# PALM6 Threads — generation pipeline (Phase 0 spike)

Headless chain: PNG → DDS (texconv) → `.ytd` (CodeWalker.Core) → base `.ydd` copy →
`.ymt` (gtautil) → loose-file `palm6_threads` resource → in-game via illenium.

## Environment (recorded during Phase 0 execution, 2026-07-22)

- **.NET SDK:** installed via Microsoft `dotnet-install.ps1` (winget source service is
  disabled on this box, error 0x80070422 — do not use winget here). Installed to
  `C:\Users\Mgtda\.dotnet\` — version **8.0.423**. Invoke as
  `& "$env:USERPROFILE\.dotnet\dotnet.exe"` (not on global PATH).
- **texconv:** TODO (Task 2) — DirectXTex release exe.
- **gtautil:** TODO (Task 6 / Stage B) — gizzdev/gtautil.

## ✅ RESOLVED: CodeWalker.Core sourcing (Task 3)

**Root cause of the initial failures was NOT the package — it was that this machine had
NO NuGet source configured** (`dotnet nuget list source` → "No sources found"). Every
restore failed with `NU1100 Unable to resolve` for *every* package (even
`Microsoft.NETFramework.ReferenceAssemblies`). Fix, applied once:

```powershell
& "$env:USERPROFILE\.dotnet\dotnet.exe" nuget add source https://api.nuget.org/v3/index.json -n nuget.org
```

After that, `CodeWalker.Core 1.0.3` **restores cleanly**. Verified facts:
- The package targets **netstandard2.0** (so it loads under BOTH net8.0 and net48 — the
  earlier "incompatible with all frameworks" was a red herring from the missing source).
  `YtdBuild.csproj` is currently `net48`; net8.0 would also work.
- It is the **genuine dexyfex library** — reflection confirms
  `CodeWalker.GameFiles.{YtdFile, TextureDictionary, Texture, JenkHash, JenkIndex}` are all
  present. Not a squat.

### Verified API (reflected from the 1.0.3 assembly)

- `YtdFile`: `.TextureDict` (get/set), `.Load(byte[])`, `.Save() -> byte[]`.
- `TextureDictionary`: **`.BuildFromTextureList(List<Texture>)`** (this builds the hash
  table — the part we feared; the lib handles it), `.Lookup(uint hash) -> Texture`,
  `.Textures`, `.TextureNameHashes`.
- `Texture` settable props: `Width, Height, Depth, Stride, Format, Levels` (mip count),
  `Data` (a `TextureData` whose `.FullData` holds the raw block-compressed bytes),
  `Name, NameHash, Usage, UsageFlags`.
- `JenkHash.GenHash(string)` / `JenkIndex.Ensure(string)` for the name hash.

### ⚠️ Remaining Task-3 work (well-scoped, not a blocker)

**`DDSIO` is NOT in this build** — there is no one-call DDS→Texture helper. So `Program.cs`
must **parse the DDS header itself** (magic `DDS `, width, height, mip count, and the
pixelformat FourCC → map `DXT1/DXT5/BC7` to CodeWalker's `TextureFormat` enum), set
`Texture.{Width,Height,Stride,Format,Levels}` and `Texture.Data.FullData = <all bytes after
the 128-byte DDS header>` (or 148 for DX10/BC7 headers), then `BuildFromTextureList` +
`YtdFile.Save()`. This is a standard DDS parse (~100 lines). **grzyClothTool's texture-add
path is the exact reference** for the DDS→Texture field mapping (GPL — reference, don't
copy). This is the one piece left to write + validate in-game.

## ✅ PHASE 0 TASK 2 + TASK 3 PROVEN (2026-07-22)

The make-or-break (headless PNG → valid GTA `.ytd`) is proven at the structural level.

**Tools present** (`vendor/`, git-ignored): `texconv.exe` (DirectXTex release `may2026`).
GPU BC7 compression works here (DirectCompute on RTX 4060), so BC7 is fast.

**Task 2 — PNG → DDS:** `scripts/png-to-dds.ps1 -In x.png -Out x.dds -Format BC7_UNORM`
wraps texconv. Verified: 256×256 PNG → 65,684-byte BC7 DDS with a DX10 header.

**Task 3 — DDS → `.ytd`:** `YtdBuild/Program.cs` parses the DDS header by hand (DDSIO absent),
maps fourCC/DXGI → `TextureFormat`, computes `Stride = slicePitch/height`, strips the
128/148-byte header into `Texture.Data.FullData`, builds the dict via
`TextureDictionary.BuildFromTextureList`, and `YtdFile.Save()`s. It then re-opens the saved
`.ytd` and asserts the texture round-trips (matching dims + format). **Both formats verified:**
- 64×64 hand-crafted **DXT1** (legacy fourCC) → `OK ... fmt=D3DFMT_DXT1 stride=32 exit=0`
- 256×256 **BC7** (DX10 header, real texconv output) → `OK ... fmt=D3DFMT_BC7 stride=256 exit=0`

Field mapping mirrors CodeWalker's own `DDSIO.GetTexture` (fetched from source as the reference).

**Invoke:** `& "$env:USERPROFILE\.dotnet\dotnet.exe"` for builds;
`YtdBuild\bin\Release\net48\YtdBuild.exe --dds <in.dds> --name <tex> --out <out.ytd>`.

### ⚠️ What "proven" does and does NOT mean
- **DOES:** the `.ytd` is a well-formed CodeWalker resource — re-openable, correct texture
  metadata (name hash, dims, format, stride, mips). The DDS→`.ytd` automation works headlessly.
- **DOES NOT:** prove the texture *renders on a ped in-game*. That is Phase 0 **Task 5** and can
  only be confirmed by David wearing it on PALM6 (no local FXServer exists).

### Remaining Phase 0 (Stage B → in-game)
- A **base garment `.ydd`** to copy into a reserved drawable slot (from a known-good addon pack).
- **gtautil `genpeddefs --fivem`** to emit the component `.ymt` (verify gtautil runs on this box).
- Assemble the `palm6_threads` resource (stream/ + meta/ + fxmanifest) and deploy.
- **Task 5 in-game gate (David):** does it wear + persist.
