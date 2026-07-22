using System;
using System.Collections.Generic;
using System.IO;
using CodeWalker.GameFiles;

// YtdBuild --dds <in.dds> --name <textureName> --out <out.ytd>
//
// Builds a GTA5 .ytd (texture dictionary) containing one texture parsed from a DDS,
// then re-opens the saved .ytd and asserts the texture round-trips (structural gate).
//
// DDSIO is absent from the CodeWalker.Core 1.0.3 nuget, so the DDS header is parsed
// here by hand. Field mapping mirrors CodeWalker's own DDSIO.GetTexture:
//   - FullData  = all bytes AFTER the header (128, or 148 when a DX10 header is present)
//   - Levels    = dwMipMapCount (min 1)
//   - Stride    = slicePitch / height  (per-format block pitch)
//   - Format    = fourCC / DXGI -> TextureFormat
internal static class Program
{
    private const uint DDS_MAGIC   = 0x20534444; // "DDS "
    private const uint DDPF_FOURCC = 0x4;
    private const uint FOURCC_DXT1 = 0x31545844;
    private const uint FOURCC_DXT3 = 0x33545844;
    private const uint FOURCC_DXT5 = 0x35545844;
    private const uint FOURCC_DX10 = 0x30315844;

    private static int Main(string[] args)
    {
        // --list <ytd>: open an existing .ytd and print each texture's Name/Width/Height/Format.
        // Used to read a base clothing pack's INTERNAL texture name so our generated .ytd can
        // reuse the exact name the base .ydd looks up.
        string listPath = Arg(args, "--list");
        if (listPath != null)
        {
            if (!File.Exists(listPath)) { Console.Error.WriteLine("ytd not found: " + listPath); return 2; }
            var yf = new YtdFile();
            try { yf.Load(File.ReadAllBytes(listPath)); }
            catch (Exception e) { Console.Error.WriteLine("YTD load failed: " + e.Message); return 1; }
            var dict = yf.TextureDict;
            if (dict == null) { Console.Error.WriteLine("no TextureDictionary in " + listPath); return 1; }
            var texs = dict.Textures?.data_items;
            int n = texs?.Length ?? 0;
            Console.WriteLine($"YTD {listPath}  textures={n}");
            if (texs != null)
            {
                foreach (var t in texs)
                {
                    if (t == null) continue;
                    Console.WriteLine($"  name={t.Name}  hash=0x{t.NameHash:X8}  {t.Width}x{t.Height}  fmt={t.Format}  levels={t.Levels}  stride={t.Stride}");
                }
            }
            return 0;
        }

        // --yddtex <ydd>: open a drawable dictionary (.ydd) and print, per drawable, the
        // texture NAMES its shaders reference. A clothing .ydd carries no embedded texture -
        // it looks the texture up BY NAME at render time in whatever .ytd is loaded for its
        // slot. That referenced name is the ground truth our generated .ytd must reproduce.
        string yddPath = Arg(args, "--yddtex");
        if (yddPath != null)
        {
            if (!File.Exists(yddPath)) { Console.Error.WriteLine("ydd not found: " + yddPath); return 2; }
            var yd = new YddFile();
            try { yd.Load(File.ReadAllBytes(yddPath)); }
            catch (Exception e) { Console.Error.WriteLine("YDD load failed: " + e.Message); return 1; }
            var drawables = yd.DrawableDict?.Drawables?.data_items;
            int dn = drawables?.Length ?? 0;
            Console.WriteLine($"YDD {yddPath}  drawables={dn}");
            var seen = new HashSet<string>();
            if (drawables != null)
            {
                for (int di = 0; di < drawables.Length; di++)
                {
                    var d = drawables[di];
                    var shaders = d?.ShaderGroup?.Shaders?.data_items;
                    if (shaders == null) continue;
                    foreach (var sh in shaders)
                    {
                        var pars = sh?.ParametersList?.Parameters;
                        if (pars == null) continue;
                        foreach (var p in pars)
                        {
                            var tb = p.Data as TextureBase;
                            if (tb == null) continue;
                            string tag = $"draw[{di}] shader={sh.Name} texName={tb.Name} hash=0x{tb.NameHash:X8}";
                            if (seen.Add(tag)) Console.WriteLine("  " + tag);
                        }
                    }
                }
            }
            if (seen.Count == 0) Console.WriteLine("  (no TextureBase references found)");
            return 0;
        }

        string dds = Arg(args, "--dds"), name = Arg(args, "--name"), outp = Arg(args, "--out");
        if (dds == null || name == null || outp == null)
        {
            Console.Error.WriteLine("usage: YtdBuild --dds <in.dds> --name <textureName> --out <out.ytd>");
            Console.Error.WriteLine("   or: YtdBuild --list <in.ytd>");
            return 2;
        }
        if (!File.Exists(dds)) { Console.Error.WriteLine("dds not found: " + dds); return 2; }

        byte[] file = File.ReadAllBytes(dds);
        Texture tex;
        try { tex = TextureFromDds(file, name); }
        catch (Exception e) { Console.Error.WriteLine("DDS parse failed: " + e.Message); return 1; }

        var ytd = new YtdFile { TextureDict = new TextureDictionary() };
        ytd.TextureDict.BuildFromTextureList(new List<Texture> { tex });

        byte[] outBytes = ytd.Save();
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outp)));
        File.WriteAllBytes(outp, outBytes);

        // Round-trip gate: re-open and confirm the texture is present with matching dims/format.
        var check = new YtdFile();
        check.Load(File.ReadAllBytes(outp));
        Texture got = check.TextureDict?.Lookup(tex.NameHash);
        if (got == null) { Console.Error.WriteLine("ROUNDTRIP FAIL: texture not found in saved ytd"); return 1; }
        if (got.Width != tex.Width || got.Height != tex.Height || got.Format != tex.Format)
        {
            Console.Error.WriteLine($"ROUNDTRIP FAIL: got {got.Width}x{got.Height} {got.Format}, expected {tex.Width}x{tex.Height} {tex.Format}");
            return 1;
        }
        Console.WriteLine($"OK {outp}  name={name}  {got.Width}x{got.Height}  fmt={got.Format}  levels={got.Levels}  stride={got.Stride}  bytes={outBytes.Length}");
        return 0;
    }

    private static Texture TextureFromDds(byte[] f, string name)
    {
        if (f.Length < 128) throw new Exception("file too small");
        if (U32(f, 0) != DDS_MAGIC) throw new Exception("bad DDS magic");

        uint height   = U32(f, 12);
        uint width    = U32(f, 16);
        uint depth    = U32(f, 24); if (depth == 0) depth = 1;
        uint mipCount = U32(f, 28); if (mipCount == 0) mipCount = 1;

        uint pfFlags  = U32(f, 80);
        uint fourCC   = U32(f, 84);

        int headerSize = 128;
        TextureFormat format;

        if ((pfFlags & DDPF_FOURCC) != 0 && fourCC == FOURCC_DX10)
        {
            if (f.Length < 148) throw new Exception("DX10 header truncated");
            uint dxgi = U32(f, 128);
            headerSize = 148;
            format = DxgiToFormat(dxgi);
        }
        else if ((pfFlags & DDPF_FOURCC) != 0)
        {
            switch (fourCC)
            {
                case FOURCC_DXT1: format = TextureFormat.D3DFMT_DXT1; break;
                case FOURCC_DXT3: format = TextureFormat.D3DFMT_DXT3; break;
                case FOURCC_DXT5: format = TextureFormat.D3DFMT_DXT5; break;
                default: throw new Exception("unsupported fourCC 0x" + fourCC.ToString("X8"));
            }
        }
        else
        {
            // Uncompressed 32bpp path (rare for our pipeline; BC1/BC3/BC7 is the norm).
            format = TextureFormat.D3DFMT_A8R8G8B8;
        }

        byte[] data = new byte[f.Length - headerSize];
        Array.Copy(f, headerSize, data, 0, data.Length);

        ushort stride = (ushort)ComputeStride(format, (int)width, (int)height);

        uint hash = JenkHash.GenHash(name.ToLowerInvariant());
        JenkIndex.Ensure(name.ToLowerInvariant());

        var tex = new Texture
        {
            Name     = name,
            NameHash = hash,
            Width    = (ushort)width,
            Height   = (ushort)height,
            Depth    = (ushort)depth,
            Levels   = (byte)mipCount,
            Format   = format,
            Stride   = stride,
            Data     = new TextureData { FullData = data }
        };
        return tex;
    }

    private static TextureFormat DxgiToFormat(uint dxgi)
    {
        switch (dxgi)
        {
            case 71: case 72: return TextureFormat.D3DFMT_DXT1; // BC1_UNORM(_SRGB)
            case 74: case 75: return TextureFormat.D3DFMT_DXT3; // BC2_UNORM(_SRGB)
            case 77: case 78: return TextureFormat.D3DFMT_DXT5; // BC3_UNORM(_SRGB)
            case 98: case 99: return TextureFormat.D3DFMT_BC7;  // BC7_UNORM(_SRGB)
            case 87:          return TextureFormat.D3DFMT_A8R8G8B8; // B8G8R8A8_UNORM
            default: throw new Exception("unsupported DXGI format " + dxgi);
        }
    }

    // stride = slicePitch / height, per DirectXTex ComputePitch rules.
    private static int ComputeStride(TextureFormat fmt, int width, int height)
    {
        bool block = fmt == TextureFormat.D3DFMT_DXT1 || fmt == TextureFormat.D3DFMT_DXT3
                  || fmt == TextureFormat.D3DFMT_DXT5 || fmt == TextureFormat.D3DFMT_BC7;
        if (block)
        {
            int blockBytes = fmt == TextureFormat.D3DFMT_DXT1 ? 8 : 16;
            int blocksWide = Math.Max(1, (width + 3) / 4);
            int blocksHigh = Math.Max(1, (height + 3) / 4);
            long slicePitch = (long)blocksWide * blockBytes * blocksHigh;
            return (int)(slicePitch / Math.Max(1, height));
        }
        return width * 4; // 32bpp
    }

    private static uint U32(byte[] b, int off) => BitConverter.ToUInt32(b, off);

    private static string Arg(string[] a, string k)
    {
        for (int i = 0; i < a.Length - 1; i++) if (a[i] == k) return a[i + 1];
        return null;
    }
}
