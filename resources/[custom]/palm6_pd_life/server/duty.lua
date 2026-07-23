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
    if not Bridge.IsPolice(src) then
        Bridge.Notify(src, 'PD', 'You are not police.', 'error')
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

-- Free a post if its officer disconnects.
AddEventHandler('playerDropped', function()
    releasePost(source, true)
end)

-- A late-joining client asks which posts are currently held so it can pre-cull
-- those NPCs when it builds the scene.
RegisterNetEvent('palm6_pd_life:requestHeld', function()
    local src = source
    local held = {}
    for postId in pairs(heldBy) do held[#held + 1] = postId end
    TriggerClientEvent('palm6_pd_life:heldSnapshot', src, held)
end)
