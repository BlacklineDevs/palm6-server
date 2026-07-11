# gtarp_gangs

Player-run **gang management + shared cash vault + reputation** for the Palm6
Qbox server. This is the layer Qbox does **not** ship.

## What Qbox already provides (and what we do NOT duplicate)

`qbx_core` owns the **static gang DATA model** — predefined gangs + grades in
shared config, `PlayerData.gang`, and `/setgang` — the exact analog of its
jobs. What it has **no concept of** is a gang that players **create and run
themselves**: membership management, a shared vault, and reputation. That is
precisely what `qb-gangs` / `ps-gangs` add to QBCore, and it is this resource's
entire scope.

We therefore build only the missing player-run layer on our **own** tables and
leave qbx_core's static registry untouched. Integration seam: the bridge reads
the qbx gang **read-only** (`Bridge.GetQbxGang`) and offers an **opt-in**,
best-effort mirror of membership into `PlayerData.gang`
(`Config.MirrorToQbxGang`, default **OFF** — it only "sticks" if the gang is
also registered in qbx_core's static registry, so it's off until an operator
wires that up; pcall-guarded so it can never corrupt state). Our tables stay
the authoritative source of truth for player-run gangs.

## Features

- **Create / disband** a gang: unique name (sanitised, length-limited,
  profanity-filtered) + tag; a bank-charged creation cost; leader-only disband.
- **Membership + ranks:** Leader / Officer / Member. Invite (server picks the
  closest eligible nearby player — client never names the target), accept,
  leave, kick (officer+, strictly-lower ranks only), promote/demote (leader).
  **One gang per player**, enforced at the schema level.
- **Shared CASH vault:** rank-gated deposit (any member) / withdraw (officer+),
  atomic + logged. Chosen over an ox_inventory stash for auditability.
- **Reputation:** a per-gang `rep` integer + a server-only `AddRep` export other
  resources call to reward gang activity (turf, protection, drugs, …).

## Server-authoritative guarantees

- Every action re-derives citizenid + rank **server-side** from the DB; the
  client never supplies gang id, rank, membership, or amounts it is trusted on.
- Vault deposits are **consume-before-credit** (cash pulled first, refunded if
  the vault write fails). Withdraws use an **atomic guarded decrement**
  (`vault_balance - ? WHERE vault_balance >= ?`, affected-rows == 1) so two
  same-tick withdraws can never both pass and the vault can't overdraft; a
  failed payout is rolled back into the vault.
- All SQL is parameterised. The three tables are indexed and restart-safe.

## Exports (server-only)

| Export | Returns |
|---|---|
| `GetGang(citizenid)` | `{ id, name, tag, rank, rankName, rep, vault, leaderCid }` or `nil` |
| `IsSameGang(cidA, cidB)` | `true` if both are in the same player-run gang |
| `AddRep(gangId, amount, reason)` | new rep (floors at 0), or `nil` if the gang is unknown |
| `GetSummary()` | `{ gangs, members, totalVault, topRep }` (for `/economy` + devtest) |

## Net events (all `gtarp_eventguard`-rate-limited)

`requestMenu`, `create`, `disband`, `invite`, `acceptInvite`, `declineInvite`,
`leave`, `kick`, `promote`, `demote`, `deposit`, `withdraw`.

## Command

- `/gang` — opens the gang menu (create if you have no gang; otherwise manage
  vault, members, ranks, invites, leave/disband).

## Tables (`sql/0041_gangs.sql`)

- `gtarp_gangs` — one row per gang (name, tag, leader_cid, vault_balance, rep).
- `gtarp_gang_members` — PK on `citizenid` (one gang per player), rank, cached name.
- `gtarp_gang_vault_log` — append-only vault ledger with balance snapshots.

(Prefixed `gtarp_` per the repo collision-avoidance convention — the QBCore
ecosystem's gang add-ons ship unprefixed `gangs`/`gang_members`, and an
unprefixed table has silently collided with a recipe resource here before.)

## Install

1. Apply `sql/0041_gangs.sql` to the server DB.
2. Add the ensure line to `custom.cfg` **after `qbx_core`**, near the other
   crime resources, and **after `gtarp_eventguard`** (so its rate-limit guards
   register before this resource's net events):

   ```
   ensure gtarp_gangs
   ```

   Recommended placement: alongside `gtarp_turf` / the other gang-adjacent
   crime resources, e.g. right after `ensure gtarp_turf`.

## GTA VI portability

Tier 2 (bridge rewrite). No world coords, blips, peds, or targets — pure
management over server-authoritative state. `bridge/sv_framework.lua` (framework
money/identity) and `bridge/cl_game.lua` (ox_lib UI) are the only files to
rewrite; all logic and our own SQL carry unchanged. See
`docs/GTA6-READINESS.md` §3.
