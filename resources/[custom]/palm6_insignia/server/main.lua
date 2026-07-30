-- ============================================================================
-- palm6_insignia/server/main.lua
--
-- The authority. Owns the badge number, composes the tape text, and publishes
-- the on-duty officer roster to every client.
--
-- Pure logic + DB. Every framework / native touch goes through Bridge.*
-- (bridge/sv_framework.lua), so this file ports to GTA VI unchanged.
--
-- THE INTEGRITY RULE, in one sentence: identity flows SERVER -> CLIENT and
-- never the other way. There is exactly one net event a client may raise
-- (palm6_insignia:requestRoster) and it carries NO payload at all - not a
-- badge number, not a name, not a job, nothing. A modified client therefore
-- has no surface to claim an identity through.
-- ============================================================================

local SchemaReady = false     -- flipped by ensureSchema(); shown in the banner

local badgeOf   = {}          -- citizenid -> badge number   (hydrated at boot)
local badgeTaken = {}         -- badge number -> holder key  (allocation set)
local badgeRetired = {}       -- badge number -> the citizenid that last held it

-- ---------------------------------------------------------------------------
-- RETIREMENT
--
-- badgeTaken holds "this number may not be issued". Its value is either a real
-- citizenid (someone wears it) or a TOMBSTONE key (nobody wears it and nobody
-- ever will). Both block allocation, which is the whole point: lowestFree only
-- asks "is this key set".
--
-- The tombstone is a real row in palm6_officer_badges, so the reservation
-- survives a restart. It needs no schema change: the table is keyed on
-- citizenid and carries a UNIQUE index on badge, and a tombstone is just a row
-- whose citizenid is a reserved string instead of a character.
--
--   citizenid = 'retired:<badge>:<the citizenid that gave it up>'
--   job       = 'retired'
--
-- The previous holder is encoded in the key so their own number can be handed
-- back to them (and to nobody else) by /setbadge.
-- ---------------------------------------------------------------------------
local RETIRED_JOB = 'retired'

local function retiredKey(badge, prevCitizenid)
    -- citizenid is VARCHAR(64). 'retired:' + up to 4 digits + ':' is 13, so the
    -- previous id is cut at 48 to stay inside the column with room to spare.
    return ('retired:%d:%s'):format(badge, tostring(prevCitizenid or ''):sub(1, 48))
end

-- badge, previousHolder for a tombstone key, or nil when it is a real citizen.
local function parseRetiredKey(key)
    local n, prev = tostring(key or ''):match('^retired:(%d+):(.+)$')
    if not n then return nil end
    return tonumber(n), prev
end

local roster    = {}          -- serverId -> { id, l1, l2, badge }
local lastSig   = nil         -- signature of the last roster we published
local lastAction = {}         -- [src] = { [key] = unix ts }  (rate limits)

local function dbg(msg)
    if Config.Debug then print('[palm6_insignia] ' .. msg) end
end

local function now() return os.time() end

-- Per-source, per-key cooldown floor. Independent of palm6_eventguard: that
-- bounds the NET event, this also bounds the command paths.
local function rl(src, key)
    local window = Config.RateLimits[key] or 1
    if src == 0 then return true end            -- console is not rate limited
    lastAction[src] = lastAction[src] or {}
    local t = now()
    if (lastAction[src][key] or 0) + window > t then return false end
    lastAction[src][key] = t
    return true
