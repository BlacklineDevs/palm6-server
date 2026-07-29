// ============================================================================
// tools/audit/allowlist.js - THE ONLY place a deliberate exception may live.
//
// RULES, enforced by run.js and not by good intentions:
//   1. Every entry needs a non-empty `reason`. An entry without one fails the
//      whole run. "Allowlisted because the check was noisy" is not a reason;
//      state what makes the thing correct.
//   2. Every entry needs a `check` that names a real check id, and a `key`
//      the check actually produces. A key nothing matches is reported as
//      STALE, because a dead exception is rot that reads like coverage.
//   3. Nothing else in this directory may hardcode an exception. If you find
//      yourself writing `if (name === 'palm6_something') continue;` inside a
//      check, it belongs here instead.
//
// The `key` format is documented per check in README.md.
// ============================================================================
'use strict';

module.exports = [
    // -----------------------------------------------------------------------
    // tables: a palm6_* table referenced by code with no CREATE TABLE anywhere
    // in this repo.
    // -----------------------------------------------------------------------
    {
        check: 'tables',
        key: 'palm6_founding_grants',
        reason:
            'Owned by the WEBSITE, not the game server. The site writes a row when a '
            + 'verified /beta reservation links its Discord identity; palm6_founder only '
            + 'ever SELECTs from it (resources/[custom]/palm6_founder/server/main.lua) and '
            + 'fails open when the read errors, so a missing table costs a chat badge and '
            + 'nothing else. Creating it here would give two systems a claim on one schema.',
    },

    // -----------------------------------------------------------------------
    // events: dynamic registration sites. The first argument is not a literal,
    // so the scanner cannot read the name off the call. Each site is declared
    // here with the names it really registers, and those names are then fed
    // back into the graph. A NEW dynamic site that is not listed here FAILS
    // the check rather than silently widening the blind spot.
    //
    // key = '<file>:<line>' of the registration call.
    // registers = names to credit to it ([] means "credits nothing").
    // -----------------------------------------------------------------------
    {
        check: 'events',
        key: 'dynamic:resources/[custom]/palm6_witnesses/server/main.lua',
        registers: ['palm6_robbery:started'],
        reason:
            'AddEventHandler(Config.Hooks.palm6Robbery.event, ...). The name is a config '
            + 'constant: palm6_witnesses/shared/config.lua sets Hooks.palm6Robbery.event = '
            + "'palm6_robbery:started' with enabled = true. That is the server-only signal "
            + 'palm6_robbery raises after its gates pass, deliberately NOT the forgeable '
            + "net event 'palm6_robbery:start'.",
    },
    {
        check: 'events',
        key: 'dynamic:resources/[custom]/palm6_eventguard/server/main.lua',
        registers: [],
        reason:
            'AddEventHandler(eventName, ...) inside the loop over Config.Events. It '
            + 'registers a RATELIMIT GUARD for every budgeted name, not a handler that '
            + 'does the work. Crediting it as a handler would make every budgeted event '
            + 'look owned even after its real owner was deleted, which is the exact rot '
            + 'the orphan check exists to catch. So it registers nothing here, on purpose.',
    },
    {
        check: 'events',
        key: 'dynamic:resources/[custom]/palm6_replay/bridge/sv_framework.lua',
        registers: [],
        reason:
            'Bridge.OnServerOnlyEvent / Bridge.OnForeignNetEvent are generic wrappers: the '
            + 'name is a parameter. Their callers pass names from Config.Triggers, which '
            + 'are foreign (qbx / other-resource) signals, not palm6_* names, and this '
            + 'check only rules on palm6_* names. Nothing to credit.',
    },

    // -----------------------------------------------------------------------
    // eventguard: a budget whose event is not RegisterNetEvent'd anywhere in
    // this repo.
    // -----------------------------------------------------------------------
    {
        check: 'eventguard',
        key: 'ox_inventory:openInventory',
        reason:
            'Registered by ox_inventory, a recipe resource that is not in this repo, so no '
            + 'in-tree RegisterNetEvent can exist for it. The budget is real: '
            + 'palm6_eventguard is ensured in custom.cfg well before ox_inventory is '
            + 'started by the panel server.cfg, so the guard is first in the handler chain.',
    },

    // -----------------------------------------------------------------------
    // ensure-list: a resource directory in resources/[custom] with no `ensure`
    // line in custom.cfg.
    // -----------------------------------------------------------------------
    {
        check: 'ensure-list',
        key: 'palm6_threads',
        reason:
            'Deliberately NOT ensured, and custom.cfg says so at length. The Stage A spike '
            + "is REPLACEMENT-style: its stream/ folder overwrites the BASE GAME's male "
            + 'jbib drawable 0, so ensuring it would repaint that torso for every male '
            + 'freemode character on the server. It becomes ensurable only once Phase 1 '
            + 'converts it to a true addon-DLC pack with its own SHOP_PED_APPAREL_META_FILE.',
    },
    {
        check: 'ensure-list',
        key: 'prop_spawn',
        reason:
            'Deliberately STOPPED, not ensured. custom.cfg carries `stop prop_spawn` '
            + 'because the panel-managed server.cfg (outside this repo) ensures it and it '
            + 'is an ungated client-side prop spawner any player could grief with. '
            + 'custom.cfg execs last, so the stop wins.',
    },

    // -----------------------------------------------------------------------
    // command-aces: an `add_ace <principal> command.<name>` in custom.cfg whose
    // <name> is not registered anywhere in this repo.
    // -----------------------------------------------------------------------
    {
        check: 'command-aces',
        key: 'ace-without-command:tp',
        reason: 'qbx_core command, shipped by the recipe and not present in this repo. The grant extends it from admin to mod.',
    },
    {
        check: 'command-aces',
        key: 'ace-without-command:tpm',
        reason: 'qbx_core command, shipped by the recipe and not present in this repo. The grant extends it from admin to mod.',
    },
    {
        check: 'command-aces',
        key: 'ace-without-command:revive',
        reason: 'qbx_medical command, shipped by the recipe and not present in this repo. The grant extends it from admin to mod.',
    },
    {
        check: 'command-aces',
        key: 'ace-without-command:heal',
        reason: 'qbx_medical command, shipped by the recipe and not present in this repo. The grant extends it from admin to mod.',
    },
    {
        check: 'command-aces',
        key: 'ace-without-command:setjob',
        reason:
            'qbx_core command, shipped by the recipe and not present in this repo. '
            + 'palm6_whitelist_jobs guards WHICH jobs it may set; it does not register the command.',
    },
    {
        check: 'command-aces',
        key: 'ace-without-command:giveitem',
        reason: 'ox_inventory / qbx_core command, shipped by the recipe and not present in this repo.',
    },

    // -----------------------------------------------------------------------
    // stop-await: a MySQL .await reachable from an onResourceStop handler.
    //
    // These two are the SAME deliberate pattern, and the pattern is the fix,
    // not the bug: the callee takes an `inline` boolean, and the onResourceStop
    // caller passes true to select a path that uses the NON-await call form
    // (which only hands the query to oxmysql, a separate still-running
    // resource, and returns). The check cannot follow a boolean argument into a
    // branch, so it reports the reachability and these entries record why it is
    // safe. The key contains the whole call chain, so if the chain ever changes
    // shape the entry stops matching and the check fails again.
    // -----------------------------------------------------------------------
    {
        check: 'stop-await',
        key: 'palm6_counterfeit::persistHeat',
        reason:
            'persistHeat(districtId, inline) at palm6_counterfeit/server/main.lua:265 '
            + 'branches on `inline`: MySQL.query(...) when true, MySQL.query.await(...) '
            + 'when false. The onResourceStop handler calls persistHeat(districtId, true), '
            + 'so the awaiting branch is unreachable from teardown. The handler comment '
            + 'above it documents the exact bug this shape was introduced to fix.',
    },
    {
        check: 'stop-await',
        key: 'palm6_mapeditor::restorePending',
        reason:
            'restorePending(src, why, inline) at palm6_mapeditor/server/live.lua:461 '
            + 'branches on `inline`: the inline path fire-and-forgets MySQL.insert(...), '
            + 'the normal path uses MySQL.insert.await(...) under withWriteLock. Both '
            + 'onResourceStop handlers (server/live.lua and server/entities.lua) pass '
            + 'inline = true, so the awaiting branch is unreachable from teardown.',
    },

    // -----------------------------------------------------------------------
    // migrations: numbers owned by palm6_dbmigrate/server.lua with no sql/ file.
    //
    // sql/ is NOT the authority for the next free migration number. These seven
    // exist only as entries in palm6_dbmigrate/server.lua's STATEMENTS table.
    // Anyone who numbers a new sql/ file by looking at `ls sql/` alone will
    // collide with one of them, which is why the check reports the next free
    // number across BOTH authorities.
    // -----------------------------------------------------------------------
    {
        check: 'migrations',
        key: 'dbmigrate-only:0067',
        reason: 'palm6_racing tables. Authored directly in palm6_dbmigrate/server.lua; no sql/0067 file was ever created.',
    },
    {
        check: 'migrations',
        key: 'dbmigrate-only:0068',
        reason: 'palm6_business base tables. Authored directly in palm6_dbmigrate/server.lua; no sql/0068 file exists.',
    },
    {
        check: 'migrations',
        key: 'dbmigrate-only:0069',
        reason: 'palm6_business follow-up. Authored directly in palm6_dbmigrate/server.lua; no sql/0069 file exists.',
    },
    {
        check: 'migrations',
        key: 'dbmigrate-only:0070',
        reason: 'palm6_business follow-up. Authored directly in palm6_dbmigrate/server.lua; no sql/0070 file exists.',
    },
    {
        check: 'migrations',
        key: 'dbmigrate-only:0071',
        reason: 'palm6_business follow-up. Authored directly in palm6_dbmigrate/server.lua; no sql/0071 file exists.',
    },
    {
        check: 'migrations',
        key: 'dbmigrate-only:0072',
        reason: 'palm6_business follow-up. Authored directly in palm6_dbmigrate/server.lua; no sql/0072 file exists.',
    },
    {
        check: 'migrations',
        key: 'dbmigrate-only:0073',
        reason: 'palm6_business follow-up. Authored directly in palm6_dbmigrate/server.lua; no sql/0073 file exists.',
    },
    {
        check: 'migrations',
        key: 'gap:0004',
        reason: 'Never used. No sql/0004 file is in git history; the number was skipped when the early migrations were written.',
    },
    {
        check: 'migrations',
        key: 'gap:0005',
        reason: 'Never used. No sql/0005 file is in git history; the number was skipped when the early migrations were written.',
    },
    {
        check: 'migrations',
        key: 'gap:0010',
        reason:
            'sql/0010_properties.sql existed and was DELETED by commit f6862cb '
            + '("revert: remove gtarp_housing - duplicates recipe-provided qbx_properties"). '
            + 'The number stays burnt so it can never be reused for something else.',
    },
];
