# palm6 repo invariant checker

Eight whole-repo facts that were each established **by hand**, at real cost, and
each of which was true only at the moment somebody checked it. This turns them
into one command.

```
node tools/audit/run.js
```

Exit code is 0 when every invariant holds and 1 otherwise, so it drops into CI
or a pre-push hook unchanged. **No dependencies** — `tests/` needs `fengari`,
this needs nothing, so it runs on a clean clone with nothing installed.

```
node tools/audit/run.js              # everything
node tools/audit/run.js tables       # one check, by id or substring
node tools/audit/run.js --list       # the ids, what each protects, key formats
node tools/audit/run.js --root PATH  # audit a different tree (a scratch copy)
node tools/audit/run.js --self-test  # prove every check can still FAIL
```

---

## What each invariant protects

| id | invariant | what it stops |
|---|---|---|
| `tables` | every `palm6_*` table a query names has a `CREATE TABLE` somewhere in this repo | A referenced-but-never-created table does not error loudly. Nearly every query here is `pcall`-wrapped, so the resource degrades to "does nothing". It looks fine on the live box, where the table already exists, and half a feature is silently dead on a fresh box or a restored backup. |
| `exports` | every cross-resource export call names a resource that exists, a function it really registers, and a realm the caller can reach | A call to a missing export is a nil-index; where the site is `pcall`-guarded it does not even error, the feature just never works. The realm half catches a client calling a server-only export, which can never resolve no matter how correct it looks. |
| `events` | the `palm6_*` event graph has no orphans | An event raised with no handler is a feature that silently does nothing. A handler nothing raises is dead code still holding a network name. Both parse, load and boot perfectly. |
| `stop-await` | no MySQL `.await` is reachable from an `onResourceStop` handler | `.await` is `Citizen.Await`: it yields, and teardown never resumes the coroutine. The first await in a stop handler silently abandons every row after it. Invisible until a deploy lands while several rows were dirty. |
| `command-aces` | restricted commands and `custom.cfg` ACE grants agree **both** ways | A `RegisterCommand(..., true)` with no `add_ace` is runnable by `group.owner` and nobody else, because owner holds the blanket `command` ace. Every admin and mod silently has no access. An `add_ace` for a command that no longer exists is the mirror image: it reads like coverage and grants nothing. |
| `eventguard` | every `palm6_eventguard` budget names a real net event, and the guard is ensured first | A budget for a name nothing `RegisterNetEvent`s is inert. So is a budget whose owning resource is ensured *before* `palm6_eventguard`, because `CancelEvent()` only stops handlers that have not run yet. Both look identical to a working ratelimit in the boot banner, which counts budgets, not effect. |
| `ensure-list` | `custom.cfg`'s ensure list and `resources/[custom]` agree | An `ensure` for a deleted directory is one lost line in a boot log of thousands. A resource directory nobody ensures is a feature that was built, merged and never ran. |
| `migrations` | migration numbering is consistent across **both** authorities | `sql/` is not the authority. `palm6_dbmigrate/server.lua` owns 0067 and 0068–0073, which have no `sql/` file at all. `ls sql/` shows an unbroken run to 0066 and then 0074, which reads exactly like "0067 is free". It is not. The check also verifies that where both authorities create the same table, the bodies still match, and prints the real next free number. |

---

## Traps this checker is built around

These are the ones that already caught people here. Each is handled in code, not
in a comment telling you to be careful.

**A literal-string grep misses a dynamic event raise.** This repo raises an
event name through a ternary:

```lua
TriggerServerEvent(ok and 'palm6_fc_combat:accept' or 'palm6_fc_combat:decline')
-- palm6_fc_combat/client/main.lua
```

A "first literal wins" reader credits `:accept` and then reports `:decline` as
an event nobody raises. There is no ternary special case here: the name argument
is read as **every literal in the first argument**, so both branches are
collected, and `Config.X or 'literal'` falls out of the same code. The self-test
plants exactly this shape and requires the second branch to be caught.

**A dynamic *registration* cannot be read at all.** Four sites register a handler
under a name held in a variable. Each is declared in `allowlist.js` with the
names it really resolves to and why. A **new** dynamic site that is not declared
there **fails** the check, so the blind spot cannot grow quietly.

**A declared fxmanifest dependency does not make an export call safe.**
`dependencies` only orders resources at boot. At runtime the target can be
stopped, restarted or crashed, and indexing a stopped resource's export raises.
The `exports` check therefore proves the target and the function exist and are
reachable from the calling realm — and **deliberately does not** rule on whether
a given call site is guarded. Most guards here are resource-local helpers that
wrap `pcall`, and a check that guesses at wrappers produces false accusations,
which is worse than no check. Read a green `exports` as "the name on the other
end is real", never as "this call is safe bare".

