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

### Current state of `YtdBuild/`

`net48` console, `CodeWalker.Core 1.0.3` + `Microsoft.NETFramework.ReferenceAssemblies`
referenced and **restoring cleanly**. `Program.cs` is still the `dotnet new` stub — the DDS
parser + build code (above) is the next thing to write.
