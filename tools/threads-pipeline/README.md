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

## ⚠️ BLOCKER surfaced: CodeWalker.Core sourcing (Task 3)

The research assumed `CodeWalker.Core` is a clean NuGet targeting .NET Standard 2.0.
**Reality on nuget.org:** the `CodeWalker.Core` package (versions 1.0.0–1.0.3) is
**unlisted** (appears in the flat-container index but not in search/registration) AND
**incompatible with net8.0** — `dotnet add package` → `NU1100: Unable to resolve` /
`incompatible with 'all' frameworks`. It almost certainly targets **.NET Framework 4.x**
(dexyfex's CodeWalker.Core is historically net48), not netstandard2.0.

### Resolution options (decide before continuing Task 3)

1. **Target the tool at `net48` instead of `net8.0`** (LIKELY SIMPLEST). The `YtdBuild`
   tool only needs to run on the Windows worker; it does not need net8. Retarget
   `YtdBuild.csproj` to `net48`, add `Microsoft.NETFramework.ReferenceAssemblies` if the
   targeting pack is missing, then reference the `net48` CodeWalker.Core assembly
   (`--version 1.0.3`, which should restore for a net48 TFM). Verify the 1.0.x package is
   the genuine dexyfex library (exposes `Texture`, `TextureDictionary`, `YtdFile`,
   `DDSIO`) and not a squat — inspect the restored DLL with `ildasm`/ILSpy.
2. **Build CodeWalker.Core from source** — clone `dexyfex/CodeWalker`, build the
   `CodeWalker.Core` project, reference the resulting DLL directly. The `CodeWalker API`
   (.NET 9) project proves Core can run under modern .NET, but may require the Core csproj
   to be retargeted to netstandard2.0 first. More work, cleaner long-term.
3. **Fork/extract grzyClothTool's texture-add path** (GPL-3.0 — accept the license or use
   as reference only). grzyClothTool already references a working CodeWalker.Core; its
   `.csproj` shows exactly which assembly/version works.

**Recommendation:** try option 1 first (retarget net48) — a ~10-minute change that likely
unblocks the whole packer. If the 1.0.x package turns out to be a squat/stale, fall back
to option 2 (source build).

### Current state of `YtdBuild/`

Scaffolded as a net8.0 console (`dotnet new console`). `CodeWalker.Core` PackageReference
was added but does NOT restore (incompatible TFM). `Program.cs` is still the default
`dotnet new` stub — the real DDS→.ytd code (per the plan Task 3) is NOT yet written,
pending the sourcing decision above.
