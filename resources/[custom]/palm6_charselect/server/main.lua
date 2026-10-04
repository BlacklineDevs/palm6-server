-- ============================================================================
-- palm6_charselect/server/main.lua
--
-- Server-side flow. Only calls Bridge.* (see bridge/sv_framework.lua) -
-- never a qbx_core export directly.
--
-- REWRITTEN after verifying the real qbx_core source: character listing,
-- creation, and login now happen CLIENT-SIDE (client/main.lua calling
-- bridge/cl_game.lua's Game.GetCharacters / CreateCharacterViaQbx /
-- LoginCharacterViaQbx, which are the real qbx_core lib.callback names -
-- see that file's header comment for why this had to move off the server).
-- What THIS server still owns:
--   1. The restart-safety gate (requestCharacters/clearToOpen/alreadyLoaded)
--   2. Confirming a client-driven login actually took effect before telling
--      the client to play the select/spawn cinematic (confirmSelect)
--   3. The soft-delete feature, which is entirely ours, not qbx_core's
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Boot: self-create palm6_charselect_hidden (soft-delete tracking - see
-- Bridge.HideCharacter). Idempotent, guarded, same precedent as palm6_heat/
-- palm6_appearance - CI never touches the DB, so a fresh box or restored
-- backup must be able to boot this resource cold.
-- ---------------------------------------------------------------------------
local READY = false

-- owner_license scopes the soft-delete list per player (see
-- bridge/sv_framework.lua's getHiddenSet/HideCharacter) - without it, every
-- client was sent the full, unscoped, ever-growing hidden list for the
-- entire server.
local function ensureSchema()
    local ok, err = pcall(function()
        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `palm6_charselect_hidden` (
                `citizenid`     VARCHAR(50)  NOT NULL,
                `owner_license` VARCHAR(80)  NOT NULL DEFAULT '',
                `hidden_at`     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`citizenid`),
                KEY `idx_owner` (`owner_license`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]])

        -- Playtime. Every premium select screen shows how long you have played
        -- a character; qbx_core does not track it ANYWHERE (confirmed against
        -- its real metadata defaults - there is no playtime/playTime key), so
        -- this resource keeps its own. Its own table, like the soft-delete
        -- one: qbx_core's `players` row is never written by us.
        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `palm6_charselect_playtime` (
                `citizenid`      VARCHAR(50) NOT NULL,
                `seconds_played` BIGINT UNSIGNED NOT NULL DEFAULT 0,
                `updated_at`     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                PRIMARY KEY (`citizenid`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]])
    end)
    if ok then
        READY = true
        print('[palm6_charselect] schema ready (palm6_charselect_hidden)')
        return
    end

    print(('[palm6_charselect] could not create palm6_charselect_hidden (%s). Retrying in 10s.'):format(tostring(err)))
    -- A DB that's briefly unreachable at boot (slow startup, restore in
    -- progress, etc) previously left this resource permanently inert -
    -- delete/restore would just silently no-op forever with no retry and no
    -- player-facing error. Keep retrying instead of giving up after one try;
    -- this only ever runs until READY flips true.
    SetTimeout(10000, ensureSchema)
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    ensureSchema()
end)

