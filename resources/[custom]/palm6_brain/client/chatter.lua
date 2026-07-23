-- ============================================================================
-- palm6_brain/client/chatter.lua — PHASE 5: Ambient NPC-to-NPC chatter.
--
-- Nearby AMBIENT pedestrians occasionally exchange a short "overheard" line as a
-- floating text bubble, so the street reads as conversational and alive instead of
-- a crowd of mimes on scenarios. Zero AI, zero network, zero cost: the lines come
-- from a small CANNED POOL below (no LLM, no HTTP), and everything is CLIENT-LOCAL.
--
-- DESIGN (cheap + no spam):
--   • ONE slow scan loop (every CFG.IntervalSec) sweeps GetGamePool('CPed'), keeps
--     only non-player, alive, on-foot peds within CFG.Range of the PLAYER, then
--     fires AT MOST ONE chatter event — a single line, or a two-line PAIR exchange.
--   • A bubble render loop (Wait(0)) ONLY runs while a bubble is actually active; it
--     self-terminates the instant the last bubble expires, so idle cost is nil.
--   • Hard throttle: the scan loop itself waits CFG.IntervalSec between events, and
--     `lastPed` blocks the same ped talking twice back-to-back.
--
-- DARK-SHIP: CFG.Enabled = false ships inert (loop returns immediately, nothing
-- renders). ALSO gated on Config.Enabled (the master brain gate) so chatter can
-- never run unless the whole living-world system is on. A coordinator may later
-- promote this local CFG into shared/config.lua (e.g. Config.Chatter) and repoint
-- the reads — the flag names below are chosen to map 1:1.
--
-- SELF-CONTAINED: client/main.lua's helpers (drawText3D, spawned, named, movers)
-- are file-local and invisible here, so this file carries its OWN tiny copies of
-- what it needs (drawTextBubble, bubble state) and touches no other file.
-- ============================================================================

-- Dark-ship config. A coordinator may promote this to Config.Chatter and repoint.
local CFG = {
    Enabled     = true,   -- LIVE: ambient overheard chatter ON (also requires Config.Enabled).
    IntervalSec = 12,     -- Global floor between chatter events (hard anti-spam throttle).
    Range       = 25.0,   -- Only peds within this many metres of the PLAYER may chatter (must be observed).
    BubbleSeconds = 4.0,  -- How long each overheard line floats above a ped's head.
    PairChance  = 0.4,    -- Chance an event is a two-ped EXCHANGE (else a single overheard line).
}

-- Canned, brand-safe, PG-13, fictional street chatter. No real brands, no slurs,
-- nothing offensive — generic overheard small-talk that fits any city sidewalk.
local LINES = {
    "You catch the game last night?",
    "Traffic's been brutal all week.",
    "I swear this coffee gets pricier every day.",
    "Did you ever hear back about that job?",
    "It's supposed to rain later, bring a jacket.",
    "My cousin's in town, we're grabbing lunch.",
    "This block's changed a lot, huh?",
    "You still living over on the east side?",
    "Long day. I just wanna get home.",
    "New place opened up around the corner.",
    "Weekend can't come fast enough.",
    "Tell your sister I said hey.",
}

-- Second half of a two-line exchange — short, generic replies to any opener above.
local REPLIES = {
    "Ha, tell me about it.",
    "Yeah, wild right?",
    "For real though.",
    "You know how it is.",
    "Same here, honestly.",
    "Right? Every time.",
    "No kidding.",
    "We should catch up soon.",
}

