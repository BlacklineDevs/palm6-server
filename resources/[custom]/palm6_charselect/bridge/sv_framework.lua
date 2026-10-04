-- ============================================================================
-- palm6_charselect/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core exports or MySQL directly. server/main.lua calls Bridge.* only,
-- so this logic ports to GTA VI by rewriting THIS FILE. Same convention as
-- palm6_onboarding/bridge/sv_framework.lua.
--
-- REWRITTEN after cloning and reading the real qbx_core source
-- (github.com/Qbox-project/qbx_core) end to end. What changed and why:
--   - GetCharacters/Login/CreateCharacter as SERVER-side calls are GONE.
--     qbx_core exposes character listing/creation/login as
--     lib.callback.register'd SERVER callbacks, and ox_lib's lib.callback
--     has no server-to-server path (imports/callback/server.lua:
--     lib.callback.register wires a RegisterNetEvent a CLIENT triggers via
--     lib.callback.await; there is no equivalent for one server resource to
--     call another server resource's registered callback). Those calls now
--     live client-side in bridge/cl_game.lua's Game.GetCharacters /
--     Game.CreateCharacterViaQbx / Game.LoginCharacterViaQbx, called
--     directly from client/main.lua.
--   - GetMaxSlots/GetNameRules (which read qbx:multichar_slots /
--     qbx:character_name_* convars) are GONE. qbx_core's config
--     (config/client.lua, config/server.lua) is plain Lua data with ZERO
--     GetConvar calls anywhere in it - those convars were never read by the
--     real qbx_core. (This same dead-convar pattern is also what
--     resources/[custom]/[config_overrides]/qbx_core_overrides publishes -
--     flagging that as a separate, pre-existing repo issue, not something
--     this resource can fix.) Max character count now comes from the REAL
--     second return value of Game.GetCharacters(); name/DOB rules are now
--     shared/config.lua's Config.NameRules, explicitly OUR OWN UX guardrail,
--     not a synced qbx_core value.
--   - Bridge.OwnsCharacter replaces the old ownership loop over a guessed
--     Bridge.GetCharacters() - used only by the soft-delete flow now (see
--     below), a read-only check against qbx_core's players table with the
--     REAL confirmed schema (server/storage/players.lua).
-- ============================================================================

Bridge = {}

-- True once qbx_core has a loaded player object for this source - i.e. this
-- client has already been through Login/CreateCharacter successfully this
-- session. CONFIRMED real export (server/functions.lua: exports('GetPlayer',
-- GetPlayer)). Used to stop this resource re-opening charselect on top of an
-- already-playing client if palm6_charselect itself gets restarted mid-game
-- (onResourceStart fires for every connected client, not just new joins),
-- and to confirm a client-driven login actually took effect (see
-- server/main.lua's confirmSelect handler).
function Bridge.IsPlayerLoaded(src)
    local ok, player = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and player ~= nil
end

--- The citizenid qbx_core currently has loaded for this source, or nil.
---
--- This is the ONLY trustworthy answer to "which character is this player
--- playing" that the server can get. The client sends its own idea of it
--- alongside confirmSelect, and a client can send anything at all: a
--- citizenid belonging to someone else, or a 10KB string that does not fit
--- palm6_charselect_playtime's VARCHAR(50) and takes the flush thread down
--- with it. Read it off qbx_core's own loaded player object instead - which,
--- by definition, only exists because qbx_core itself authenticated the login.
---
--- PlayerData.citizenid is the real field name, confirmed in qbx_core's
--- server/player.lua (CreatePlayer builds PlayerData.citizenid) and used the
--- same way throughout its own storage layer.
function Bridge.GetLoadedCitizenId(src)
    local ok, citizenid = pcall(function()
        local player = exports.qbx_core:GetPlayer(src)
        return player and player.PlayerData and player.PlayerData.citizenid or nil
    end)
    if not ok then return nil end
    return (type(citizenid) == 'string' and citizenid ~= '') and citizenid or nil
end

-- Read-only ownership check against qbx_core's OWN `players` table, using
-- the REAL column/identifier shape confirmed in server/storage/players.lua
-- (fetchAllPlayerEntities: `... WHERE license = ? OR license = ? ...`, both
-- the legacy and license2 identifiers, matching qbx_core's own convention
-- throughout). Read-only - never INSERT/UPDATE/DELETE against `players`,
-- qbx_core remains sole writer of its own table. Used only by the
-- soft-delete flow below (palm6_charselect_hidden is OUR table, but a
-- citizenid must still be proven to belong to this player before it's
-- allowed into that table).
function Bridge.OwnsCharacter(src, citizenid)
    -- Coalesced to '' rather than left nil: a nil in the middle of the params
    -- array makes #params undefined, which risks a parameter-count mismatch
    -- in oxmysql's serialization and an uncaught error instead of a clean
    -- "not owned" result. '' can never match a real license value, so this
    -- stays correct either way.
    local license = GetPlayerIdentifierByType(src, 'license') or ''
    local license2 = GetPlayerIdentifierByType(src, 'license2') or ''
    if license == '' and license2 == '' then return false end

    local row = MySQL.single.await(
        'SELECT citizenid FROM players WHERE citizenid = ? AND (license = ? OR license = ?)',
        { citizenid, license, license2 }
    )
    return row ~= nil
end

-- Citizenids THIS player has soft-deleted (see Bridge.HideCharacter below).
-- Scoped by owner_license (set at hide time) - palm6_charselect_hidden used
-- to have no owner column at all, meaning every client was sent the FULL,
-- unscoped, ever-growing table of every soft-deleted citizenid on the whole
-- server. Read from OUR OWN table, never qbx_core's.
local function getHiddenSet(src)
    local license = GetPlayerIdentifierByType(src, 'license') or ''
    local license2 = GetPlayerIdentifierByType(src, 'license2') or ''
    local rows = MySQL.query.await(
        'SELECT citizenid FROM palm6_charselect_hidden WHERE owner_license IN (?, ?)',
        { license, license2 }
    ) or {}
    local set = {}
    for _, row in ipairs(rows) do
        set[row.citizenid] = true
    end
    return set
end

Bridge.GetHiddenSet = getHiddenSet

-- SOFT delete only. Never a real DELETE/DROP against qbx_core's `players` row
-- or any other palm6_* table a citizenid touches (vehicles, houses, gang
-- membership, bank, business ownership, ...) - a hard delete here would leave
-- every one of those orphaned. qbx_core DOES ship a real, ownership-checked
-- hard-delete callback (`qbx_core:server:deleteCharacter`, confirmed in
-- server/player.lua - it validates the caller owns the citizenid, then calls
-- `storage.deletePlayer`) but that path is deliberately NOT used here: it has
-- the exact same no-cross-resource-cascade limitation our own hard-delete
-- would have, so using it wouldn't remove any risk, only remove the
-- reversibility our soft-delete provides. Hiding is fully reversible:
-- Bridge.UnhideCharacter / the /palm6charselect_restore admin command just
-- remove the row again.
function Bridge.HideCharacter(src, citizenid)
    -- owner_license is what getHiddenSet above scopes by - Bridge.OwnsCharacter
    -- already proved src owns this citizenid before this is ever called
    -- (server/main.lua's deleteCharacter handler), so license (falling back
    -- to license2) here is trustworthy.
    local ownerLicense = GetPlayerIdentifierByType(src, 'license') or GetPlayerIdentifierByType(src, 'license2') or ''
    MySQL.query.await(
        'INSERT INTO palm6_charselect_hidden (citizenid, owner_license, hidden_at) VALUES (?, ?, NOW()) ' ..
        'ON DUPLICATE KEY UPDATE hidden_at = NOW()',
        { citizenid, ownerLicense }
    )
end

function Bridge.UnhideCharacter(citizenid)
    local result = MySQL.query.await('DELETE FROM palm6_charselect_hidden WHERE citizenid = ?', { citizenid })
    return result and result.affectedRows and result.affectedRows > 0
end

-- Saved appearances for the character-select ped previews, for the characters
-- this player actually owns.
--
-- Two separate gates, on purpose. Ownership is proved HERE, per citizenid,
-- against qbx_core's own `players` table (Bridge.OwnsCharacter above) - the
-- list arrives from the client, which got it from qbx_core, but a client can
-- send any list it likes, and appearance is another player's data. Only the
-- survivors are handed to palm6_appearance's server-only export, which does
-- the actual table read and trusts its caller for exactly this reason.
--
-- Degrades to an empty table if palm6_appearance isn't running: the select
-- screen then shows the same lettered silhouettes it showed before previews
-- existed, which is a downgrade in polish and nothing else.
--- The subset of `citizenids` this player provably owns. Split out from the
--- appearance read so ownership is proved ONCE per request and the surviving
--- ids are reused for every per-character lookup that follows (appearance,
--- playtime). Two features doing their own ownership check is two chances to
--- get it wrong, and a lookup that skipped it would let a client probe for
--- characters belonging to someone else.
function Bridge.FilterOwned(src, citizenids)
    local owned = {}
    if type(citizenids) ~= 'table' then return owned end
    for i = 1, math.min(#citizenids, 16) do
        local citizenid = citizenids[i]
        if type(citizenid) == 'string' and citizenid ~= '' and Bridge.OwnsCharacter(src, citizenid) then
            owned[#owned + 1] = citizenid
        end
    end
    return owned
end

--- Saved appearances for ids that have ALREADY been ownership-checked by
--- Bridge.FilterOwned. Never call this with a raw client-supplied list.
function Bridge.GetAppearancesFor(owned)
    if type(owned) ~= 'table' or #owned == 0 then return {} end

    local ok, appearances = pcall(function()
        return exports.palm6_appearance:GetAppearanceForCitizenIds(owned)
    end)
    return (ok and type(appearances) == 'table') and appearances or {}
end

-- ---------------------------------------------------------------------------
-- Playtime. Ours entirely: qbx_core tracks none (confirmed against its real
-- metadata defaults), which is why the select screen's old "playtime" line
-- could never have shown anything and was removed. This is the honest version.
-- ---------------------------------------------------------------------------

--- Total seconds played per citizenid, for the ids given. Read-only.
---@param citizenids string[]
---@return table<string, number>
function Bridge.GetPlaytimes(citizenids)
    local out = {}
    if type(citizenids) ~= 'table' or #citizenids == 0 then return out end

    local placeholders = {}
    for i = 1, #citizenids do placeholders[i] = '?' end

    local rows = MySQL.query.await(
        ('SELECT citizenid, seconds_played FROM palm6_charselect_playtime WHERE citizenid IN (%s)')
            :format(table.concat(placeholders, ',')),
        citizenids
    ) or {}

    for _, row in ipairs(rows) do
        out[row.citizenid] = tonumber(row.seconds_played) or 0
    end
    return out
end

--- Adds `seconds` to a character's running total. Upsert so a character that
--- has never been played simply starts existing here on its first flush.
function Bridge.AddPlaytime(citizenid, seconds)
    if type(citizenid) ~= 'string' or citizenid == '' then return end
    -- Belt and braces behind Bridge.GetLoadedCitizenId: the column is
    -- VARCHAR(50), and an over-long value is a hard MySQL error, not a
    -- truncation - raised inside the periodic flush thread, which would then
    -- die and take every player's unbanked playtime with it. Nothing
    -- legitimate is anywhere near this length (qbx_core citizenids are 8-11
    -- chars), so refusing is strictly better than writing.
    if #citizenid > 50 then return end
    seconds = math.floor(tonumber(seconds) or 0)
    -- A non-positive delta is not an error worth logging - a player who joins
    -- and leaves inside the same second produces one.
    if seconds <= 0 then return end

    MySQL.query.await(
        'INSERT INTO palm6_charselect_playtime (citizenid, seconds_played) VALUES (?, ?) ' ..
        'ON DUPLICATE KEY UPDATE seconds_played = seconds_played + VALUES(seconds_played)',
        { citizenid, seconds }
    )
end

-- src == 0 is the server console (an admin command run there, not by a
-- player) - TriggerClientEvent to source 0 goes nowhere, so console admins
-- got silent commands. print() as well so that path has feedback too.
function Bridge.Notify(src, title, msg, t)
    if src == 0 then
        print(('[%s] %s'):format(title, msg))
        return
    end
    TriggerClientEvent('ox_lib:notify', src, { title = title, description = msg, type = t or 'inform' })
end

function Bridge.RegisterCommand(name, handler, restricted)
    RegisterCommand(name, handler, restricted or false)
end
