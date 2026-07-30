# HOST CLEANUP REQUIRED - `palm6_threads/stream/` is still on the live box

**Raised 2026-07-29. Not done yet. This file stays here until someone does it
and deletes this file.**

## The one fact that makes this file necessary

**Deleting a file from the repo does not remove it from the server.**

`.github/workflows/deploy-custom-layer.yml:39`

```yaml
MIRROR_DELETE: ${{ vars.MIRROR_DELETE || 'false' }}
```

`.github/workflows/deploy-custom-layer.yml:148`

```
mirror --reverse --verbose --no-perms $DELETE_FLAG "resources/[custom]/" "$REMOTE_BASE/resources/[custom]/"
```

`DELETE_FLAG` is empty unless the repo variable `MIRROR_DELETE` is set to
`true`, and it is not set. `deploy/README.md:184` states it directly: *"By
default the upload is additive: it never deletes server-side files that aren't
in the repo."*

So the deploy **overwrites** the files it carries and **deletes nothing**.

## What that means right now

The `stream/` folder was removed from this repo. On the live box it is
untouched:

```
resources/[custom]/palm6_threads/stream/mp_m_freemode_01^jbib_000_u.ydd
resources/[custom]/palm6_threads/stream/mp_m_freemode_01^jbib_diff_000_a_uni.ytd
```

Those are the two files that took the server down on 2026-07-29. They are the
payload, and the payload is still loaded on the host, waiting for anything that
starts this resource.

What the deploy **does** fix on the box:

| file | state on the box after deploy |
| --- | --- |
| `fxmanifest.lua` | overwritten with the retired tombstone, including the unresolvable `dependency` |
| `client/debug.lua`, `shared/config.lua` | overwritten with comment-only tombstones |
| `retired-assets/`, this file | newly uploaded |
| `custom.cfg` (`stop palm6_threads`) | overwritten, and it EXECUTES |
| **`stream/` and its two files** | **unchanged. Still there. Still dangerous.** |

The resource is held down today by `stop palm6_threads` in `custom.cfg`, which
execs last, after the panel's `server.cfg` ensures. That is a real, executing
control and it is why this is a cleanup task and not an outage. But it is one
line standing between the payload and every male ped on the server.

## The fix

Two options. Option A is the one to take.

### Option A - delete the folder on the host by hand (recommended)

Safe to do at any time, including with players on, **provided the resource is
stopped** (it is, via `custom.cfg`). Deleting files inside a stopped resource
has no runtime effect: nothing has them open and nothing is mounted from them.

1. Open the game panel file manager (RocketNode, server `9524616c`), or connect
   over SFTP with the non-secret details in
   `.github/workflows/deploy-custom-layer.yml:29-33`.
2. Navigate to `resources/[custom]/palm6_threads/`.
3. Confirm you can see `fxmanifest.lua` starting with
   `-- palm6_threads is RETIRED`. If it does not say that, the deploy has not
   landed yet. **Stop and deploy first**, otherwise you are deleting the
   payload while the box still holds the original dangerous manifest.
4. Delete the `stream/` directory and both files inside it.
5. Confirm the directory is gone and that `retired-assets/` is present.
6. **Do not** `ensure`, `start`, `restart` or `refresh` anything. Nothing needs
   restarting. The resource is stopped and stays stopped.

Do not "back up" the two files anywhere under `resources/`. Copies of them are
already preserved in this repo at
`resources/[custom]/palm6_threads/retired-assets/` with a `.RETIRED` extension,
and the reviewer confirmed those copies are byte-identical to the originals in
git history. A stray copy under any `stream/` folder is the whole bug again.

### Option B - set `MIRROR_DELETE=true`

Repo variable, Settings > Secrets and variables > Actions > Variables. This
turns the next deploy into a strict mirror that deletes every server-side file
under `resources/[custom]/` that is not in the repo.

**Do not do this casually.** It applies to the entire custom layer, not just
this resource, and anything a human ever placed on the box by hand and never
committed will be destroyed in one run. Option A removes two known files.
Option B removes everything unknown, and nobody has enumerated what that is.

## When it is done

Delete this file, and remove the "still on the box" wording from
`fxmanifest.lua` and from section 3 of `docs/CUSTOM-CLOTHING.md`. Until then,
every document in this repo must say the payload is still on the host, because
it is.
