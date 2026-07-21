-- ============================================================================
-- palm6_eventguard/config.lua
--
-- Per-event ratelimits. Every guarded event has a (calls, window_seconds)
-- budget. Exceeding the budget drops the event AND increments the
-- violation counter; persistent offenders are auto-kicked at
-- KickThreshold breaches in a single session.
-- ============================================================================

Config = {}

Config.KickThreshold = 3

-- Only list events some resource actually registers as NET events
-- (RegisterNetEvent) — the guard hooks with AddEventHandler, so a name
-- nothing net-registers can never fire and its budget is dead weight.
-- The legacy qb-core names (QBCore:Server:UpdateMoney / SetMetaData /
-- OnJobUpdate) were removed 2026-07-03: Qbox never registers them as net
-- events (money is server-authoritative via qbx_core AddMoney/RemoveMoney;
-- OnJobUpdate is an internal TriggerEvent), so those guards were inert
-- since they shipped.
Config.Events = {
    -- palm6 custom layer events
    ['palm6_courier:post']     = { calls = 5,  window_seconds = 60  },
    ['palm6_courier:accept']   = { calls = 10, window_seconds = 60  },
    ['palm6_courier:pickup']   = { calls = 20, window_seconds = 60  },
    ['palm6_courier:complete'] = { calls = 20, window_seconds = 60  },
    ['palm6_courier:cancel']   = { calls = 10, window_seconds = 60  },

    -- palm6_robbery — ATM two-phase flow. `complete` is the money-touching
    -- event (Bridge.AddCash payout); `start`/`cancel` are budgeted too since
    -- they drive the police dispatch fan-out and the per-ATM cooldown
    -- reservation. ensure order in custom.cfg puts palm6_eventguard before
    -- palm6_robbery, so these guards register first in the handler chain.
    ['palm6_robbery:start']    = { calls = 10, window_seconds = 60 },
    ['palm6_robbery:complete'] = { calls = 10, window_seconds = 60 },
    ['palm6_robbery:cancel']   = { calls = 10, window_seconds = 60 },

    -- palm6_mechanic — repair-invoice flow. `complete`/`confirmInvoice` SEND the
    -- invoice offer to the customer; the MONEY-touching event is `acceptInvoice`
    -- (Bridge.ChargeBank customer / Bridge.CreditBank mechanic), gated in-resource
    -- by an atomic offer-consume + per-customer cooldown. Budgets sized generously
    -- so a busy on-duty mechanic working multiple vehicles isn't throttled.
    ['palm6_mechanic:start']         = { calls = 20, window_seconds = 60 },
    ['palm6_mechanic:complete']      = { calls = 20, window_seconds = 60 },
    ['palm6_mechanic:acceptInvoice'] = { calls = 20, window_seconds = 60 },
    ['palm6_mechanic:cancel']        = { calls = 10, window_seconds = 60 },

    -- palm6_turf — territory capture two-phase flow. `complete` writes
    -- palm6_turf (owner_gang flip = the reputation payout). `requestSync`
    -- is read-only but fans a full zone snapshot out per call — same
    -- "blunt budget as defense-in-depth" reasoning as ox_inventory below.
    ['palm6_turf:requestSync'] = { calls = 20, window_seconds = 30 },
    ['palm6_turf:requestTag']  = { calls = 10, window_seconds = 60 },
    ['palm6_turf:complete']    = { calls = 10, window_seconds = 60 },
    ['palm6_turf:cancel']      = { calls = 10, window_seconds = 60 },

    -- palm6_drugs — Schedule I supply chain. The money/item-touching events
    -- are `plant`/`harvest` (grant items), `mix`/`mixRecipe` (mint product),
    -- and `sell` (dirty-cash payout); `plotMenu`/`mixMenu`/`sellMenu` are
    -- read-only snapshots that fan a DB read + inventory scan per call, so they
    -- get a blunt call-count budget as defense-in-depth (same reasoning as
    -- ox_inventory:openInventory below). Each event has its own per-player
    -- server-side cooldown too. ensure order in custom.cfg MUST put
    -- palm6_eventguard before palm6_drugs so these guards register first in the
    -- handler chain (same requirement as palm6_robbery/turf above).
    ['palm6_drugs:plotMenu']  = { calls = 30, window_seconds = 30 },
    ['palm6_drugs:plant']     = { calls = 15, window_seconds = 60 },
    ['palm6_drugs:water']     = { calls = 30, window_seconds = 60 },
    ['palm6_drugs:harvest']   = { calls = 20, window_seconds = 60 },
    ['palm6_drugs:mixMenu']   = { calls = 20, window_seconds = 30 },
    ['palm6_drugs:mix']       = { calls = 15, window_seconds = 60 },
    ['palm6_drugs:mixRecipe'] = { calls = 15, window_seconds = 60 },
    ['palm6_drugs:sellMenu']  = { calls = 20, window_seconds = 30 },
    ['palm6_drugs:sell']      = { calls = 20, window_seconds = 60 },

    -- palm6_drugs drying rack (Phase-2 → Heavenly quality). `dryStart` consumes
    -- a fresh bud stack into a palm6_drugs_processes wall-clock timer; `dryCollect`
    -- grants the dried (Heavenly) buds back on the atomic collect claim;
    -- `dryMenu` is a read-only snapshot that fans a per-slot DB read + inventory
    -- scan per call, so it gets a blunt call-count budget as defense-in-depth
    -- (same reasoning as the menu events above). Each has its own per-player
    -- server-side cooldown too; same ensure-order requirement (palm6_eventguard
    -- before palm6_drugs).
    ['palm6_drugs:dryMenu']    = { calls = 20, window_seconds = 30 },
    ['palm6_drugs:dryStart']   = { calls = 15, window_seconds = 60 },
    ['palm6_drugs:dryCollect'] = { calls = 20, window_seconds = 60 },

    -- palm6_drugs meth cook lab (§9). `cookStart` consumes the precursor stack
    -- into a palm6_drugs_processes (kind='cook') wall-clock timer; `cookCollect`
    -- mints the crystal. Same shape/limits as the drying rack (load palm6_eventguard
    -- before palm6_drugs so these register first).
    ['palm6_drugs:cookMenu']    = { calls = 20, window_seconds = 30 },
    ['palm6_drugs:cookStart']   = { calls = 15, window_seconds = 60 },
    ['palm6_drugs:cookCollect'] = { calls = 20, window_seconds = 60 },

    -- palm6_drugs NPC dealer (Phase 2) — a passive dirty-cash faucet. `dealerMenu`
    -- is a read-only snapshot (fans a DB read + lazy sale resolve); hire/stock/
    -- collect/fire each touch money or the stash. Load-order: ensure
    -- palm6_eventguard before palm6_drugs so these register first.
    ['palm6_drugs:dealerMenu']    = { calls = 20, window_seconds = 30 },
    ['palm6_drugs:dealerHire']    = { calls = 5,  window_seconds = 60 },
    ['palm6_drugs:dealerStock']   = { calls = 20, window_seconds = 60 },
    ['palm6_drugs:dealerCollect'] = { calls = 15, window_seconds = 60 },
    ['palm6_drugs:dealerFire']    = { calls = 5,  window_seconds = 60 },

    -- palm6_gangs — player-run gang management + shared CASH vault + rep. The
    -- money-touching events are `deposit`/`withdraw` (vault, re-validated +
    -- atomic server-side) and `create` (charges the founder's bank); the
    -- membership events (`invite`/`acceptInvite`/`declineInvite`/`leave`/`kick`/
    -- `promote`/`demote`/`disband`) all re-check rank server-side. `requestMenu`
    -- is read-only but fans a full DB-backed roster snapshot per call, so it
    -- gets a blunt call-count budget as defense-in-depth (same reasoning as
    -- ox_inventory:openInventory below). ensure order in custom.cfg MUST put
    -- palm6_eventguard before palm6_gangs so these guards register first in the
    -- handler chain (same requirement as palm6_robbery/turf/drugs above).
    ['palm6_gangs:requestMenu']    = { calls = 20, window_seconds = 30 },
    ['palm6_gangs:create']         = { calls = 5,  window_seconds = 60 },
    ['palm6_gangs:disband']        = { calls = 5,  window_seconds = 60 },
    ['palm6_gangs:invite']         = { calls = 15, window_seconds = 60 },
    ['palm6_gangs:acceptInvite']   = { calls = 10, window_seconds = 60 },
    ['palm6_gangs:declineInvite']  = { calls = 10, window_seconds = 60 },
    ['palm6_gangs:leave']          = { calls = 5,  window_seconds = 60 },
    ['palm6_gangs:kick']           = { calls = 15, window_seconds = 60 },
    ['palm6_gangs:promote']        = { calls = 15, window_seconds = 60 },
    ['palm6_gangs:demote']         = { calls = 15, window_seconds = 60 },
    ['palm6_gangs:deposit']        = { calls = 20, window_seconds = 60 },
    ['palm6_gangs:withdraw']       = { calls = 20, window_seconds = 60 },
    ['palm6_gangs:rename']         = { calls = 5,  window_seconds = 60 },

    -- palm6_market — the Commodity Exchange. `sell` pays CLEAN cash for raw
    -- goods; `refine` mints higher-value refined goods (money-touching once
    -- sold). Both are server-priced + server-proximity checked and already carry
    -- an atomic per-player cooldown; these budgets are defense-in-depth against a
    -- flood. `refine`'s server cooldown is 5s (=12/60s), so a 20/60s budget bounds
    -- a modified-client flood without ever clipping legitimate use. Load-order:
    -- ensure palm6_eventguard before palm6_market so this guard registers first in
    -- the handler chain.
    ['palm6_market:sell']          = { calls = 20, window_seconds = 60 },
    ['palm6_market:refine']        = { calls = 20, window_seconds = 60 },

    -- palm6_yard — prison economy. `doLabor`/`buyCommissary` move small cash and
    -- carry persisted per-char cooldowns; `postBail` moves a large sum + releases,
    -- so it gets the tightest budget. All three are server-authoritative (shave,
    -- price, bail all server-computed; client sends no amounts). Load-order:
    -- ensure palm6_eventguard before palm6_yard so these register first.
    ['palm6_yard:server:doLabor']       = { calls = 20, window_seconds = 60 },
    ['palm6_yard:server:buyCommissary'] = { calls = 20, window_seconds = 60 },
    ['palm6_yard:server:postBail']      = { calls = 6,  window_seconds = 60 },

    -- palm6_grind — resource gathering + sale. `sell` pays clean cash for raw
    -- goods; `gather` grants the raw item. Both are server-priced/validated and
    -- carry their own per-player cooldown; these blunt budgets are defense-in-depth
    -- against a modified-client flood (palm6_eventguard ensures before palm6_grind).
    ['palm6_grind:gather'] = { calls = 30, window_seconds = 60 },
    ['palm6_grind:sell']   = { calls = 20, window_seconds = 60 },

    -- palm6_pumpcoin — memecoin exchange. `buy`/`sell` move bank cash against the
    -- bonding curve; `mint` creates a new coin (rare, charges a mint fee). Each is
    -- server-priced with its own cooldown/lock; budgets are defense-in-depth. `mint`
    -- is a one-off creation so a tighter budget still never clips legit use.
    ['palm6_pumpcoin:buy']  = { calls = 20, window_seconds = 60 },
    ['palm6_pumpcoin:sell'] = { calls = 20, window_seconds = 60 },
    ['palm6_pumpcoin:mint'] = { calls = 5,  window_seconds = 60 },

    -- palm6_flashdrop — hype-drop sneaker market. `finishCheckout` (primary buy),
    -- `consign:buy` (secondary-market buy) and `fence:sell` (fence payout) all move
    -- money; each is server-priced + consume-before-grant with its own cooldown.
    ['palm6_flashdrop:finishCheckout'] = { calls = 15, window_seconds = 60 },
    ['palm6_flashdrop:consign:buy']    = { calls = 15, window_seconds = 60 },
    ['palm6_flashdrop:consign:list']   = { calls = 15, window_seconds = 60 },
    ['palm6_flashdrop:fence:sell']     = { calls = 15, window_seconds = 60 },

    -- palm6_counterfeit — counterfeit-cash chain. `printer:finish` collects a
    -- printed run, `sink:spend` launders/spends fake bills, `fence:pass` passes to
    -- a fence; each moves item/money and is server-validated with its own cooldown.
    ['palm6_counterfeit:printer:finish'] = { calls = 15, window_seconds = 60 },
    ['palm6_counterfeit:printer:feed']   = { calls = 20, window_seconds = 60 },
    ['palm6_counterfeit:sink:spend']     = { calls = 20, window_seconds = 60 },
    ['palm6_counterfeit:fence:pass']     = { calls = 20, window_seconds = 60 },

    -- palm6_witnesses — `payoff` pays a witness to recant (bank cash out),
    -- server-validated with its own cooldown. Blunt budget as defense-in-depth.
    ['palm6_witnesses:payoff'] = { calls = 15, window_seconds = 60 },

    -- ox_inventory shop purchase fan-out — recipe-shipped net event.
    -- ox_inventory does its own per-event data validation (Utils.LogExploit);
    -- this blunt call-count budget is defense-in-depth on top.
    ['ox_inventory:openInventory'] = { calls = 30, window_seconds = 30 },

    -- palm6_onboarding — the accept event writes palm6_onboarding and
    -- (first time only) credits starter cash. A real accept only ever
    -- fires once per citizen; the budget just bounds retry/replay spam
    -- from a modified client on top of the resource's own UNIQUE(citizenid)
    -- guard and its own tighter Config.AcceptCooldownSec.
    ['palm6_onboarding:acceptRules'] = { calls = 3, window_seconds = 60 },

    -- palm6_onboarding:checkStatus — fires once per normal player load
    -- (client-side Game.OnPlayerLoaded) but is a bare client-addressable
    -- net event with NO in-resource rate limit (unlike acceptRules, which
    -- has its own Config.AcceptCooldownSec on top of this). It does a real
    -- DB read every call. Found during the independent harden pass on
    -- palm6_onboarding — same "blunt budget as defense-in-depth" reasoning
    -- as ox_inventory:openInventory above.
    ['palm6_onboarding:checkStatus'] = { calls = 10, window_seconds = 60 },

    -- evidence:server:CreateCasing — recipe-shipped net event (qbx_police).
    -- palm6_gunrunning registers a second handler on it to cross-reference
    -- fired-weapon serials against its black-market sales registry. The
    -- handler only writes to palm6_evidence on a real serial match (a cheap
    -- read-only lookup otherwise), same "blunt budget as defense-in-depth"
    -- reasoning as ox_inventory:openInventory above — normal gunfire can
    -- legitimately fire this often, so the budget is sized generously.
    ['evidence:server:CreateCasing'] = { calls = 60, window_seconds = 60 },

    -- palm6_insurance — the Mors Mutual agent NPC menu. `agent:quote`/`claimList`/
    -- `policies` are read-only DB snapshots; `agent:buy` charges the tier premium
    -- and `agent:fileclaim` opens a claim (money). All re-run the exact server
    -- authority (rate limit, at-office, ownership, server-side price recompute) —
    -- these budgets are blunt defense-in-depth against a modified-client flood.
    -- ensure palm6_eventguard before palm6_insurance so these register first.
    ['palm6_insurance:agent:quote']     = { calls = 20, window_seconds = 60 },
    ['palm6_insurance:agent:buy']       = { calls = 10, window_seconds = 60 },
    ['palm6_insurance:agent:fileclaim'] = { calls = 10, window_seconds = 60 },
    ['palm6_insurance:agent:policies']  = { calls = 15, window_seconds = 60 },
    ['palm6_insurance:agent:claimList'] = { calls = 15, window_seconds = 60 },

    -- palm6_lottery — the City Lottery kiosk NPC menu. :data is a read-only
    -- snapshot (pot / your tickets / recent winners); :buy routes to cmdBuy,
    -- which re-runs the /lottery buy authority (rate limit, open-draw, bank
    -- charge, per-draw cap). Blunt DoS budgets; ensure palm6_eventguard before
    -- palm6_lottery so these register first.
    ['palm6_lottery:kiosk:data']    = { calls = 20, window_seconds = 60 },
    ['palm6_lottery:kiosk:buy']     = { calls = 15, window_seconds = 60 },
    ['palm6_lottery:kiosk:scratch'] = { calls = 20, window_seconds = 60 },

    -- palm6_gunrunning — the dealer NPC buy. Routes into cmdBuyWeapon (proximity
    -- + price + bank charge + serialized grant, all server-side). Own 10s spam
    -- guard already applies; this budgets the net-event surface too. eventguard
    -- ensures before palm6_gunrunning so this registers first.
    ['palm6_gunrunning:dealer:buy'] = { calls = 10, window_seconds = 60 },

    -- palm6_fc_combat — Def Jam fight-club engine (Phase 0). challenge/accept/
    -- decline/select are low-frequency MENU events → the normal kick model.
    -- The LIVE-combat events (strike/connect/block/break) fire many times a
    -- second per fighter and carry class='combat' so the guard DROPS an
    -- over-budget event WITHOUT the 3-strike session kick (see server/main.lua
    -- guard()): the server move-clock is the authority, and the §7 finisher
    -- :break mash would trip a kick model instantly. custom.cfg ensures
    -- palm6_eventguard BEFORE palm6_fc_combat so these register first in the
    -- handler chain (same requirement as palm6_robbery/turf/drugs/gangs above).
    ['palm6_fc_combat:challenge'] = { calls = 10, window_seconds = 60 },
    ['palm6_fc_combat:accept']    = { calls = 10, window_seconds = 60 },
    ['palm6_fc_combat:decline']   = { calls = 10, window_seconds = 60 },
    ['palm6_fc_combat:select']    = { calls = 15, window_seconds = 60 },
    ['palm6_fc_combat:strike']    = { calls = 60, window_seconds = 10, class = 'combat' },
    ['palm6_fc_combat:connect']   = { calls = 60, window_seconds = 10, class = 'combat' },
    ['palm6_fc_combat:block']     = { calls = 40, window_seconds = 10, class = 'combat' },
    ['palm6_fc_combat:break']     = { calls = 80, window_seconds = 10, class = 'combat' },

    -- palm6_business — player-owned businesses. Money-touching events are
    -- `deposit`/`withdraw`/`buyStock`/`serve`/`runPayroll`/`acceptCharge` (each
    -- server-re-validated + atomic + charge-before-credit); `register` charges
    -- the founder's bank; the rest are membership/menu. `serve` is the most
    -- frequent (repeated walk-in serving) so it gets the widest budget; its money
    -- is bounded server-side by supply/cooldown/daily-cap regardless. (The menu
    -- opens server-side via the /business command, not a net event, so there is
    -- no openMenu budget.)
    -- ensure order in custom.cfg puts palm6_eventguard BEFORE palm6_business so
    -- these guards register first in the handler chain.
    ['palm6_business:register']     = { calls = 5,  window_seconds = 60 },
    ['palm6_business:deposit']      = { calls = 20, window_seconds = 60 },
    ['palm6_business:withdraw']     = { calls = 20, window_seconds = 60 },
    ['palm6_business:buyStock']     = { calls = 20, window_seconds = 60 },
    ['palm6_business:serve']        = { calls = 40, window_seconds = 60 },
    ['palm6_business:clock']        = { calls = 15, window_seconds = 60 },
    ['palm6_business:hireNearest']  = { calls = 15, window_seconds = 60 },
    ['palm6_business:acceptHire']   = { calls = 10, window_seconds = 60 },
    ['palm6_business:fire']         = { calls = 15, window_seconds = 60 },
    ['palm6_business:setWage']      = { calls = 20, window_seconds = 60 },
    ['palm6_business:promote']      = { calls = 10, window_seconds = 60 },
    ['palm6_business:demote']       = { calls = 10, window_seconds = 60 },
    ['palm6_business:transfer']     = { calls = 5,  window_seconds = 60 },
    ['palm6_business:close']        = { calls = 5,  window_seconds = 60 },
    ['palm6_business:runPayroll']   = { calls = 10, window_seconds = 60 },
    ['palm6_business:chargeNearest']= { calls = 20, window_seconds = 60 },
    ['palm6_business:acceptCharge'] = { calls = 15, window_seconds = 60 },
    ['palm6_business:viewLedger']   = { calls = 20, window_seconds = 60 },
    ['palm6_business:rename']       = { calls = 5,  window_seconds = 60 },
    ['palm6_business:resign']       = { calls = 5,  window_seconds = 60 },
    -- Phase 1 storefronts. All owner-gated + re-validated server-side; none move
    -- money. `openHere` is the walk-up (staff open the menu, passersby get a card);
    -- `requestStorefronts` is a client-load pull, so both get a wider budget.
    ['palm6_business:setStorefront']      = { calls = 10, window_seconds = 60 },
    ['palm6_business:clearStorefront']    = { calls = 10, window_seconds = 60 },
    ['palm6_business:setBlip']            = { calls = 15, window_seconds = 60 },
    ['palm6_business:openHere']           = { calls = 40, window_seconds = 60 },
    ['palm6_business:requestStorefronts'] = { calls = 10, window_seconds = 60 },
    -- Robbery: server re-validates proximity + per-robber + per-business cooldown +
    -- balance + atomic guarded debit; a tight budget is belt-and-braces over those.
    ['palm6_business:rob']                = { calls = 6,  window_seconds = 60 },
    -- Phase 1b interiors. enter/exit re-validate storefront proximity + membership
    -- + shell existence server-side and move no money; a player may reasonably
    -- enter/leave repeatedly, so the budget is generous but still bounded (anti-spam
    -- on the teleport). setLayout is owner-only + allowlisted, so it is tight.
    ['palm6_business:enterInterior']      = { calls = 30, window_seconds = 60 },
    -- exitInterior is the ESCAPE direction: dropping it would strand a player in
    -- the bucket, so its budget is generous (well above any human enter/exit rate)
    -- — throttle the enter side, never the way out.
    ['palm6_business:exitInterior']       = { calls = 120, window_seconds = 60 },
    ['palm6_business:setLayout']          = { calls = 15, window_seconds = 60 },
}
