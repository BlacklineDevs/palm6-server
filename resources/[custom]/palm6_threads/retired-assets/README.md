# palm6_threads retired assets — DO NOT PUT THESE BACK IN A `stream/` FOLDER

Retired 2026-07-29. These are the two files that took the live server down.

| file here | original name and location |
| --- | --- |
| `mp_m_freemode_01^jbib_000_u.ydd.RETIRED` | `stream/mp_m_freemode_01^jbib_000_u.ydd` |
| `mp_m_freemode_01^jbib_diff_000_a_uni.ytd.RETIRED` | `stream/mp_m_freemode_01^jbib_diff_000_a_uni.ytd` |

## Why they are here and not in `stream/`

FiveM auto-mounts every file under a resource's `stream/` folder into the global
streaming store, keyed by filename. Neither of these filenames has a DLC segment
(`mp_m_freemode_01^...`, not `mp_m_freemode_01_<packname>^...`), so mounting them
does not add a garment. It **replaces** base male-torso jbib drawable 0 for every
male freemode ped on the server.

On 2026-07-29 `palm6_threads` was found running on the live box and every police
work outfit rendered as nothing, for everyone, because every outfit built on the
base torso had lost its drawable.

## What stops that recurring, honestly

**In this repo:** there is no `stream/` folder, so a fresh checkout mounts
nothing, and these two copies carry a `.RETIRED` extension that FiveM would not
recognise as a game asset even if someone moved them back.

**On the live box: neither of those applies yet.** The deploy is additive
(`mirror --reverse` with `MIRROR_DELETE` defaulting to `false`,
`.github/workflows/deploy-custom-layer.yml:39,148`), so removing `stream/` from
the repo did not remove it from the server. The originals are still at
`resources/[custom]/palm6_threads/stream/` on the host, under their original
names, fully mountable. See `../HOST-CLEANUP-REQUIRED.md`.

What actually holds the line on the live box today is `stop palm6_threads` in
`custom.cfg`, which the server executes, and the retired `fxmanifest.lua`, which
the deploy overwrites in place. The files in this folder are a record, not a
control.

Removing any of that without reading `docs/CUSTOM-CLOTHING.md` is how this
happens a third time.

## What they actually are

- **The `.ydd` (186,568 bytes)** is a copy of Rockstar's own base male-torso
  geometry, taken as a "known-good" template so the spike only had one variable.
  It is not custom work and it has no value in a future addon pack, because an
  addon pack that adds a duplicate of a garment the game already ships adds
  nothing. A real pack needs new geometry authored in Blender + Sollumz.
- **The `.ytd` (6,077 bytes)** is the one genuinely custom artifact: a 256x256
  BC7 texture produced headlessly by `tools/threads-pipeline/YtdBuild`
  (PNG -> texconv -> DDS -> CodeWalker.Core -> `.ytd`). It proved the packer
  emits a structurally valid, re-openable `.ytd`. It never proved the texture
  renders on a ped in game, which was Task 5 and was never completed.

Keep them for the record. They are evidence, not building blocks.
