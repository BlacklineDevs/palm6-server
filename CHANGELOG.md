# Changelog — Horizon (gtarp server)

All notable changes to the Horizon RP server's custom layer. **This is the
source of truth we post from** — every entry has an internal/technical list for
tracking *and* a ready-to-post **📣 Public** blurb (player-facing, no jargon) for
the Discord `#「📝」updates` channel, the website, and public announcements.

Format: newest first. Dates are EDT.

---

## 2026-07-10 — Economy anti-exploit hardening + coord retune

A server-wide adversarial audit of the money-handling systems (find →
independently verify → fix), plus real-location retuning of placeholder coords
and a continued bridge-pattern rollout. **8 confirmed-exploitable bugs fixed;
the other 12 audited resources came back clean.**

**Tracking (internal):**
- 🔴 **gtarp_courier** — fixed a **critical double-payout race**: `complete` now
  atomically gates the `UPDATE` on `status='taken' AND courier_citizenid` and only
  pays when rows-affected == 1. Same guard on cancel-refund and both lifetime sweeps.
- **gtarp_insurance** — policy is now consumed on claim (one payout per policy);
  no-scene damage claims are hard-denied instead of trusting client health.
- **gtarp_chopshop** — closed a free-money faucet: ambient/NPC cars (no
  `player_vehicles` row, no active stolen report) can no longer be sold.
- **gtarp_bounty** — fixed a city-money faucet: captured state contracts update in
  place (`status IN ('active','claimed')`) instead of re-posting every sweep.
- **gtarp_mechanic** — repairs now require a **customer consent handshake**
  (offer → confirm → accept, re-validated server-side) plus a per-customer cooldown;
  a mechanic can no longer force-charge a non-consenting nearby player.
- 🧩 **Bridge pattern** — extended to `ox_inventory_overrides` (isolated its
  `ox_inventory`/`ox_target`/native calls behind `bridge/`), per GTA6-readiness. The
  other candidate resources already had adapters.
- 📍 **Coord retune** — replaced Tier-3 placeholder map coords with real Los Santos
  locations across bounty, fightclub, gunrunning, laundering, loanshark, numbers,
  protection, and robbery. All flagged `VERIFY IN-GAME`.
- Audited clean (no fixes needed): laundering, numbers, loanshark, protection,
  seizure, smuggling, pumpcoin, economy, ransom, gunrunning, counterfeit, grind.

**📣 Public:**
> 🔧 **Server maintenance — economy hardening**
> We ran a full security sweep of the crime economy and patched several money
> exploits (courier payouts, insurance claims, chop-shop, bounties). Repairs from
> mechanics now ask for your approval before charging you. Plus we moved a bunch of
> racket locations to their real spots around the city. Cleaner, fairer hustle. 💰

## 2026-07-10 — 🌿 New: `gtarp_drugs` (Schedule I-style) — _in progress_

Building the missing drug supply chain — a faithful adaptation of **Schedule I**:
grow → **mix base drugs with additives to create branded products with stacking
effects + quality tiers** → sell → build a customer base → hire dealers → launder →
dodge heat → rank up. Design locked in `docs/DRUGS-SPEC.md`; MVP (weed grow → mix →
sell → dirty cash → laundering + heat) building now.

**📣 Public:** _drafting for launch — big one coming._

<!-- Template:
## YYYY-MM-DD — <title>
**Tracking (internal):**
- <change> (`resource`)
**📣 Public:**
> 🎮 <player-facing line(s)>
-->
