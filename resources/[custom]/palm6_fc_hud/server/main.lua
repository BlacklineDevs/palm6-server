-- ============================================================================
-- palm6_fc_hud/server/main.lua
--
-- The HUD is display-only. Its SOLE server surface is one read-only ox_lib
-- callback returning the caller's own rep/rank for the career panel. It:
--   * resolves the citizenid SERVER-SIDE (ignores any client-supplied args),
--   * reads palm6_fc_progression LAZILY (it may be down / starting — the T11
--     ensure order starts progression AFTER this resource, so a hard dependency
--     would block boot; pcall + GetResourceState guard it instead),
--   * writes nothing and mints nothing.
-- ============================================================================

local function getCitizenId(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    if ok and p and p.PlayerData then return p.PlayerData.citizenid end
    return nil
end

lib.callback.register('palm6_fc_hud:getCareer', function(src)
    local cid = getCitizenId(src)
    if not cid then return { rep = 0, rank = 0 } end
    local rep, rank = 0, 0
    pcall(function()
        if GetResourceState('palm6_fc_progression') == 'started' then
            rep  = exports.palm6_fc_progression:GetRep(cid) or 0
            rank = exports.palm6_fc_progression:GetRank(cid) or 0
        end
    end)
    return { rep = rep, rank = rank }
end)