RegisterNetEvent('palm6_charselect:requestCharacters', function()
    local src = source

    -- Never (re)open charselect on top of a client that already has an
    -- active qbx_core player object - this is what stops a mid-session
    -- restart of THIS resource from yanking every already-playing client
    -- back into the NUI (onResourceStart fires for every connected client,
    -- not just new joins). See README.md "restart safety".
    if Bridge.IsPlayerLoaded(src) then
        TriggerClientEvent('palm6_charselect:alreadyLoaded', src)
        return
    end

    -- The client fetches the actual character list itself (Game.GetCharacters,
    -- the real qbx_core callback) - this just clears it to do so, and hands
    -- over which citizenids to filter out (soft-deleted by this player
    -- previously). See bridge/sv_framework.lua for why listing moved off
    -- the server.
    local hidden = {}
    if READY then
        for citizenid in pairs(Bridge.GetHiddenSet(src)) do
            hidden[#hidden + 1] = citizenid
        end
    end
    TriggerClientEvent('palm6_charselect:clearToOpen', src, { hiddenCitizenIds = hidden })
end)

-- Saved appearances for the ped previews on the select screen. Fires once,
-- right after the client has its character list from qbx_core (the client is
-- the only side that can call that callback - see bridge/cl_game.lua - so the
-- server can't pre-load this into clearToOpen; it doesn't know the citizenids
-- yet at that point).
--
-- Pre-login by nature, like every other event in this resource: the requester
-- has no qbx_core player object yet, so ownership is proved from the license
-- against the `players` table rather than from a loaded player
-- (Bridge.FilterOwned -> Bridge.OwnsCharacter).
RegisterNetEvent('palm6_charselect:requestAppearances', function(citizenids)
    local src = source
    if Bridge.IsPlayerLoaded(src) then return end   -- already playing; nothing on the select screen to preview

    -- Ownership is proved ONCE, by Bridge.FilterOwned, and the surviving ids
    -- are what every per-character read below is given - so playtime cannot be
    -- used to probe for characters the requester does not own, and there is no
    -- second ownership notion to get wrong.
    local owned = Bridge.FilterOwned(src, citizenids)
    TriggerClientEvent('palm6_charselect:appearances', src, {
        appearances = Bridge.GetAppearancesFor(owned),
        playtime = READY and Bridge.GetPlaytimes(owned) or {},
    })
end)

-- ---------------------------------------------------------------------------
-- Playtime sessions
--
-- Started when a login is confirmed, flushed on disconnect and periodically
-- while playing. The periodic flush is the part that matters: a server crash
-- or a hard kill never fires playerDropped, and without it every session since
-- the last restart would be lost.
-- ---------------------------------------------------------------------------
local sessions = {}   -- src -> { citizenid = string, since = os.time() }

local function flushSession(src, keepOpen)
    local session = sessions[src]
    if not session or not READY then return end

    local now = os.time()
    local elapsed = now - session.since

    -- THE BOOKKEEPING IS ADVANCED BEFORE THE WRITE, NEVER AFTER.
    --
    -- Bridge.AddPlaytime yields on a DB round trip. Anything that lands during
    -- that await re-enters this function - playerDropped, the periodic flush,
    -- or another confirmSelect - reads the SAME unadvanced session.since,
    -- computes the identical elapsed, and issues a second identical `+N`
    -- upsert. It is client-triggerable: N confirmSelect events in a burst
    -- credit N x elapsed. Advancing first means every re-entrant caller
    -- computes elapsed == 0 and writes nothing.
    --
    -- `session` is a local reference, so nil'ing sessions[src] here does not
    -- lose the citizenid the write below still needs.
    if keepOpen then
        session.since = now      -- banked; keep counting from here
    else
        sessions[src] = nil
    end

    if elapsed > 0 then
        Bridge.AddPlaytime(session.citizenid, elapsed)
    end
end

AddEventHandler('playerDropped', function()
    flushSession(source, false)
end)

-- Flush every player's running session on a fixed interval so an unclean
-- shutdown costs at most one interval instead of the whole session.
CreateThread(function()
    while true do
        Wait(Config.PlaytimeFlushIntervalMs)

        -- Iterate a SNAPSHOT of the keys, not `sessions` itself. flushSession
        -- yields, and mutating a table while a pairs() traversal is suspended
        -- inside it is undefined per the Lua manual - confirmSelect INSERTS a
        -- new key (a player logging in during the flush) and playerDropped
        -- DELETES one, either of which can raise "invalid key to 'next'".
        --
        -- And the body is pcall'd, because this thread dying is not a small
        -- failure: the comment block below declares it the ONLY durability
        -- guarantee this feature has, so an unhandled error here silently
        -- loses every player's playtime until the next restart.
        local srcs = {}
        for src in pairs(sessions) do srcs[#srcs + 1] = src end

        for i = 1, #srcs do
            local src = srcs[i]
            if sessions[src] then   -- may have dropped during an earlier flush's await
                local ok, err = pcall(flushSession, src, true)
                if not ok then
                    print(('[palm6_charselect] playtime flush failed for src %s: %s')
                        :format(tostring(src), tostring(err)))
                end
            end
        end
    end
end)

-- NO onResourceStop FLUSH, on purpose.
--
-- The obvious "bank every open session when the resource stops" handler was
-- written here and removed: flushSession reaches MySQL.query.await, and this
-- repo's own audit enforces "no MySQL .await is reachable from an
-- onResourceStop handler" (tools/audit - it caught this). A yielding call in a
-- stop handler is not guaranteed to resume, so the write may never land
-- anyway, and the audit exists because that has bitten this repo before.
--
-- The periodic flush above already bounds the loss: a restart costs each
-- player at most Config.PlaytimeFlushIntervalMs of unbanked time, not their
-- whole session. That is the honest trade, and it is why the interval exists.

-- Client calls this right after Game.LoginCharacterViaQbx or
-- Game.CreateCharacterViaQbx returns, so this resource plays its own
-- cinematic/spawn hand-off only once qbx_core has ACTUALLY logged the player
-- in (both of those calls block until qbx_core's server-side handler
-- returns, but neither communicates success/failure back to the caller in a
-- checkable way - qbx_core's own default UI doesn't check either, it just
-- proceeds. This checks Bridge.IsPlayerLoaded instead of blindly trusting
-- that, so a genuinely failed login surfaces as an error here rather than a
-- cinematic playing over nothing).
--
-- THE CITIZENID IS READ OFF QBX_CORE, NOT OFF THE PAYLOAD.
--
-- This handler takes no argument on purpose. It used to accept the client's
-- own citizenid string and, once Bridge.IsPlayerLoaded said *some* character
-- was loaded, write it straight into palm6_charselect_playtime. That proved
-- nothing about the string itself: every other write path in this resource
-- goes through Bridge.OwnsCharacter/FilterOwned, and this was the one that
-- gated nothing. The length was unchecked too, against a VARCHAR(50) column
-- reached by a bare MySQL.query.await on the periodic flush thread - one
-- crafted event killed playtime for the whole server until restart.
--
-- Bridge.GetLoadedCitizenId answers from qbx_core's loaded player object,
-- which exists only because qbx_core itself authenticated the login, so
-- ownership and length are both settled by construction rather than checked.
RegisterNetEvent('palm6_charselect:confirmSelect', function()
    local src = source
    local citizenid = Bridge.GetLoadedCitizenId(src)
    if not citizenid then
        TriggerClientEvent('palm6_charselect:error', src, 'login_failed', 'Character did not load. Please try again.')
        return
    end
    -- Start the playtime clock. Here and not on the client, because a client
    -- can lie about how long it played; and here rather than at spawn, because
    -- this is the point the server has CONFIRMED the character is loaded.
    --
    -- Any session already open on this source is banked FIRST. Two ways that
    -- happens and both lose time if it is just overwritten:
    --   1. A player switches character without disconnecting - everything the
    --      previous character had accrued since its last flush is discarded.
    --   2. Server ids are REUSED. If a disconnect ever misses playerDropped,
    --      the stale session belongs to a different player, and that time was
    --      genuinely played by the old character - it should be banked to it,
    --      not silently dropped or credited to whoever inherits the id. The
    --      periodic flush caps any over-credit at one interval.
    flushSession(src, false)
    sessions[src] = { citizenid = citizenid, since = os.time() }

    -- No camera/spawn coords in this payload - client/main.lua already has
    -- the selected character's real saved position (from its own
    -- Game.GetCharacters() call) and uses that for the actual spawn; this
    -- server never fetches characters itself (see bridge/sv_framework.lua).
    TriggerClientEvent('palm6_charselect:selectAccepted', src, citizenid)
end)

-- Same proof, same clock, different answer. The create path cannot reuse
-- confirmSelect because selectAccepted plays the "you're in the world now"
-- cinematic and spawns - a newly created character instead hands off to the
-- appearance editor first, and only spawns when that closes. Splitting the
-- reply keeps one meaning per event rather than adding a client-supplied mode
-- flag to decide which of two very different things the server does.
RegisterNetEvent('palm6_charselect:confirmCreate', function()
    local src = source
    local citizenid = Bridge.GetLoadedCitizenId(src)
    if not citizenid then
        TriggerClientEvent('palm6_charselect:error', src, 'create_failed', 'Character was not created. Please try again.')
        return
    end

    flushSession(src, false)
    sessions[src] = { citizenid = citizenid, since = os.time() }

    TriggerClientEvent('palm6_charselect:createAccepted', src)
end)

RegisterNetEvent('palm6_charselect:deleteCharacter', function(citizenid)
    local src = source
    if type(citizenid) ~= 'string' then return end
    if not READY then
        -- Previously a silent no-op: the player types the character's name
        -- to confirm, clicks delete, and nothing happens at all, with no
        -- indication why. Now at least surfaces as a visible error instead
        -- of looking broken.
        TriggerClientEvent('palm6_charselect:error', src, 'not_ready', 'Character system is still starting up - try again in a moment.')
        return
    end

    if not Bridge.OwnsCharacter(src, citizenid) then
        TriggerClientEvent('palm6_charselect:error', src, 'not_owned', 'That character does not belong to you.')
        return
    end

    Bridge.HideCharacter(src, citizenid)
    TriggerClientEvent('palm6_charselect:deleteConfirmed', src, citizenid)
end)

-- Admin recovery for the soft-delete above: undoes a HideCharacter, no data
-- was ever touched so this is a plain, safe unhide. ACE-gated like every
-- other admin command in this resource.
Bridge.RegisterCommand('palm6charselect_restore', function(source, args)
    local citizenid = args[1]
    if not READY or type(citizenid) ~= 'string' or citizenid == '' then
        Bridge.Notify(source, 'palm6_charselect', 'Usage: /palm6charselect_restore <citizenid>', 'error')
        return
    end
    local restored = Bridge.UnhideCharacter(citizenid)
    Bridge.Notify(source, 'palm6_charselect',
        restored and ('Restored character %s.'):format(citizenid) or ('No hidden character found for %s.'):format(citizenid),
        restored and 'success' or 'inform')
end, true) -- restricted=true: requires the command.palm6charselect_restore ACE

-- Admin bail-out: force-releases a client stuck in the charselect NUI (e.g.
-- qbx_core's own lib.callback timed out or errored for some reason and the
-- player is staring at a permanent error with no other way out - charselect
-- has no cancel button because selecting/creating a character is mandatory).
-- ACE-gated the same way palm6_heat/palm6_anchors gate their admin commands.
Bridge.RegisterCommand('palm6charselect_release', function(source, args)
    local targetId = tonumber(args[1])
    if not targetId then
        Bridge.Notify(source, 'palm6_charselect', 'Usage: /palm6charselect_release <server id>', 'error')
        return
    end
    -- Whether qbx_core already has a player object for the target decides what
    -- the rescue can safely DO, and only the server can answer it. Loaded ->
    -- the character exists and the client just never got spawned, so spawn it.
    -- Not loaded -> it must NOT spawn (Game.SpawnAtPosition fires
    -- QBCore:*:OnPlayerLoaded, and seven other palm6_* resources act on that
    -- for a player who has no character); reopen charselect for a real retry
    -- instead.
    local loaded = Bridge.IsPlayerLoaded(targetId)
    TriggerClientEvent('palm6_charselect:forceRelease', targetId, loaded)
    Bridge.Notify(source, 'palm6_charselect',
        ('Sent force-release to server id %d (%s).')
            :format(targetId, loaded and 'character loaded - will spawn' or 'no character - will reopen select'),
        'success')
end, true) -- restricted=true: requires the command.palm6charselect_release ACE, same convention as every other admin command in this repo