-- ---------------------------------------------------------------------------
-- Bubble state + render (self-contained; does NOT reuse main.lua's private one).
-- ---------------------------------------------------------------------------
local bubbles = {}          -- ped -> { text = , expire = }  (active floating lines)
local bubbleThread = false  -- render loop only spins while a bubble is live
local lastEventAt  = 0      -- GetGameTimer() ms of the last fired event (global throttle)
local lastPed      = nil    -- ped that spoke last event (no back-to-back repeat)

-- Reimplements main.lua's drawText3D locally (its copy is file-private).
local function drawTextBubble(x, y, z, text)
    SetDrawOrigin(x + 0.0, y + 0.0, z + 0.0, 0)
    SetTextScale(0.32, 0.32)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(235, 235, 235, 200)
    SetTextCentre(true)
    SetTextEntry('STRING')
    AddTextComponentSubstringPlayerName(text)
    DrawText(0.0, 0.0)
    ClearDrawOrigin()
end

local function startBubbleThread()
    if bubbleThread then return end
    bubbleThread = true
    CreateThread(function()
        while bubbleThread do
            local now = GetGameTimer()
            local any = false
            for ped, b in pairs(bubbles) do
                if not DoesEntityExist(ped) or now > b.expire then
                    bubbles[ped] = nil          -- expired or ped gone -> drop it
                else
                    any = true
                    local c = GetEntityCoords(ped)
                    drawTextBubble(c.x, c.y, c.z + 1.0, b.text)
                end
            end
            if not any then bubbleThread = false break end   -- nothing left -> stop spinning
            Wait(0)
        end
    end)
end

local function sayBubble(ped, text)
    if not (ped and DoesEntityExist(ped)) then return end
    bubbles[ped] = { text = text, expire = GetGameTimer() + math.floor(CFG.BubbleSeconds * 1000) }
    startBubbleThread()
end

local function pick(t) return t[math.random(#t)] end

-- Collect ambient candidates: real non-player peds, alive, on-foot, within Range of
-- the player. Defensive throughout — never errors on an empty/garbage pool.
local function nearbyChatterPeds()
    local me = PlayerPedId()
    if not me or me == 0 then return nil end
    local mc = GetEntityCoords(me)
    local out = {}
    local pool = GetGamePool('CPed')
    if not pool then return out end
    for _, ped in ipairs(pool) do
        if ped and ped ~= me
            and DoesEntityExist(ped)
            and not IsPedAPlayer(ped)
            and not IsEntityDead(ped)
            and not IsPedInAnyVehicle(ped, false)
            and ped ~= lastPed
            and #(GetEntityCoords(ped) - mc) <= CFG.Range then
            out[#out + 1] = ped
        end
    end
    return out
end

-- Fire one chatter event: a single overheard line, or (PairChance) a two-line
-- exchange between two nearby peds with a short beat between them.
local function fireChatter(cands)
    local a = pick(cands)
    if not a then return end
    sayBubble(a, pick(LINES))
    lastPed = a
    -- Optionally make it a tiny exchange with a second, distinct ped.
    if #cands > 1 and math.random() < CFG.PairChance then
        local b
        for _ = 1, 4 do local c = pick(cands); if c ~= a then b = c break end end
        if b then
            CreateThread(function()               -- short beat, then the reply
                Wait(math.random(1200, 2000))
                if DoesEntityExist(b) then sayBubble(b, pick(REPLIES)) end
            end)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Scan loop — throttled, cheap. Set at load from the master gate (stable, no race).
-- ---------------------------------------------------------------------------
local running = (Config.Enabled == true) and CFG.Enabled

CreateThread(function()
    -- Dark-ship: inert unless BOTH the master brain gate AND our own flag are on.
    if not (Config.Enabled == true and CFG.Enabled) then return end
    while running do
        local now = GetGameTimer()
        if (now - lastEventAt) >= (CFG.IntervalSec * 1000) then   -- global anti-spam floor
            local cands = nearbyChatterPeds()
            if cands and #cands > 0 then
                fireChatter(cands)
                lastEventAt = now
            end
        end
        Wait(math.floor(CFG.IntervalSec * 1000))   -- slow tick — no per-frame work here
    end
end)

-- Clean teardown: stop both loops and drop all bubble state so no orphaned text or
-- threads survive a resource restart.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    running = false
    bubbleThread = false
    for ped in pairs(bubbles) do bubbles[ped] = nil end
    lastPed = nil
end)