**Migration numbering has two authorities.** See the `migrations` row above. The
check reads `palm6_dbmigrate/server.lua` as a first-class source, not `sql/`
alone, and every number that only one authority owns is either reported or
recorded in `allowlist.js` with the reason.

**Comments in this repo quote code.** `custom.cfg` literally spells out grep
commands; several `config.lua` files name tables and events in prose. So nothing
here reads raw bytes: `lib/lualex.js` splits every file into a code stream and a
list of string literals, and **no check ever sees a comment**.

---

## The allowlist

Every deliberate exception lives in `tools/audit/allowlist.js` and nowhere else.
No check hardcodes a name.

```js
{
    check:  'tables',                 // a real check id
    key:    'palm6_founding_grants',  // the key the check prints on failure
    reason: 'Owned by the WEBSITE, not the game server. ...',
}
```

Enforced by `run.js`, not by good intentions:

- an entry with no `reason` (or a trivial one) **fails the whole run**;
- an entry naming a check id that does not exist **fails the whole run**;
- an entry that matched nothing this run is reported as **STALE**. A dead
  exception reads like coverage and grants none — delete it, or find out why the
  thing it excused stopped being reported.

Every failure message ends with the exact `allowlist key:` to use, so adding an
exception is copy-paste plus writing down why.

---

## When a check fails

1. **Read the offenders.** Every violation prints `file:line`. "3 violations"
   with no locations would be useless, so there is no such output here.
2. **Decide which of three things it is:**
   - *a real defect* → fix the code. That is the point.
   - *a deliberate exception* → add an `allowlist.js` entry with the printed key
     and a reason that says what makes it correct. "The check is noisy" is not a
     reason.
   - *a checker bug* → fix the check, then add a plant to `selftest.js` so the
     same bug cannot come back silently.
3. **Re-run.** `node tools/audit/run.js <id>` runs just that one.

---

## Proving it can fail

A gate that cannot fail is worse than no gate: it turns "nobody looked" into "it
passed". `node tools/audit/run.js --self-test` builds two synthetic repos in a
temp directory and runs all eight checks against both.

- **CLEAN** — a small, correct server layout. Every check must report **zero**
  violations. Without this half the failing half proves nothing, because a check
  that is simply always angry would pass it.
- **BROKEN** — the same layout with one deliberate violation planted per check
  (19 of them). Every check must report its planted key.

The self-test touches nothing outside a temp directory and never reads the real
repo.

For a demonstration against the real tree, copy the files the checker reads into
a scratch directory, sabotage the copy, and point `--root` at it:

```
node tools/audit/run.js --root /path/to/scratch-copy
```

Never plant a violation in the repo itself.

---

## How it works

```
tools/audit/
  run.js            CLI + reporting + allowlist enforcement
  allowlist.js      every deliberate exception, one reason each
  selftest.js       two synthetic repos: one clean, one with 19 planted faults
  checks/           one file per invariant
  lib/
    lualex.js       Lua/cfg/SQL scanner: code stream + string literals, no comments
    calls.js        reading arguments off a call site (incl. the ternary case)
    luablocks.js    Lua block matching and a per-resource call graph
    repo.js         one scan of the tree, shared by every check
    checks.js       check loading (its own module so selftest need not import run.js)
```

A check is a module with `id`, `title`, `protects`, `keyFormat` and
`run(repo, allow)`, returning `{ violations: [{key, what, where}], stats: [] }`.
`run.js` subtracts allowlisted keys and decides pass/fail. A check that **throws**
is counted as a failure and its stack is printed: a runner that exits 0 on a
crashed check is worse than no runner.

### Known limits, stated plainly

- **Realm classification** comes from the `*_scripts` blocks in each
  `fxmanifest.lua`. A file listed in no block is `unknown`, and no check draws a
  conclusion from an unknown file.
- **The `stop-await` call graph** resolves by name, within one resource, within
  the server realm. It does not follow a call through a table field held in a
  local, and it cannot follow a boolean argument into a branch — which is why
  the two `inline`-flag callees in this repo are allowlisted rather than
  silently ignored. Every one of these limits makes the check **miss** things.
  None of them makes it invent things, which is the direction that matters.
- **`events` and `tables` rule on `palm6_*` names only.** A name owned by a
  recipe resource (`police:server:policeAlert`, `players`, `player_vehicles`)
  has producers and consumers outside this repo, so this tree cannot rule on it.
- **`exports` says nothing about out-of-repo targets** (`ox_target`, `qbx_core`,
  `Renewed-Banking`, …). Their export lists are not in this repo.
- This is a **static** checker. It never connects to the database, never starts
  the server, and never reads a world coordinate.