end

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating table). Same shape as palm6_citations / palm6_ems:
-- per-statement pcall, IF NOT EXISTS so re-runs are harmless no-ops.
--
-- Why this exists: sql/ is applied BY HAND (deploy/README.md) and CI never
-- touches the DB, so a restored backup or a brand new box boots with no
-- palm6_officer_badges table. Every query in this file is pcall-guarded, so
-- that would not be an error, it would be SILENCE: every officer would look
-- unbadged and the tape would show a name with no number. On the live box this
-- statement is a pure no-op.
--
-- The DDL is copied VERBATIM from sql/0075_insignia.sql (trailing `;` dropped
-- so oxmysql sees a single statement).
-- ---------------------------------------------------------------------------
local function ensureSchema()
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `palm6_officer_badges` (
    citizenid VARCHAR(64) NOT NULL,
    badge INT UNSIGNED NOT NULL,
    job VARCHAR(50) NOT NULL DEFAULT 'police',
    assigned_by VARCHAR(64) NOT NULL DEFAULT 'system',
    assigned_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NULL DEFAULT NULL,
    PRIMARY KEY (citizenid),
    UNIQUE KEY uniq_palm6_officer_badges_badge (badge)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
    }

    local failed = 0
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            failed = failed + 1
            print(('^1[palm6_insignia] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end
    SchemaReady = (failed == 0)
    return SchemaReady
end

-- Pull every existing badge into memory. The allocation set has to be complete
-- or "lowest free" would hand out a number the UNIQUE key then rejects.
--
-- Tombstone rows are loaded into the SAME taken set as live badges, which is
-- what makes retirement survive a restart. They are deliberately kept out of
-- badgeOf: nobody wears them, they must not be counted as issued, and no
-- lookup by citizenid should ever find one.
--
-- Returns liveCount, retiredCount.
local function hydrate()
    local rows
    local ok = pcall(function()
        rows = MySQL.query.await('SELECT citizenid, badge FROM palm6_officer_badges')
    end)
    if not ok or type(rows) ~= 'table' then return 0, 0 end
    local n, r
    n, r = 0, 0
    for _, row in ipairs(rows) do
        local b = tonumber(row.badge)
        if row.citizenid and b then
            local tombBadge, prev = parseRetiredKey(row.citizenid)
            if tombBadge then
                badgeTaken[b] = row.citizenid
                badgeRetired[b] = prev
                r = r + 1
            else
                badgeOf[row.citizenid] = b
                badgeTaken[b] = row.citizenid
                n = n + 1
            end
        end
    end
    return n, r
end

-- ---------------------------------------------------------------------------
-- BADGE ALLOCATION
-- ---------------------------------------------------------------------------

-- Lowest free number in [minv, maxv] given the taken set, or nil when the
-- range is exhausted. Deliberately pure (no clock, no DB, no PRNG) so the
-- result is identical on every boot and can be reasoned about in isolation.
--
-- Lowest-free rather than max+1: numbers stay short, and a department that has
-- churned through 40 officers still issues #103 rather than #143.
--
-- "Free" means "no key in the taken set". With Config.Badge.RetireOnReassign
-- on, a number that leaves a character keeps a TOMBSTONE key in that set (and a
-- row in the database), so free is exactly "never issued to anyone" and a
-- number is never silently recycled onto a different person. With retirement
-- off, free also includes numbers released by /setbadge, and old records naming
-- them become ambiguous. That trade-off is stated in shared/config.lua.
local function lowestFree(taken, minv, maxv)
    for n = minv, maxv do
        if not taken[n] then return n end
    end
    return nil
end

-- Assign (or return the existing) badge for a citizenid. Returns number, or
-- nil when the range is exhausted or the write failed.
--
-- The UNIQUE key on `badge` is the real guarantee. The in-memory set makes the
-- common path a single insert; if two allocations race, the loser's INSERT
-- fails, we mark that number taken and try the next free one, bounded by
-- Config.Badge.MaxAllocAttempts.
local function assignBadge(citizenid, assignedBy)
    if not citizenid then return nil end
    if badgeOf[citizenid] then return badgeOf[citizenid] end
    if not SchemaReady then return nil end

    for _ = 1, math.max(1, Config.Badge.MaxAllocAttempts) do
        local n = lowestFree(badgeTaken, Config.Badge.Min, Config.Badge.Max)
        if not n then
            print(('^3[palm6_insignia] badge range %d-%d is EXHAUSTED; %s gets no number^0')
                :format(Config.Badge.Min, Config.Badge.Max, citizenid))
            return nil
        end

        local wrote = false
        local ok = pcall(function()
            MySQL.insert.await(
                'INSERT INTO palm6_officer_badges (citizenid, badge, job, assigned_by) VALUES (?, ?, ?, ?)',
                { citizenid, n, Config.PoliceJob, assignedBy or 'system' })
            wrote = true
        end)

        -- Mark taken either way: on success it IS ours, on failure the only
        -- realistic cause is that somebody else holds it, and re-picking the
        -- same number next iteration would loop forever.
        badgeTaken[n] = citizenid

        if ok and wrote then
            badgeOf[citizenid] = n
            dbg(('assigned badge #%d to %s'):format(n, citizenid))
            return n
        end
    end

    print(('^3[palm6_insignia] could not allocate a badge for %s after %d attempts^0')
        :format(citizenid, Config.Badge.MaxAllocAttempts))
    return nil
end

-- Admin override. Returns true, or false plus a human reason.
--
-- WRITE ORDER MATTERS and is not arbitrary. `badge` carries a UNIQUE index, so
-- a number can only be held by one row at a time:
--   1. if this citizen is reclaiming their OWN retired number, delete the
--      tombstone first, or step 2 collides with it;
--   2. move the citizen's row onto the wanted number;
--   3. only then write a tombstone for the number they just vacated, which is
--      free in the database precisely because step 2 moved their row off it.
local function setBadge(citizenid, wanted, assignedBy)
    if not SchemaReady then return false, 'the badge table is not available' end
    wanted = math.floor(tonumber(wanted) or -1)
    if wanted < Config.Badge.Min or wanted > Config.Badge.Max then
        return false, ('badge must be between %d and %d'):format(Config.Badge.Min, Config.Badge.Max)
    end
    if badgeOf[citizenid] == wanted then
        return true, ('already #%d'):format(wanted)
    end

    local reclaiming = false
    local holder = badgeTaken[wanted]
    if holder and holder ~= citizenid then
        local retiredFrom = badgeRetired[wanted]
        if retiredFrom == citizenid then
            -- The original holder getting their own number back. Allowed, and
            -- it is the one case that RESTORES history rather than breaking
            -- it: every old record naming this number named this person.
            reclaiming = true
        elseif retiredFrom then
            return false, ('#%d is retired (last held by %s) and is never issued to anyone else')
                :format(wanted, retiredFrom)
        else
            return false, ('#%d already belongs to %s'):format(wanted, holder)
        end
    end

    if reclaiming then
        local okDel = pcall(function()
            MySQL.query.await('DELETE FROM palm6_officer_badges WHERE citizenid = ?',
                { retiredKey(wanted, citizenid) })
        end)
        if not okDel then return false, 'the retired-number release failed' end
    end

    local ok = pcall(function()
        MySQL.query.await([[
INSERT INTO palm6_officer_badges (citizenid, badge, job, assigned_by, updated_at)
VALUES (?, ?, ?, ?, NOW())
ON DUPLICATE KEY UPDATE badge = VALUES(badge), assigned_by = VALUES(assigned_by), updated_at = NOW()
        ]], { citizenid, wanted, Config.PoliceJob, assignedBy or 'admin' })
    end)
    if not ok then
        -- Two statements, no transaction (oxmysql .await is per-statement), so
        -- the one interleaving that can lose a reservation is handled by hand:
        -- the reclaim DELETE above already freed #wanted in the database, and
        -- the row that was supposed to take it did not land. Put the tombstone
        -- back, or #wanted becomes issuable to a stranger at the next restart.
        if reclaiming then
            local okRestore = pcall(function()
                MySQL.query.await([[
INSERT INTO palm6_officer_badges (citizenid, badge, job, assigned_by, updated_at)
VALUES (?, ?, ?, ?, NOW())
ON DUPLICATE KEY UPDATE badge = VALUES(badge), updated_at = NOW()
                ]], { retiredKey(wanted, citizenid), wanted, RETIRED_JOB, 'rollback' })
            end)
            if not okRestore then
                print(('^1[palm6_insignia] #%d was un-retired for %s, the reassign then FAILED, and the '
                    .. 'tombstone could not be restored. #%d is now free in the database and could be '
                    .. 'issued to someone else. Re-insert it by hand: '
                    .. "INSERT INTO palm6_officer_badges (citizenid, badge, job, assigned_by) VALUES ('%s', %d, '%s', 'manual');^0")
                    :format(wanted, citizenid, wanted, retiredKey(wanted, citizenid), wanted, RETIRED_JOB))
            end
        end
        return false, 'the database write failed'
    end

    local previous = badgeOf[citizenid]

    badgeOf[citizenid] = wanted
    badgeTaken[wanted] = citizenid
    if reclaiming then badgeRetired[wanted] = nil end

    -- Retire the vacated number so no future hire can be handed it.
    if previous and Config.Badge.RetireOnReassign then
        local key = retiredKey(previous, citizenid)
        badgeTaken[previous] = key
        badgeRetired[previous] = citizenid

        local okTomb = pcall(function()
            MySQL.query.await([[
INSERT INTO palm6_officer_badges (citizenid, badge, job, assigned_by, updated_at)
VALUES (?, ?, ?, ?, NOW())
ON DUPLICATE KEY UPDATE badge = VALUES(badge), updated_at = NOW()
            ]], { key, previous, RETIRED_JOB, tostring(assignedBy or 'admin') })
        end)
        if not okTomb then
            -- Loud, because the in-memory reservation is now the only thing
            -- stopping #previous being re-issued, and it dies at restart.
            print(('^1[palm6_insignia] could not persist the retirement of #%d (was %s). '
                .. 'It is reserved in memory only and WILL become issuable again after a restart. '
                .. 'Insert it by hand: '
                .. "INSERT INTO palm6_officer_badges (citizenid, badge, job, assigned_by) VALUES ('%s', %d, '%s', 'manual');^0")
                :format(previous, citizenid, key, previous, RETIRED_JOB))
        end
    elseif previous then
        -- Retirement is switched off, so the number goes back in the pool.
        badgeTaken[previous] = nil
        print(('^3[palm6_insignia] #%d released back into the pool (Config.Badge.RetireOnReassign is off). '
            .. 'Records naming #%d are now ambiguous.^0'):format(previous, previous))
    end

    -- Console audit line. A badge change is an identity change, so it is
    -- recorded even when Config.Debug is off.
    print(('[palm6_insignia] BADGE SET %s -> #%d (by %s, was %s%s)')
        :format(citizenid, wanted, tostring(assignedBy),
            previous and ('#' .. previous) or 'none',
            previous and Config.Badge.RetireOnReassign and ', now retired' or ''))
    return true
end

-- ---------------------------------------------------------------------------
-- TAPE TEXT (composed here, on the server, never on the client)
-- ---------------------------------------------------------------------------

-- Strip everything a GTA text draw could misread, then truncate.
--
-- The '~' strip is the one that matters and it is not cosmetic: the client
-- draws these strings with AddTextComponentSubstringPlayerName, which PARSES
-- tilde markup. A surname of "~r~WANTED" would render as coloured text of the
-- player's choosing above their own ped. Names are player-typed at character
-- creation, so this is a real input, not a theoretical one.
--
-- The allowlist (letters, digits, space, dot, apostrophe, hyphen, and every
-- byte >= 128) is a whitelist rather than a blocklist on purpose: a blocklist
-- has to be right about every future markup token, a whitelist only has to be
-- right about what a name contains.
--
-- Bytes 128-255 are kept so an accented surname survives. They are UTF-8 lead
-- and continuation bytes and carry no markup meaning, so keeping them costs
-- nothing on the safety side. The truncation below then has to be UTF-8 aware,
-- because cutting at a byte offset can leave half a character behind.
local function sanitiseTapeText(s, maxChars)
    s = tostring(s or '')
    -- Turn every whitespace form (newline, tab, carriage return) into a plain
    -- space BEFORE the allowlist runs. Deleting them outright instead would
    -- silently weld two words together: "Olv\nerson" must read "Olv erson",
    -- not "Olverson".
    s = s:gsub('%s', ' ')
    s = s:gsub('[^%a%d %.\'%-\128-\255]', '')
    s = s:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if maxChars and #s > maxChars then
        s = s:sub(1, maxChars)
        -- Drop a trailing partial UTF-8 sequence: first any continuation bytes
        -- (0x80-0xBF), then a lead byte (>= 0xC0) left with nothing to lead.
        while #s > 0 and s:byte(#s) >= 0x80 and s:byte(#s) < 0xC0 do s = s:sub(1, #s - 1) end
        if #s > 0 and s:byte(#s) >= 0xC0 then s = s:sub(1, #s - 1) end
        s = s:gsub('%s+$', '')
    end
    return s
end

-- Officer surname line, per Config.Name.Format.
local function nameLine(identity)
    local first = sanitiseTapeText(identity.first, Config.Name.MaxChars)
    local last  = sanitiseTapeText(identity.last, Config.Name.MaxChars)
    local out

    if Config.Name.Format == 'first_last' then
        out = (first .. ' ' .. last)
    elseif Config.Name.Format == 'last' then
        out = last
    else -- 'initial_last', the default
        out = (first ~= '' and (first:sub(1, 1) .. '. ') or '') .. last
    end

    out = sanitiseTapeText(out, Config.Name.MaxChars)
    if out == '' then out = 'OFFICER' end
    if Config.Name.Uppercase then out = out:upper() end
    return out
end

-- Second line: department, badge number, rank. Rank comes from the framework
-- grade label, so a promotion changes the tape with no extra plumbing.
local function badgeLine(identity, badge)
    local parts = {}
    parts[#parts + 1] = Config.Brand .. (badge and (' #' .. badge) or '')
    local rank = sanitiseTapeText(identity.gradeName, Config.Name.MaxChars)
    if rank ~= '' then parts[#parts + 1] = rank:upper() end
    return table.concat(parts, '  -  ')
end

-- ---------------------------------------------------------------------------
-- ROSTER
-- ---------------------------------------------------------------------------

-- The published entry for one source, or nil when this player has no tape.
local function entryFor(src)
    local id = Bridge.GetIdentity(src)
    if not id then return nil end
    if id.job ~= Config.PoliceJob then return nil end
    if Config.Roster.OnDutyOnly and not id.onduty then return nil end

    local badge = badgeOf[id.citizenid]
    if not badge and Config.Badge.AutoAssign then
        badge = assignBadge(id.citizenid, 'system')
    end

    return {
        id    = src,
        l1    = nameLine(id),
        l2    = badgeLine(id, badge),
        badge = badge,
    }
end

-- ---------------------------------------------------------------------------
-- IS THE EVENTGUARD BUDGET ACTUALLY THERE?
--
-- README.md asks the orchestrator for
--   ['palm6_insignia:requestRoster'] = { calls = 10, window_seconds = 60 },
-- in palm6_eventguard/config.lua. The first revision of this resource ASSERTED
-- that both layers existed while only one did, and the repo audit's eventguard
-- check only verifies budget -> real event, so it cannot see a missing budget.
--
-- This reads the guard's config file (LoadResourceFile is a read; it does not
-- start, touch or depend on that resource) purely so the boot banner tells the
-- truth about which layers are live. Nothing here changes behaviour: the
-- per-source floor in rl() runs either way, and a guard that is stopped,
-- renamed or unreadable just reports 'unknown'.
-- ---------------------------------------------------------------------------
local GUARDED_EVENT = 'palm6_insignia:requestRoster'

local function eventguardBudgetState()
    local state
    local okState = pcall(function() state = GetResourceState('palm6_eventguard') end)
    if not okState or state ~= 'started' then
        return 'absent', ('palm6_eventguard is %s'):format(tostring(state or 'unknown'))
    end

    local body
    pcall(function() body = LoadResourceFile('palm6_eventguard', 'config.lua') end)
    if type(body) ~= 'string' then
        return 'unknown', 'its config.lua could not be read'
    end
    if body:find(GUARDED_EVENT, 1, true) then
        return 'present', 'budget declared'
    end
    return 'absent', 'no budget for ' .. GUARDED_EVENT
end

-- Cheap order-independent signature, so the reconcile tick can push only when
-- something actually changed.
local function signature(tbl)
    local keys = {}
    for k in pairs(tbl) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local e = tbl[k]
        parts[#parts + 1] = ('%d|%s|%s'):format(k, e.l1, e.l2)
    end
    return table.concat(parts, ';')
end

local function rosterList()
    local out = {}
    for _, e in pairs(roster) do
        if #out >= Config.Roster.MaxEntries then break end
        out[#out + 1] = e
    end
    return out
end

local function pushFull(target)
    TriggerClientEvent('palm6_insignia:sync', target or -1, rosterList())
end

-- Re-derive ONE source's entry and fan out only the delta.
local function refresh(src, silent)
    local before = roster[src]
    local after = entryFor(src)

    if after then
        roster[src] = after
        if not silent and (not before or before.l1 ~= after.l1 or before.l2 ~= after.l2) then
            TriggerClientEvent('palm6_insignia:upsert', -1, after)
        end
    elseif before then
        roster[src] = nil
        if not silent then TriggerClientEvent('palm6_insignia:remove', -1, src) end
    end

    lastSig = signature(roster)
end

-- Re-derive EVERY source. Used by the reconcile tick and at boot.
local function rebuild()
    local fresh = {}
    for _, src in ipairs(Bridge.GetPlayers()) do
        local e = entryFor(src)
        if e then fresh[src] = e end
    end
    roster = fresh
    local sig = signature(roster)
    if sig ~= lastSig then
        lastSig = sig
        pushFull(nil)
        dbg(('roster changed -> %d officer(s) published'):format(#rosterList()))
    end
end

-- ---------------------------------------------------------------------------
-- NET SURFACE (exactly one inbound event, and it carries nothing)
-- ---------------------------------------------------------------------------

RegisterNetEvent('palm6_insignia:requestRoster', function()
    local src = source
    if not src or src <= 0 then return end
    if not rl(src, 'requestRoster') then return end
    -- The requester's own entry may not exist yet on a fresh spawn, so derive
    -- it first, then answer with the whole table.
    refresh(src)
    pushFull(src)
end)

-- ---------------------------------------------------------------------------
-- COMMANDS
--
-- All registered UNRESTRICTED (Bridge.RegisterCommand -> RegisterCommand(...,
-- false)) and gated inside the handler. /setbadge additionally requires
-- Config.AdminAce, which custom.cfg must grant.
-- ---------------------------------------------------------------------------

-- /mybadge - what does the server say my identity is?
Bridge.RegisterCommand('mybadge', function(src)
    src = tonumber(src) or 0
    if not rl(src, 'mybadge') then return end

    local id = Bridge.GetIdentity(src)
    if not id then
        Bridge.Reply(src, { 'No character loaded.' })
        return
    end
    if id.job ~= Config.PoliceJob then
        Bridge.Reply(src, { 'You are not a police officer, so you carry no badge.' })
        return
    end

    local badge = badgeOf[id.citizenid]
    if not badge and Config.Badge.AutoAssign then
        badge = assignBadge(id.citizenid, 'system')
        refresh(src)
    end

    Bridge.Reply(src, {
        ('%s   %s'):format(nameLine(id), badgeLine(id, badge)),
        badge and ('Badge number: #%d (permanent, tied to your character)'):format(badge)
              or 'No badge number assigned yet. Ask an admin to run /setbadge.',
        ('On duty: %s'):format(id.onduty and 'yes (your tape is visible)' or 'no (no tape)'),
    })
end)

-- /badge - present your badge to whoever you are standing with. The tape is
-- the passive channel; this is the deliberate one, and it works even for an
-- officer whose tape is hidden (off duty, plainclothes).
Bridge.RegisterCommand('badge', function(src)
    src = tonumber(src) or 0
    if src == 0 then
        Bridge.Reply(0, { '/badge is an in-world action; run it from a character.' })
        return
    end
    if not rl(src, 'badge') then return end

    local id = Bridge.GetIdentity(src)
    if not id or id.job ~= Config.PoliceJob then
        Bridge.Notify(src, 'Insignia', 'You have no badge to present.', 'error')
        return
    end

    local badge = badgeOf[id.citizenid]
    if not badge and Config.Badge.AutoAssign then
        badge = assignBadge(id.citizenid, 'system')
    end

    local targets = Bridge.NearbyPlayers(src, Config.Badge.PresentRange, Config.Badge.PresentMaxTargets)
    if #targets == 0 then
        Bridge.Notify(src, 'Insignia', 'Nobody close enough to show your badge to.', 'inform')
        return
    end

    local card = {
        l1 = nameLine(id),
        l2 = badgeLine(id, badge),
        badge = badge,
    }
    for _, t in ipairs(targets) do
        TriggerClientEvent('palm6_insignia:card', t, card)
    end
    Bridge.Notify(src, 'Insignia',
        ('Badge presented to %d %s.'):format(#targets, #targets == 1 and 'person' or 'people'), 'success')
end)

-- /setbadge <server id | citizenid> <number> - ace-gated override.
Bridge.RegisterCommand('setbadge', function(src, args)
    src = tonumber(src) or 0
    if not Bridge.IsAdmin(src) then
        -- DEGRADING SANELY WHEN THE GRANT IS MISSING.
        -- This command is registered unrestricted and gated here on
        -- Config.AdminAce. If custom.cfg has no matching add_ace line, the ace
        -- resolves only through the blanket `command` ace, so group.owner and
        -- the server console work and every admin silently does not. That is a
        -- fail-closed refusal that looks identical to "you are not an admin",
        -- so the refusal names the exact line instead of leaving it to guesswork.
        Bridge.Reply(src, {
            'You do not have permission to change a badge number.',
            ('If you expected this to work, custom.cfg needs: add_ace group.admin %s allow')
                :format(Config.AdminAce),
            'Until then /setbadge works from the server console and for group.owner.',
        })
        return
    end
    if not rl(src, 'setbadge') then return end

    args = args or {}
    if not args[1] or not args[2] then
        Bridge.Reply(src, { 'Usage: /setbadge <server id | citizenid> <number>' })
        return
    end

    local citizenid = Bridge.ResolveCitizenId(args[1])
    if not citizenid then
        Bridge.Reply(src, { ('No citizen found for "%s".'):format(tostring(args[1])) })
        return
    end

    local by = 'console'
    if src > 0 then
        local me = Bridge.GetIdentity(src)
        by = (me and me.citizenid) or ('src:' .. src)
    end

    local ok, why = setBadge(citizenid, args[2], by)
    if not ok then
        Bridge.Reply(src, { ('Could not set the badge: %s.'):format(tostring(why)) })
        return
    end

    local name = Bridge.GetCitizenName(citizenid) or citizenid
    Bridge.Reply(src, { ('%s is now badge #%s.'):format(name, tostring(args[2])) })

    -- Republish immediately if they are online, so the tape updates without a
    -- relog.
    local theirSrc = Bridge.GetSourceByCitizenId(citizenid)
    if theirSrc then refresh(theirSrc) end
end)

-- /insignia - status. Read-only, safe for anyone; it reports the system, not
-- other people's identities.
Bridge.RegisterCommand('insignia', function(src)
    src = tonumber(src) or 0
    if not rl(src, 'insignia') then return end
    local list = rosterList()

    local issued = 0
    for _ in pairs(badgeOf) do issued = issued + 1 end
    local retired = 0
    for _ in pairs(badgeRetired) do retired = retired + 1 end

    local guard = eventguardBudgetState()

    Bridge.Reply(src, {
        ('schema: %s   badges issued: %d   retired: %d   range: %d-%d')
            :format(SchemaReady and 'ready' or 'UNAVAILABLE', issued, retired,
                Config.Badge.Min, Config.Badge.Max),
        ('officers currently wearing a tape: %d (cap %d, render cap %d per frame)')
            :format(#list, Config.Roster.MaxEntries, Config.Render.MaxTapes),
        ('rate limits: eventguard budget %s, per-source floor %ds')
            :format(guard, Config.RateLimits.requestRoster),
    })
end)

-- ---------------------------------------------------------------------------
-- EXPORTS - the reason nothing else has to invent a badge number.
--
-- The uniform/rank resource, palm6_mdt, dispatch and any future ID-card
-- feature should all read from here. Every one is a plain read; none of them
-- can mutate the registry.
-- ---------------------------------------------------------------------------

exports('GetBadge', function(src)
    local id = Bridge.GetIdentity(tonumber(src) or -1)
    return id and badgeOf[id.citizenid] or nil
end)

exports('GetBadgeByCitizenId', function(citizenid)
    if type(citizenid) ~= 'string' then return nil end
    return badgeOf[citizenid]
end)

-- Full server-authoritative identity, including the exact strings drawn on the
-- tape, so a consumer renders the same text this resource does.
exports('GetInsignia', function(src)
    src = tonumber(src) or -1
    local id = Bridge.GetIdentity(src)
    if not id then return nil end
    local badge = badgeOf[id.citizenid]
    return {
        citizenid = id.citizenid,
        job       = id.job,
        grade     = id.grade,
        rank      = id.gradeName,
        onduty    = id.onduty,
        badge     = badge,
        line1     = nameLine(id),
        line2     = badgeLine(id, badge),
    }
end)

-- Allocate on demand. Returns the number, or nil.
--
-- CALL THIS FROM A THREAD, not from a synchronous handler. It is the only
-- export here that can WRITE: assignBadge reaches MySQL.insert.await, which
-- yields. Yielding across a C-call boundary from a consumer's synchronous
-- context errors on their side, not ours. The three read-only exports above
-- touch no database and are safe from anywhere.
--
-- Nothing in this repo calls it today; it exists so a future uniform or ID-card
-- resource can force a number rather than inventing a second registry.
exports('EnsureBadge', function(src)
    src = tonumber(src) or -1
    local id = Bridge.GetIdentity(src)
    if not id or id.job ~= Config.PoliceJob then return nil end
    local badge = badgeOf[id.citizenid] or assignBadge(id.citizenid, 'export')
    if badge then refresh(src) end
    return badge
end)

-- ---------------------------------------------------------------------------
-- FRAMEWORK SIGNALS -> roster refresh
--
-- All AddEventHandler via the bridge (never RegisterNetEvent on a
-- framework-internal name). SetJobDuty fires only the SetDuty pair and never
-- OnJobUpdate, which is why both are hooked.
-- ---------------------------------------------------------------------------

Bridge.OnPlayerLoaded(function(src) refresh(src) end)
Bridge.OnJobUpdate(function(src) refresh(src) end)
Bridge.OnGroupUpdate(function(src) refresh(src) end)
Bridge.OnDutyChange(function(src) refresh(src) end)

Bridge.OnPlayerDropped(function(src)
    lastAction[src] = nil
    if roster[src] then
        roster[src] = nil
        lastSig = signature(roster)
        TriggerClientEvent('palm6_insignia:remove', -1, src)
    end
end)

-- ---------------------------------------------------------------------------
-- BOOT
--
-- No onResourceStop handler exists in this file, deliberately. Nothing here is
-- dirty state that needs flushing (the badge registry is written through on
-- every change), so there is no reason to open a teardown path - and a MySQL
-- `.await` inside onResourceStop yields into a coroutine that teardown never
-- resumes, silently abandoning every row after the first.
-- ---------------------------------------------------------------------------
CreateThread(function()
    ensureSchema()
    local n, retired = hydrate()

    rebuild()

    print(('[palm6_insignia] ready - schema %s, %d badge(s) on file, %d retired, range %d-%d, %d officer(s) on duty')
        :format(SchemaReady and 'ok' or 'UNAVAILABLE', n, retired,
            Config.Badge.Min, Config.Badge.Max, #rosterList()))

    -- Say plainly which rate-limit layers are actually live, rather than
    -- claiming both. The floor below always runs; the guard may not be wired.
    local guard, why = eventguardBudgetState()
    if guard == 'present' then
        print(('[palm6_insignia] rate limits: eventguard budget on %s + %ds per-source floor')
            :format(GUARDED_EVENT, Config.RateLimits.requestRoster))
    else
        print(('^3[palm6_insignia] no eventguard budget for %s (%s). '
            .. 'The %ds per-source floor in this resource is the ONLY limiter on that event. '
            .. "Add to palm6_eventguard/config.lua: ['%s'] = { calls = 10, window_seconds = 60 },^0")
            :format(GUARDED_EVENT, why, Config.RateLimits.requestRoster, GUARDED_EVENT))
    end

    local every = tonumber(Config.Roster.ReconcileSec) or 0
    if every <= 0 then return end
    while true do
        Wait(every * 1000)
        -- rebuild() pushes ONLY when the signature moved, so a quiet server
        -- sends nothing on this tick.
        rebuild()
    end
end)
