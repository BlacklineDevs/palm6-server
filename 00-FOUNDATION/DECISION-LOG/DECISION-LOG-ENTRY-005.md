# Decision Log Entry 005

**Date:** 2026-07-18
**Decision ID:** DEC-005
**Decision:** Resolve open blocker DEC-002a by declaring the canonical repository
identity for each of the four Palm6 repos (Main / Server, Discord Bot, Website,
Commercial Scripts). This is a process/identity ruling; it moves no code and creates
no repo by itself.
**Status:** Approved (process/identity) - decided by David Olverson, 2026-07-18 (session
directive). No physical repo is created, renamed, or migrated by this entry; any such
action is a separate future step requiring David's GitHub admin access.
**Owner:** David Olverson (Palm6 Creative + Dev Lead).
**Basis:** DEC-002 open item "DEC-002a"; repo facts verified 2026-07-18 via `gh` + `git`
against the working clone `C:/Users/Mgtda/Projects/Active/gtarp`.

## Context
DEC-002 registered two owner-decision blockers. DEC-002b was resolved by the v39 spec
itself (Master Plan rule #9: no Phase 4/5/6; a single Cross-Repo Consistency Pass runs
once after all repos finish Phase 3). DEC-002a (the canonical remotes for Website and
Commercial Scripts, plus confirmation of Main and Bot) stayed open and gated the
downstream repos. This entry closes it with verified ground truth, so the identity of
every Palm6 repo is now fixed and unambiguous.

## Verified repo facts (2026-07-18, gh + git)
- **Main / Server:** `BlacklineDevs/gtarp` - PUBLIC, live, deployed. This repo.
- **Discord Bot:** `BlacklineDevs/palm6-bot` - PRIVATE, live.
- **Website:** `davidolverson/palm6-web` - PRIVATE, actively pushed 2026-07-18. It is the
  ONLY live web repo. `BlacklineDevs/palm6-web` does NOT exist.
- **Commercial Scripts:** no clean repo exists. `fivem-scripts` has no remote (local-only,
  absent); `davidolverson/gta-rp-bot-kit` is stale (last push 2026-04-30) and misnamed
  (it is a bot-kit, not a scripts repo).

## The ruling (canonical identity per repo)
1. **Main / Server = `BlacklineDevs/gtarp`.** CANONICAL, confirmed live. (Already used;
   this entry ratifies it.)
2. **Discord Bot = `BlacklineDevs/palm6-bot`.** CANONICAL, confirmed live.
3. **Website = `davidolverson/palm6-web`.** CANONICAL. It is the only live web repo and is
   actively pushed, so it is the restructuring target as-is. An OPTIONAL future migration
   into the `BlacklineDevs` org is desirable for org hygiene but is NOT required to
   proceed; it is logged as low-priority creative/ops debt, not a blocker.
4. **Commercial Scripts = (to be created) `BlacklineDevs/palm6-scripts`.** No canonical
   repo exists yet. The canonical repo will be a NEW `BlacklineDevs/palm6-scripts`,
   created only when the Commercial Scripts phase actually begins (far downstream, gated
   behind Website Phase 3). The stale/misnamed `davidolverson/gta-rp-bot-kit` is explicitly
   NOT to be reused as-is. This is a deferred create, not a blocker to current work.

## Effect on DEC-002
- **DEC-002a is RESOLVED by this entry.** The four canonical identities are fixed above.
- DEC-002b remains resolved by the v39 spec (see DEC-003); no further action.

## Scope and non-actions (important)
- This is a naming/identity decision. No code is moved, no repo is renamed, created, or
  migrated by DEC-005.
- The Website org migration (item 3) and the `palm6-scripts` creation (item 4) are future
  steps that each need David's GitHub admin action at the time the relevant phase begins.
- Nothing here promotes or approves any System A / logo-dependent asset. The System A core
  identity mark still does not exist and stays Candidate under CD-001; DEC-005 does not
  touch that ladder.

## Related documents
DEC-002 (blocker registration; DEC-002a now resolved here); DEC-003 (numbering
reconciliation + DEC-002b note); `14-OPERATIONS/CREATIVE-DEBT-TRACKING.md` (CD-004
now resolved by this entry, CD-007 Website org-migration debt, CD-001 for System A);
Palm6 Restructuring Handoff Package v39, Master Restructuring Plan (canonical phase
model and the Cross-Repo Consistency Pass; external source, not committed to this repo).
