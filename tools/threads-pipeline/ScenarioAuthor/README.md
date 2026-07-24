# ScenarioAuthor — headless GTA V / FiveM scenario-point authoring

Places **real ambient scenario points** into a scenario `.ymt` with **no CodeWalker
GUI** — the professional, reliable way to put seated/standing NPCs in an interior.
The game seats/poses peds on scenario points perfectly (alignment is baked into the
point), which script-spawned `TaskStartScenario` peds never do reliably.

Built on `CodeWalker.Core` (net48). Reusable for any map/interior — this is the
NPC-population pipeline we can also sell.

## Why scenario points (not scripted peds)
- A scenario point carries position + heading + scenario type; the engine spawns an
  appropriate ped and plays the authored animation rooted exactly on the point.
- Seated NPCs on chairs "just work" — no per-model Z/heading offset guessing.
- Requires ambient scenario density > 0 on the server. PALM6: `qbx_density_overrides`
  ships `scenario = 0.7`, so points spawn. (A 0-density server would need scripted
  client-local peds instead — see `palm6_pd_life`.)

## Workflow
1. **Extract chair/anchor coords** for the room (e.g. from the MLO furniture via
   `YtypDump`), one `x y z headingDeg` per line:
   ```
   awk -F'\t' '$6=="press" && $1=="3297809923"{print $2,$3,$4,$5}' out/mrpd_interior.tsv > out/press_seats.txt
   ```
2. **Author** the points into the room's scenario ymt (the one registered via
   `data_file 'SCENARIO_POINTS_OVERRIDE_PSO_FILE'` — for NTeam MRPD that's
   `cfx-nteam-mrpd/scenario/mission_row.ymt`, which already streams and drives the lobby):
   ```
   dotnet run --project tools/threads-pipeline/ScenarioAuthor -- \
     addpoints <in.ymt> out/press_seats.txt PROP_HUMAN_SEAT_CHAIR out/out.ymt
   ```
   It only writes `out.ymt` if the **validation gate** passes.
3. **Deploy**: copy `out.ymt` over the streaming ymt, commit, push (auto-deploys).
4. Verify in-game; roll back with `git revert` if needed (original preserved in history).

## Commands
- `addpoints <ymt> <coords> <SCENARIO> <outYmt>` — author points, validate, write.
- `audit <ymt>` — TypeNames / PedModelSetNames / InteriorNames counts + how many
  points carry an interior/model-set (regression check).
- `dumpseat <ymt> <SCENARIO>` — list positions of points of a given type.
- `resave <ymt> [outYmt]` / `roundtrip <ymt>` — Save round-trip sanity checks.
- `probe*` — reflection dumps of the CodeWalker structures (dev only).

## The gotchas (each was a required fix — don't relearn them)
1. **Clone, don't mutate.** Build new points via the copy ctor
   `new MCScenarioPoint(region, srcPoint)`. Setting an existing node's `.Position`
   via reflection corrupts it (reload → null MyPoint).
2. **`Save()` rebuilds EVERY lookup table from the points' resolved refs.** A headless
   `Load` sets only the numeric ids (TypeId/ModelSetId/…), leaving the refs null, so a
   plain resave DROPS TypeNames/PedModelSetNames/InteriorNames/GroupNames. You MUST
   repopulate refs on **every existing point** from its loaded index:
   - `Type` = `ScenarioTypeRef(ScenarioType{NameHash})` (parameterless ctors, settable NameHash)
   - `ModelSet` = `AmbientModelSet{NameHash}` (same pattern)
   - `InteriorName` / `GroupName` = `MetaHash` (only when Id > 0; Id 0 = none; TypeId 0 is real)
3. **`ScenarioRegion.BuildNodes()` + `BuildBVH()` + `BuildVertices()` AFTER adds**, before
   Save — else Save's lookup rebuild reads the stale load-time node list and new types
   never register.
4. **A malformed scenario ymt crashes every client on join.** The `addpoints` validation
   gate reloads the saved bytes and refuses to write unless: TypeNames intact + contains
   the new type, point count exact, all N new points present, and ModelSets/Interiors and
   their point associations did not regress vs the original. Never bypass it.
