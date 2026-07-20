# palm6_business — player-owned businesses

The civilian **business-ownership** layer that neither Qbox nor `qbx_management`
ships. `qbx_management` gives society bank accounts + boss menus for the
whitelisted *jobs* (police/EMS/mechanic); this gives a player a business they
**register and run** as a career: a registry, a pooled account, employees,
payroll, walk-in revenue, and a full ledger.

Delivers the site's repeated promises: "Own a business — employ citizens, meet
payroll", "Business Ledger (revenue/expenses/payroll)", "OWN THE ROOM — turn a
venue into an institution", "a business can outlive a crew", and the
Restaurant/Nightlife/Dealership owner careers.

Built on the `palm6_gangs` player-run-org pattern (own tables + a framework
bridge + an ox_lib menu). Design spec:
`docs/superpowers/specs/2026-07-20-palm6-business-design.md`.

## Ships DARK
`Config.Enabled = false` (shared/config.lua). Prod-inert: `/business` refuses,
every net event early-returns, nothing player-facing registers. Flip `true` +
redeploy to go live (batched with a feel-test). Revert = flip `false`.

## Money safety (the whole point)
A business account is **pooled real money, never minted** — the site's core
economic claim. Money enters ONLY via:
- owner **deposit** (owner bank → business, `ChargeBank` charge-before-credit)
- customer **charge** (player bank → business, the payer confirms)
- **NPC walk-in income** — the ONE faucet, bounded four ways (below)

Money leaves via **withdraw** / **payroll** (business → player, atomic guarded
debit that can't overdraw) and **stock purchase** (owner bank → supply, a SINK).
Every move writes a `palm6_business_ledger` row. All client amounts are
NaN/Inf-sanitized before any guard.

### The NPC-income faucet, bounded
1. **Cost basis** — NPC income needs `supply_units > 0`; supply is bought with
   the owner's clean bank money (`StockUnitCost` each = a sink). Margin/unit =
   `ServePayout - StockUnitCost`, bounded and small. You can't earn without first
   spending.
2. **Active work** — a serve needs a **clocked-in** worker doing a skill-check;
   no AFK minting.
3. **Per-worker cooldown** — `ServeCooldownSec` between serves.
4. **Per-business daily cap** — `DailyNpcIncome` (UTC `day_key` reset), enforced
   atomically in the serve UPDATE.

## Player commands
- `/business` (alias `/biz`) — opens the menu. Non-members can register; owners
  get Account / Employees / Operations / Ledger / Rename; employees get Clock
  in/out / Serve / Charge / Ledger / Resign.

## Phase 1 — physical storefronts (ships DARK behind `Config.Phase1Enabled`)
Turns a business from a menu-anywhere into a **place**.
- **Owner marks a location** from the menu (*Storefront → Place / Move here*). The
  server captures the owner's **real ped coords + heading** — never a
  client-supplied coordinate. A public **map blip** + a **walk-up interaction
  point** spawn there for everyone.
- **Blip cosmetics** — the owner picks an icon + colour from
  `Config.Storefront.Sprites` / `.Colors`; the server rejects anything outside
  those allowlists.
- **Proximity gate** — once a storefront is placed, day-to-day management (account,
  employees, operations, clock, ledger) and **NPC serving** require being **within
  `Config.Storefront.Radius`** of it. *Registering* and *placing / moving /
  removing* the storefront are always reachable, so **an owner can never lock
  themselves out.**
- **Walk-up** — staff opening the target get the management menu (still gated by
  proximity); a passerby gets a read-only info card (name / type / owner) — no
  roster or balance leak.
- **Gating** — requires **both** `Config.Enabled` **and** `Config.Phase1Enabled`.
  With Phase 1 off, a business with no storefront row behaves exactly as Phase 0.
- **No money** moves anywhere in the storefront layer — it is presentation +
  location only; the account/faucet invariants are untouched.

`Config.Phase1Enabled = false` by default — flip `true` + redeploy after the
Phase-1 feel-test.

## Server exports (seams for later phases)
- `exports.palm6_business:GetBusinessOf(citizenid)` → summary | nil
- `exports.palm6_business:Charge(businessId, payerCid, amount, memo)` → bool
  (generic player→business revenue; used by `palm6_protection` extortion later)
- `exports.palm6_business:GetAccountBalance(businessId)` → int
- `exports.palm6_business:GetStorefront(businessId)` → `{x,y,z,h}` | nil (Phase 1;
  for a future greeter ped / delivery target / extortion "shake down the shop")

## Tables (dbmigrate 0068 + 0070)
`palm6_businesses`, `palm6_business_members`, `palm6_business_ledger` (0068).
Phase 1 adds `loc_x/loc_y/loc_z/loc_h` + `blip_sprite/blip_color` to
`palm6_businesses` via `0070` (`ADD COLUMN IF NOT EXISTS`, all nullable). All
idempotent in `palm6_dbmigrate`.

## Still deferred (Phase 1 remainder / Phase 2)
Per-type mechanics (dealership lot / bar venue window / garage repairs),
`palm6_protection` extortion of owned businesses, store-SKU cosmetics (nameplate,
storefront skin, Discord business-registry badge), a manager delegate role, and a
website `/business` directory page.
