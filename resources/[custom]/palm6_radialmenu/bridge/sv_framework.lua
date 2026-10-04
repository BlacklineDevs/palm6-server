--[[
    bridge/sv_framework.lua — v0.2.0, DEFERRED. Not loaded by fxmanifest.lua in v0.1.0.

    ONLY file that calls exports.qbx_core:* directly. All server logic (server/main.lua)
    calls Bridge.* only.

    VERIFY before enabling: exact qbx_core export name (GetPlayer) and the shape of
    player.PlayerData.job.name against the live game box's qbx_core source before
    uncommenting the server_scripts block in fxmanifest.lua. This file was drafted from
    documented qbx_core conventions, not a direct read of the live resource — see
    README.md "Before First Ensure" checklist.
]]

Bridge = {}

--- Returns the job name for a connected player, or nil if unavailable.
---@param src number
---@return string|nil
function Bridge.GetJob(src)
    -- VERIFY: confirm exports.qbx_core:GetPlayer(src) and PlayerData.job.name against the
    -- live qbx_core source before this file is ever loaded.
    local ok, player = pcall(function()
        return exports.qbx_core:GetPlayer(src)
    end)
    if not ok or not player then return nil end
    return player.PlayerData and player.PlayerData.job and player.PlayerData.job.name or nil
end
