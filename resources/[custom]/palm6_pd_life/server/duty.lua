-- ============================================================================
-- palm6_pd_life/server/duty.lua
--
-- Authoritative duty + post registry. One officer may man a post at a time; an
-- ambient NPC holds every post until a player relieves it. The server owns the
-- held-post state and the on/off-duty gate; clients only render (despawn the
-- NPC for a held post, put the taker into the manning pose). All framework
-- access goes through Bridge.* (bridge/sv_framework.lua).
-- ============================================================================

-- postId -> src currently manning it. Single source of truth.
local heldBy = {}
-- src -> postId (reverse lookup for release-on-leave / on-drop).
local postOf = {}
-- src -> { [key] = ts }: the house rl() anti-spam idiom (palm6_mdt, palm6_ems,
-- palm6_chopshop all carry the same shape).
local lastAction = {}
-- One console line the first time the duty point cannot be read, so a
-- misconfigured box is discoverable without spamming on every toggle.
local warnedNoDutyPoint = false

local function rl(src, key, window)
    if not window or window <= 0 then return true end
    lastAction[src] = lastAction[src] or {}
    local t = os.time()
    if (lastAction[src][key] or 0) + window > t then return false end
    lastAction[src][key] = t
    return true
end

-- Is this officer standing at the station's duty point? Returns true when the
-- gate is satisfied OR deliberately not enforced.
--
-- FAILS OPEN on a missing contract, on purpose: if qbx_police_overrides is
-- stopped or its export changes shape, the honest outcome is "we could not
-- check" and every officer keeps working. Failing closed would lock the whole
-- department out of duty (and therefore out of MDT, evidence, citations and
-- EMS billing) over a config read.
local function atDutyPoint(src)
    if not Config.DutyGate.Enabled then return true end
    local pt = Bridge.GetDutyPoint()
    if not pt then
        if not warnedNoDutyPoint then
            warnedNoDutyPoint = true
            print('^3[palm6_pd_life] DutyGate is ON but qbx_police_overrides:GetDutyToggle() could not be read - the station gate is INERT (failing open).^0')
        end
        return true
    end
    local c = Bridge.GetCoords(src)
    if not c then return true end   -- no ped to measure: never block on that
    local dx, dy, dz = c.x - pt.x, c.y - pt.y, c.z - pt.z
    local radius = math.max(pt.radius or 0.0, Config.DutyGate.MinRadius)
    return (dx * dx + dy * dy + dz * dz) <= (radius * radius)
end

local function isKnownPost(postId)
    for _, e in ipairs(Config.Rooms or {}) do
        if e.post == postId then return e end
    end
    return nil
end

-- Broadcast a post's held-state to every client so the NPC despawns/respawns.
local function broadcastPost(postId, held)
    TriggerClientEvent('palm6_pd_life:postState', -1, postId, held)
end

local function releasePost(src, silent)
    local postId = postOf[src]
    if not postId then return end
    heldBy[postId] = nil
    postOf[src] = nil
    broadcastPost(postId, false)
    if not silent then
        TriggerClientEvent('palm6_pd_life:leftPost', src, postId)
    end
end

-- --- take a post -----------------------------------------------------------
RegisterNetEvent('palm6_pd_life:takePost', function(postId)
    local src = source
    local post = isKnownPost(postId)
    if not post then return end
    if not Bridge.IsPolice(src) then
        Bridge.Notify(src, 'PD', 'Only police can man a post.', 'error')
        return
    end
    if heldBy[postId] and heldBy[postId] ~= src then
        Bridge.Notify(src, 'PD', 'That post is already manned.', 'error')
        return
    end
    -- If this officer was manning another post, free it first.
    if postOf[src] and postOf[src] ~= postId then releasePost(src, true) end

    heldBy[postId] = src
    postOf[src] = postId
    Bridge.SetDuty(src, true)                      -- taking a post = on duty
    broadcastPost(postId, true)                    -- NPC yields for everyone
    TriggerClientEvent('palm6_pd_life:tookPost', src, postId, post.coords, post.scen)
    Bridge.Notify(src, 'PD', 'You are now manning this post (on duty).', 'success')
end)

-- --- leave the current post ------------------------------------------------
RegisterNetEvent('palm6_pd_life:leavePost', function()
    local src = source
    if not postOf[src] then return end
    releasePost(src, false)
    Bridge.Notify(src, 'PD', 'You left your post.', 'inform')
end)

-- --- standalone on/off duty toggle (police, anywhere in station) ------------
RegisterNetEvent('palm6_pd_life:toggleDuty', function()
    local src = source
    if not rl(src, 'toggleDuty', Config.DutyGate.CooldownSec) then return end
    if not Bridge.IsPolice(src) then
        Bridge.Notify(src, 'PD', 'You are not police.', 'error')
        return
    end
    -- Server-derived proximity: the client sends nothing, the server reads its
    -- own ped position and the station contract. No-op while DutyGate is off.
    if not atDutyPoint(src) then
        Bridge.Notify(src, 'PD', 'You need to be at the station duty desk to change duty.', 'error')
        return
    end
    local nowOn = not Bridge.IsOnDutyPolice(src)
    -- Going off duty while manning a post frees the post.
    if not nowOn and postOf[src] then releasePost(src, false) end
    local set = Bridge.SetDuty(src, nowOn)
    if set == nil then
        Bridge.Notify(src, 'PD', 'Could not change duty.', 'error')
    else
        Bridge.Notify(src, 'PD', set and 'You are now ON duty.' or 'You are now OFF duty.',
            set and 'success' or 'inform')
    end
end)

-- Free a post if its officer disconnects (and drop their rate-limit slot, so
-- the table cannot grow across a long uptime).
AddEventHandler('playerDropped', function()
    releasePost(source, true)
    lastAction[source] = nil
end)

-- A late-joining client asks which posts are currently held so it can pre-cull
-- those NPCs when it builds the scene.
RegisterNetEvent('palm6_pd_life:requestHeld', function()
    local src = source
    local held = {}
    for postId in pairs(heldBy) do held[#held + 1] = postId end
    TriggerClientEvent('palm6_pd_life:heldSnapshot', src, held)
end)
