# PALM6 Threads — Phase 0: Pipeline Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the make-or-break chain end-to-end on ONE hand-fed texture — a player-style PNG becomes a real GTA5 `.ytd`, streamed by a `palm6_threads` resource, and worn correctly on a character in-game on PALM6 via `illenium-appearance`, persisting across respawn.

**Architecture:** Reduce risk in two stages. **Stage A** proves the single bespoke step (DDS→`.ytd` via CodeWalker.Core) by swapping our generated `.ytd` into a *known-good* addon-clothing template pack and rendering it in-game — isolating "does our texture packer work" from "is the whole pack assembled right." **Stage B** then proves full generation (base `.ydd` copy + `.ymt` via gtautil) from scratch. No web UI, no DB, no entitlement — this phase touches only local tooling + one throwaway FiveM resource.

**Tech Stack:** .NET 8 (C# console tool `YtdBuild` on `CodeWalker.Core`), Microsoft `texconv` (PNG→DDS), `gtautil` (`genpeddefs --fivem`, Stage B only), a `palm6_threads` FiveM resource (Lua), git→CI→SFTP deploy.

## Global Constraints

- **Loose-file streaming only** — assets are loose `.ydd`/`.ytd`/`.ymt` in a `stream/`+`meta/` folder; NO `.rpf` packing, NO `GTA5.exe` key extraction.
- **FiveM rule:** `CancelEvent()` before ANY yield in an event handler.
- **PALM6 resource conventions:** ship `Config.Enabled = false` (prod-inert); DoS-budget net events in `palm6_eventguard`; every `.lua` must be `luaparse`-clean; NO local FXServer exists — **the deploy IS the boot-verify.**
- **Debug commands are ace-gated** (console/admin only), never open net events.
- **Windows worker** — all generation tooling (texconv, CodeWalker.Core, gtautil) runs on Windows; run the spike locally on the Windows dev box, not GitHub Actions (CI wiring is Phase 1).
- **Index stability:** the spike reserves a fixed drawable index band and never reuses indices (a renumber corrupts saved outfits).
- **Bash hangs on this box** — use PowerShell for all git/shell.
- **Reference, don't copy:** `grzyClothTool` (GPL-3.0) chains this exact flow — study its CodeWalker.Core usage; do not copy GPL code into our tree.

---

### Task 1: Tooling setup + acquire a known-good base template

**Files:**
- Create: `tools/threads-pipeline/README.md` (records exact tool versions + paths)
- Create: `tools/threads-pipeline/vendor/` (texconv.exe, gtautil — git-ignored binaries; README records source URLs + SHA256)
- Create: `tools/threads-pipeline/.gitignore` (`vendor/`, `bin/`, `obj/`, `*.dds`, `work/`)

**Interfaces:**
- Produces: a verified local toolchain and a `work/base-template/` known-good addon-clothing pack (a proven `.ydd`+`.ytd`+`.ymt` for one male torso garment) used as the Stage-A swap target.

- [ ] **Step 1: Verify .NET 8 SDK is present**

Run (PowerShell):
```powershell
dotnet --version
```
Expected: `8.x.x` (or higher). If absent, install: `winget install Microsoft.DotNet.SDK.8`.

- [ ] **Step 2: Fetch texconv**

Download `texconv.exe` from the Microsoft DirectXTex releases (https://github.com/microsoft/DirectXTex/releases) into `tools/threads-pipeline/vendor/texconv.exe`. Verify:
```powershell
tools\threads-pipeline\vendor\texconv.exe -h | Select-Object -First 3
```
Expected: usage banner mentioning `-f <format>`. Record the release tag + SHA256 in `README.md`.

- [ ] **Step 3: Fetch gtautil (Stage B tool; fetch now)**

Clone + build from https://github.com/gizzdev/gtautil (or download a release) into `vendor/gtautil/`. Verify:
```powershell
tools\threads-pipeline\vendor\gtautil\gtautil.exe genpeddefs --help
```
Expected: help text listing `--input --output --reserve --reserveprops --fivem`. If the build is non-trivial, record the blocker in `README.md` and defer to Stage B (Task 6) — Stage A does not need gtautil.

- [ ] **Step 4: Acquire a known-good base addon-clothing template**

Download the TimyStream FiveM clothing addon template (https://github.com/TimyStream/fivem-clothing-addon-template) into `tools/threads-pipeline/work/base-template/`. Confirm it contains a `stream/` folder with at least one male torso (`component 11` jacket, or `8` undershirt) `.ydd` + `.ytd` and a `meta/` `.ymt`/`.meta`, and an `fxmanifest.lua` with a `data_file 'SHOP_PED_APPAREL_META_FILE'` line. Note the exact `.ytd` filename we will regenerate (e.g. `jbib_diff_000_a_uni.ytd`).

- [ ] **Step 5: Commit the harness (no binaries)**

```powershell
Push-Location 'C:\Users\Mgtda\Projects\Active\gtarp-threads'
git add tools/threads-pipeline/README.md tools/threads-pipeline/.gitignore
git commit -m @'
chore(threads): pipeline tooling harness + versions (Phase 0 Task 1)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
Pop-Location
```

---

### Task 2: PNG → DDS wrapper (texconv)

**Files:**
- Create: `tools/threads-pipeline/scripts/png-to-dds.ps1`
- Create: `tools/threads-pipeline/work/test-input/logo-tee.png` (a hand-made 1024×1024 test texture — solid color + a simple white shape, so success is visually obvious in-game)

**Interfaces:**
- Produces: `png-to-dds.ps1 -In <png> -Out <dds> [-Format BC7_UNORM|BC3_UNORM]` → a valid DDS file.

- [ ] **Step 1: Write the wrapper**

`tools/threads-pipeline/scripts/png-to-dds.ps1`:
```powershell
param(
  [Parameter(Mandatory)][string]$In,
  [Parameter(Mandatory)][string]$Out,
  [ValidateSet('BC7_UNORM','BC3_UNORM')][string]$Format = 'BC7_UNORM'
)
$texconv = Join-Path $PSScriptRoot '..\vendor\texconv.exe'
$outDir  = Split-Path $Out -Parent
$name    = [IO.Path]::GetFileNameWithoutExtension($Out)
& $texconv -nologo -y -f $Format -m 0 -o $outDir $In
# texconv names output by input basename; rename to requested $Out.
$produced = Join-Path $outDir ([IO.Path]::GetFileNameWithoutExtension($In) + '.dds')
if ($produced -ne $Out) { Move-Item -Force $produced $Out }
if (-not (Test-Path $Out)) { throw "texconv produced no DDS for $In" }
Write-Output $Out
```

- [ ] **Step 2: Create the test PNG**

Generate a 1024×1024 PNG with a solid PALM6-teal background and a white circle/logo (any tool). Save as `work/test-input/logo-tee.png`. This is the "player design" for the spike — instantly recognizable in-game.

- [ ] **Step 3: Run it and verify a DDS is produced**

```powershell
tools\threads-pipeline\scripts\png-to-dds.ps1 -In tools\threads-pipeline\work\test-input\logo-tee.png -Out tools\threads-pipeline\work\test-input\logo-tee.dds -Format BC7_UNORM
tools\threads-pipeline\vendor\texconv.exe -nologo -info tools\threads-pipeline\work\test-input\logo-tee.dds | Select-String 'width|height|format'
```
Expected: reports width 1024, height 1024, format BC7_UNORM. If BC7 fails on this box (GPU/DirectX), rerun with `-Format BC3_UNORM` and record it.

- [ ] **Step 4: Commit the script**

```powershell
Push-Location 'C:\Users\Mgtda\Projects\Active\gtarp-threads'
git add tools/threads-pipeline/scripts/png-to-dds.ps1
git commit -m @'
feat(threads): PNG->DDS texconv wrapper (Phase 0 Task 2)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
Pop-Location
```

---

### Task 3: DDS → `.ytd` C# service (the bespoke, highest-risk step)

**Files:**
- Create: `tools/threads-pipeline/YtdBuild/YtdBuild.csproj`
- Create: `tools/threads-pipeline/YtdBuild/Program.cs`
- Test: `tools/threads-pipeline/YtdBuild/roundtrip check` (re-open the produced `.ytd` with CodeWalker.Core and assert the texture is present with correct dims — a structural test, since no unit test can prove in-game rendering)

**Interfaces:**
- Produces: `YtdBuild.exe --dds <file.dds> --name <textureName> --out <file.ytd>` → a `.ytd` containing one texture named `<textureName>`.
- Consumes: a DDS from Task 2.

- [ ] **Step 1: Scaffold the project + reference CodeWalker.Core**

```powershell
Push-Location 'C:\Users\Mgtda\Projects\Active\gtarp-threads\tools\threads-pipeline'
dotnet new console -n YtdBuild -o YtdBuild
Push-Location YtdBuild
dotnet add package CodeWalker.Core
Pop-Location; Pop-Location
```
Expected: `CodeWalker.Core` restored (targets .NET Standard 2.0; loads under .NET 8).

- [ ] **Step 2: Write `Program.cs` (build a .ytd from a DDS, then round-trip verify)**

`tools/threads-pipeline/YtdBuild/Program.cs`:
```csharp
using System;
using System.IO;
using CodeWalker.GameFiles;

// Usage: YtdBuild --dds <in.dds> --name <textureName> --out <out.ytd>
// Builds a texture dictionary containing a single texture, saves as a loose .ytd,
// then re-opens it to assert the texture round-trips (structural gate).
class Program
{
    static int Main(string[] args)
    {
        string dds = Arg(args, "--dds"), name = Arg(args, "--name"), outp = Arg(args, "--out");
        if (dds == null || name == null || outp == null) { Console.Error.WriteLine("need --dds --name --out"); return 2; }

        // DDSIO converts raw DDS bytes into a CodeWalker Texture (parses header: dims, format, mips).
        byte[] ddsBytes = File.ReadAllBytes(dds);
        Texture tex = DDSIO.GetTexture(ddsBytes);
        tex.Name = name;
        tex.NameHash = JenkHash.GenHash(name.ToLowerInvariant());
        JenkIndex.Ensure(name.ToLowerInvariant());

        var ytd = new YtdFile();
        ytd.TextureDict = new TextureDictionary();
        ytd.TextureDict.BuildFromTextureList(new System.Collections.Generic.List<Texture> { tex });

        byte[] outBytes = ytd.Save();
        File.WriteAllBytes(outp, outBytes);

        // Round-trip gate: re-open and confirm the texture is present with correct dims.
        var check = new YtdFile();
        check.Load(File.ReadAllBytes(outp));
        var got = check.TextureDict?.Lookup(tex.NameHash);
        if (got == null) { Console.Error.WriteLine("ROUNDTRIP FAIL: texture not found in saved ytd"); return 1; }
        if (got.Width != tex.Width || got.Height != tex.Height)
        { Console.Error.WriteLine($"ROUNDTRIP FAIL: dims {got.Width}x{got.Height} != {tex.Width}x{tex.Height}"); return 1; }
        Console.WriteLine($"OK {outp} texture={name} {got.Width}x{got.Height} fmt={got.Format}");
        return 0;
    }

    static string Arg(string[] a, string k)
    { for (int i = 0; i < a.Length - 1; i++) if (a[i] == k) return a[i + 1]; return null; }
}
```

> ⚠️ **API-verification step:** the exact member names (`DDSIO.GetTexture`, `TextureDictionary.BuildFromTextureList`, `Lookup`, `YtdFile.Save/Load`, `JenkHash`/`JenkIndex`) must be confirmed against the installed `CodeWalker.Core` version — open `grzyClothTool`'s texture-add path as the reference for the canonical sequence and adjust names if the NuGet API differs. This is the single riskiest code in the whole project; getting the `TextureDict` hash-table build right is what makes the `.ytd` load in-game.

- [ ] **Step 3: Build**

```powershell
Push-Location 'C:\Users\Mgtda\Projects\Active\gtarp-threads\tools\threads-pipeline\YtdBuild'
dotnet build -c Release
Pop-Location
```
Expected: build succeeds. Fix any API-name mismatches flagged above until it compiles.

- [ ] **Step 4: Run it on the Task-2 DDS; verify the round-trip gate passes**

```powershell
$yb='C:\Users\Mgtda\Projects\Active\gtarp-threads\tools\threads-pipeline\YtdBuild\bin\Release\net8.0\YtdBuild.exe'
& $yb --dds ..\work\test-input\logo-tee.dds --name jbib_diff_000_a_uni --out ..\work\test-input\jbib_diff_000_a_uni.ytd
```
Expected: prints `OK ... texture=jbib_diff_000_a_uni 1024x1024 fmt=BC7...`. Non-zero exit = the texture didn't round-trip; fix before proceeding (do NOT move to in-game with a failing round-trip).

- [ ] **Step 5: Commit**

```powershell
Push-Location 'C:\Users\Mgtda\Projects\Active\gtarp-threads'
git add tools/threads-pipeline/YtdBuild/YtdBuild.csproj tools/threads-pipeline/YtdBuild/Program.cs
git commit -m @'
feat(threads): DDS->.ytd builder on CodeWalker.Core + round-trip gate (Phase 0 Task 3)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
Pop-Location
```

---

### Task 4: Stage A — swap our `.ytd` into the known-good pack; assemble `palm6_threads` skeleton

**Files:**
- Create: `resources/[custom]/palm6_threads/fxmanifest.lua`
- Create: `resources/[custom]/palm6_threads/shared/config.lua`
- Create: `resources/[custom]/palm6_threads/client/debug.lua`
- Create: `resources/[custom]/palm6_threads/stream/` (base-template `.ydd` + our generated `.ytd`)
- Create: `resources/[custom]/palm6_threads/meta/` (base-template `.ymt`/`.meta`)

**Interfaces:**
- Produces: a deployable `palm6_threads` resource streaming one garment whose texture is OUR generated `.ytd`, plus an ace-gated client debug command to wear it.

- [ ] **Step 1: Copy the known-good pack into the resource, swapping our `.ytd`**

Copy the base-template `stream/*.ydd` and `meta/*` into `palm6_threads/stream` and `palm6_threads/meta`. Replace the template's torso `.ytd` with `work/test-input/jbib_diff_000_a_uni.ytd` from Task 3 (keep the exact filename the template's `.ymt` references). This is the isolation: everything is proven-good except our one texture.

- [ ] **Step 2: Write `fxmanifest.lua`**

`resources/[custom]/palm6_threads/fxmanifest.lua`:
```lua
fx_version 'cerulean'
game 'gta5'

name 'palm6_threads'
description 'PALM6 Threads — player custom clothing (Phase 0 spike)'
version '0.0.1'

shared_script 'shared/config.lua'
client_script 'client/debug.lua'

data_file 'SHOP_PED_APPAREL_META_FILE' 'meta/mp_m_freemode_01.meta'

files {
  'meta/*.meta',
}
```
> Set the `data_file` path + `files` glob to match the base-template's actual meta filename(s). The `stream/` folder auto-mounts; no manifest entry needed for loose stream assets.

- [ ] **Step 3: Write `shared/config.lua`**

`resources/[custom]/palm6_threads/shared/config.lua`:
```lua
Config = {}
-- Prod-inert until the spike is proven, per PALM6 convention.
Config.Enabled = false
-- The torso component + reserved drawable/texture the spike garment lives at.
-- Fill these from the base-template's .ymt (which drawable index + texture 0).
Config.Spike = { component = 11, drawable = 0, texture = 0 }
```

- [ ] **Step 4: Write the ace-gated debug command to wear it**

`resources/[custom]/palm6_threads/client/debug.lua`:
```lua
-- Ace-gated (server console / admin) spike command: wear the generated garment.
RegisterCommand('threads_spike', function()
    if not Config.Enabled then
        print('[palm6_threads] disabled (Config.Enabled=false)')
        return
    end
    local ped = PlayerPedId()
    local s = Config.Spike
    SetPedComponentVariation(ped, s.component, s.drawable, s.texture, 2)
    print(('[palm6_threads] applied comp=%d draw=%d tex=%d'):format(s.component, s.drawable, s.texture))
end, false)
```
> This is a *local client debug* command for the spike (visual check only). It does not persist and is not a real net event — the real delivery goes through illenium persistence in Phase 1. Keep it behind `Config.Enabled` and remove before Phase 1.

- [ ] **Step 5: luaparse-clean the Lua**

```powershell
Push-Location 'C:\Users\Mgtda\Projects\Active\gtarp-threads\resources\[custom]\palm6_threads'
npx --yes luaparse fxmanifest.lua shared/config.lua client/debug.lua 2>&1
Pop-Location
```
Expected: no parse errors. (If `npx luaparse` hangs on this box's slow disk, read-verify syntax manually — it's three tiny files.)

- [ ] **Step 6: Commit (explicit paths — binaries included intentionally for the spike)**

```powershell
Push-Location 'C:\Users\Mgtda\Projects\Active\gtarp-threads'
git add "resources/[custom]/palm6_threads/fxmanifest.lua" "resources/[custom]/palm6_threads/shared/config.lua" "resources/[custom]/palm6_threads/client/debug.lua" "resources/[custom]/palm6_threads/stream" "resources/[custom]/palm6_threads/meta"
git commit -m @'
feat(threads): palm6_threads spike resource w/ generated .ytd (Phase 0 Task 4)

Stage A: known-good addon pack with OUR CodeWalker-built texture swapped in.
Ships Config.Enabled=false (inert). Ace-gated local debug wear command.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
Pop-Location
```

---

### Task 5: Stage A — deploy + IN-GAME GATE (David)

**Files:** none (deploy + manual verification)

**Interfaces:**
- Produces: the go/no-go signal for the entire project. If our generated `.ytd` renders correctly in-game, the make-or-break is proven.

- [ ] **Step 1: Add `palm6_threads` to the server resource load order**

Add `ensure palm6_threads` to the canonical `custom.cfg` (matching where other `palm6_` resources are ensured). Since `Config.Enabled=false`, it streams assets but takes no action — safe. Confirm the ensure ordering doesn't precede its needs (no deps for the spike).

- [ ] **Step 2: Temporarily enable for the feel-test**

Set `Config.Enabled = true` in `shared/config.lua` for this deploy ONLY (the spike is a controlled feel-test; revert after). Commit that one-line flip.

- [ ] **Step 3: Deploy via the normal pipeline**

Merge/push `feat/palm6-threads`'s spike commits per the standard deploy (open a PR to `main`, or cher-pick the spike resource to the deploy branch as David directs — do NOT force anything to prod without David's go). CI → SFTP → restart. **The deploy is the boot-verify:** confirm `palm6_threads` appears LOADED in `info.json` with no `SCRIPT ERROR` (FiveM drops erroring resources, so present = clean-booted).

- [ ] **Step 4: 🔴 MANUAL IN-GAME GATE (David)**

David, in-game: run `threads_spike` from console (or set the torso component via the illenium clothing menu to the spike drawable). **Verify:**
  1. The garment shows OUR test texture (PALM6-teal + white logo), not pink/black/missing.
  2. It survives a respawn / character reload (illenium reapplies saved components).
  3. No console spam / script error.

Record the outcome in `tools/threads-pipeline/README.md`:
  - **PASS** → the DDS→`.ytd` packer works in-game. Proceed to Task 6 (full generation).
  - **FAIL (pink/missing)** → the `.ytd` structure is wrong. Return to Task 3, compare byte-for-byte against a template `.ytd` opened in CodeWalker, fix the `TextureDict` build, redeploy. **Do not proceed until this passes.**

- [ ] **Step 5: Revert the enable flip**

Set `Config.Enabled = false` again and commit — the spike resource stays inert on prod until Phase 1 is real.

```powershell
Push-Location 'C:\Users\Mgtda\Projects\Active\gtarp-threads'
git add "resources/[custom]/palm6_threads/shared/config.lua"
git commit -m @'
chore(threads): re-disable palm6_threads after Stage A feel-test (Phase 0 Task 5)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
Pop-Location
```

---

### Task 6: Stage B — full generation from scratch (`.ydd` copy + `.ymt` via gtautil)

**Files:**
- Create: `tools/threads-pipeline/scripts/generate-item.ps1` (orchestrates the full chain)
- Modify: `resources/[custom]/palm6_threads/stream/` + `meta/` (now fully generated, not template-swapped)

**Interfaces:**
- Consumes: Task 2 (PNG→DDS), Task 3 (DDS→`.ytd`), gtautil (Task 1).
- Produces: `generate-item.ps1 -Png <png> -BaseYdd <ydd> -Component <n> -Drawable <n> -OutDir <resource>` → a complete streamed item (base `.ydd` copied to the reserved drawable index + our `.ytd` + a gtautil-generated `.ymt`).

- [ ] **Step 1: Write the orchestrator script**

`tools/threads-pipeline/scripts/generate-item.ps1`:
```powershell
param(
  [Parameter(Mandatory)][string]$Png,
  [Parameter(Mandatory)][string]$BaseYdd,   # curated base garment geometry
  [Parameter(Mandatory)][int]$Component,    # e.g. 11 = jacket/top
  [Parameter(Mandatory)][int]$Drawable,     # reserved, stable index
  [Parameter(Mandatory)][string]$OutDir     # palm6_threads resource path
)
$root   = Split-Path $PSScriptRoot -Parent
$work   = Join-Path $root 'work\gen'
$stream = Join-Path $OutDir 'stream'
$meta   = Join-Path $OutDir 'meta'
New-Item -ItemType Directory -Force $work,$stream,$meta | Out-Null

$idx  = '{0:000}' -f $Drawable
$base = "jbib_diff_$idx" + '_a_uni'      # naming: <slot>_diff_<idx>_<var>_uni
$dds  = Join-Path $work "$base.dds"
$ytd  = Join-Path $stream "$base.ytd"
$ydd  = Join-Path $stream ("jbib_$idx" + '.ydd')

& (Join-Path $PSScriptRoot 'png-to-dds.ps1') -In $Png -Out $dds -Format BC7_UNORM
& (Join-Path $root 'YtdBuild\bin\Release\net8.0\YtdBuild.exe') --dds $dds --name $base --out $ytd
if ($LASTEXITCODE -ne 0) { throw "YtdBuild failed" }
Copy-Item -Force $BaseYdd $ydd

# gtautil generates the component .ymt/.meta for the project folder, reserving a fixed band.
$gt = Join-Path $root 'vendor\gtautil\gtautil.exe'
& $gt genpeddefs --input $OutDir --output $meta --reserve 200 --reserveprops 50 --fivem
if ($LASTEXITCODE -ne 0) { throw "gtautil genpeddefs failed" }
Write-Output "generated component=$Component drawable=$Drawable at $OutDir"
```
> The `jbib`/`diff`/`_a_uni` naming and the exact gtautil project-folder layout must match what gtautil + the freemode component `.ymt` expect — validate against the "Basic Ped YMT Editing" reference and the base-template's own naming. Adjust the slot prefix per component (jbib=torso/11, etc.).

- [ ] **Step 2: Run full generation to a fresh output dir**

```powershell
tools\threads-pipeline\scripts\generate-item.ps1 -Png tools\threads-pipeline\work\test-input\logo-tee.png -BaseYdd tools\threads-pipeline\work\base-template\stream\<base>.ydd -Component 11 -Drawable 1 -OutDir tools\threads-pipeline\work\gen-out
```
Expected: produces `gen-out/stream/*.ydd + *.ytd` and `gen-out/meta/*.ymt`. Inspect the `.ymt` (open in CodeWalker or `exportmeta`) to confirm it lists drawable index 1 with one texture.

- [ ] **Step 3: Deploy the fully-generated item (repeat Task 5 flow at drawable index 1)**

Copy `gen-out/*` into `palm6_threads`, set `Config.Spike.drawable = 1`, flip `Config.Enabled=true` for the test, deploy, and **re-run the Task 5 in-game gate** at the new index.

- [ ] **Step 4: 🔴 MANUAL IN-GAME GATE (David) — full generation**

Verify the fully-generated item (no template `.ymt` involved) wears correctly + persists. Record PASS/FAIL in `README.md`.
  - **PASS** → **Phase 0 complete: the entire headless chain is proven.** Re-disable `Config.Enabled`, and proceed to write the Phase 1 plan.
  - **FAIL** → the `.ymt`/`.ydd` generation is wrong (Stage A already proved the `.ytd`); debug gtautil output vs. a known-good `.ymt`.

- [ ] **Step 5: Commit + record outcome**

```powershell
Push-Location 'C:\Users\Mgtda\Projects\Active\gtarp-threads'
git add tools/threads-pipeline/scripts/generate-item.ps1 tools/threads-pipeline/README.md
git commit -m @'
feat(threads): full generate-item chain + Phase 0 outcome (Phase 0 Task 6)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
Pop-Location
```

---

## Phase 0 exit criteria

- [ ] A hand-made PNG becomes a `.ytd` via our CodeWalker.Core tool that **round-trips structurally** (Task 3) AND **renders correctly in-game** (Task 5).
- [ ] The **fully-generated** item (our `.ytd` + copied `.ydd` + gtautil `.ymt`) renders + persists in-game (Task 6).
- [ ] Tool versions, the working DDS format (BC7 vs BC3), the reserved index band, and the Cfx key tier are recorded in `tools/threads-pipeline/README.md`.
- [ ] `palm6_threads` ships `Config.Enabled=false` on prod.

**Only after all four:** write `2026-07-22-palm6-threads-phase1-core-loop.md` (catalog + curated editor + slot ledger + admin approve + GH Actions worker + illenium delivery).

## Notes for the implementer

- **This is a spike, not TDD-shaped.** The only automatable test is the Task 3 round-trip; the real gates are David's in-game checks. That's expected — no unit test can prove a GTA texture renders. Do not fake a "passing" claim from the round-trip alone.
- **Do not touch prod deploy without David's explicit go** each time (Tasks 5 & 6 deploys). The worktree branch `feat/palm6-threads` is the staging ground.
- **If gtautil won't run** on this box, Stage A (Tasks 1–5) still fully proves the make-or-break (the `.ytd`); Stage B can move to a different Windows environment. Record the blocker; don't let it block the go/no-go signal.
