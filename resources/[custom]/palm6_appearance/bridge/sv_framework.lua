-- ============================================================================
-- palm6_appearance/bridge/sv_framework.lua
--
-- The ONLY file that calls qbx_core exports / framework APIs. server/main.lua
-- calls Bridge.* only. Scoped to what this resource actually needs — no
-- money helpers, no inventory helpers, matching palm6_heat's precedent.
-- See docs/GTA6-READINESS.md §3.
-- ============================================================================

Bridge = {}

function Bridge.GetPlayer(source)
    return exports.qbx_core:GetPlayer(source)
end

function Bridge.GetCitizenId(source)
    local player = Bridge.GetPlayer(source)
    return player and player.PlayerData.citizenid or nil
end

-- Persists to this resource's OWN table (self-created at boot in
-- server/main.lua's ensureSchema, palm6_heat's precedent), not into
-- qbx_core's internal player row shape — decouples us from an unverified
-- metadata key name. See README.md for why.
function Bridge.SaveAppearance(citizenid, appearanceJson)
    MySQL.query.await(
        'INSERT INTO palm6_appearance_data (citizenid, appearance_json, updated_at) VALUES (?, ?, NOW()) ' ..
        'ON DUPLICATE KEY UPDATE appearance_json = VALUES(appearance_json), updated_at = NOW()',
        { citizenid, appearanceJson }
    )
end

function Bridge.GetAppearance(citizenid)
    local row = MySQL.single.await(
        'SELECT appearance_json FROM palm6_appearance_data WHERE citizenid = ?',
        { citizenid }
    )
    return row and row.appearance_json or nil
end

-- Batch read for the character-select screen's ped previews. One query for
-- every citizenid asked about, rather than N round trips while a player is
-- still sitting on the join screen.
--
-- Ownership is NOT checked here and deliberately so: this is a server-only
-- export with no client-reachable path, and its one caller
-- (palm6_charselect/bridge/sv_framework.lua) already proves every citizenid
-- belongs to the requesting license against qbx_core's `players` table before
-- it asks. Putting a second, weaker ownership notion here would mean two
-- answers to the same question.
---@param citizenids string[]
---@return table<string, string> citizenid -> raw appearance_json
function Bridge.GetAppearanceBatch(citizenids)
    local out = {}
    if type(citizenids) ~= 'table' or #citizenids == 0 then return out end

    -- Bounded placeholder list built from the actual argument count - never
    -- string-concatenated values.
    local placeholders = {}
    for i = 1, #citizenids do placeholders[i] = '?' end

    local rows = MySQL.query.await(
        ('SELECT citizenid, appearance_json FROM palm6_appearance_data WHERE citizenid IN (%s)')
            :format(table.concat(placeholders, ',')),
        citizenids
    ) or {}

    for _, row in ipairs(rows) do
        out[row.citizenid] = row.appearance_json
    end
    return out
end

-- NOTE: an earlier Bridge.CompleteCharacterCreation wrapping
-- exports.qbx_core:Login(source, citizenid, newCharData) was removed here. It
-- was never called by anything: character creation goes through qbx_core's own
-- client-invoked `qbx_core:server:createCharacter` callback (see
-- palm6_charselect/bridge/cl_game.lua), which also does the cid assignment,
-- sanitization and starter items that calling Login raw would have made this
-- resource responsible for duplicating.

function Bridge.Notify(source, msg, kind)
    TriggerClientEvent('ox_lib:notify', source, { description = msg, type = kind or 'inform' })
end
