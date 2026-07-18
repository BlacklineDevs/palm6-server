-- ============================================================================
-- palm6_fc_hud/bridge/cl_game.lua
--
-- Game adapter (client). The ONLY file in this resource that calls native
-- NUI messaging, reads statebags, or calls cross-resource exports. Pure logic
-- in client/main.lua calls Game.* only, so the HUD ports to GTA VI by
-- rewriting THIS FILE (palm6_clout bridge precedent, docs/GTA6-READINESS.md).
--
-- Display-only: nothing here writes fight state or sends a gameplay event.
-- ============================================================================

Game = {}

-- Push a display message to the NUI overlay. The HUD never takes input focus
-- (pure overlay), so no SetNuiFocus is ever called.
function Game.SendUIMessage(msg)
    SendNUIMessage(msg)
end

-- fc_core Config (shared_scripts export, present on the client realm). Returns
-- nil until fc_core has loaded so the caller can retry.
function Game.CoreConfig()
    local ok, cfg = pcall(function() return exports.palm6_fc_core:Config() end)
    if ok then return cfg end
    return nil
end

-- fc_core statebag key constants. Returns nil until fc_core has loaded.
function Game.StateKeys()
    local ok, keys = pcall(function() return exports.palm6_fc_core:StateKeys() end)
    if ok then return keys end
    return nil
end

-- Local player's active match id (int) or false/nil when not fighting.
function Game.GetLocalActive(activeKey)
    return LocalPlayer.state[activeKey]
end

-- Local player's fight slot (1|2) or nil.
function Game.GetLocalSlot(slotKey)
    return LocalPlayer.state[slotKey]
end

-- Throttled global fight statebag for a match, or nil when unset.
function Game.GetMatchState(matchKey)
    return GlobalState[matchKey]
end

-- Read-only career fetch (rep/rank) via this resource's own server callback,
-- which lazily reads palm6_fc_progression. Returns { rep, rank } or nil.
function Game.FetchCareer()
    local ok, res = pcall(function() return lib.callback.await('palm6_fc_hud:getCareer', false) end)
    if ok then return res end
    return nil
end
