// ============================================================================
// CHECK: events
// The palm6_* event graph has no orphans: nothing is raised that no handler
// listens for, and nothing is registered that nothing raises.
//
// TWO TRAPS THIS CHECK IS BUILT AROUND
//
// 1. A DYNAMIC RAISE. A literal-string grep misses an event name assembled at
//    the call site. This repo does exactly that:
//      TriggerServerEvent(ok and 'palm6_fc_combat:accept'
//                            or 'palm6_fc_combat:decline')
//    A "first literal" reader credits :accept and then reports :decline as
//    raised by nobody. The fix is not a special case for ternaries: the name
//    argument is read as EVERY literal in the first argument, so both branches
//    are collected, and `Config.X or 'literal'` falls out for free.
//
// 2. A DYNAMIC REGISTRATION. Four sites register a handler under a name held
//    in a variable. Those cannot be read from the call at all, so each one is
//    declared in allowlist.js with the names it really registers and the
//    reason. A dynamic site that is NOT declared there fails this check, so
//    the blind spot cannot grow quietly.
//
// SCOPE: palm6_* names only. A name owned by a recipe resource
// (police:server:policeAlert, evidence:server:CreateCasing, ...) has producers
// and consumers outside this repo, so this tree cannot rule on it.
// ============================================================================
'use strict';

const { firstArgLiterals } = require('../lib/calls');

const REGISTER = ['RegisterNetEvent', 'RegisterServerEvent', 'AddEventHandler'];
const RAISE = ['TriggerEvent', 'TriggerServerEvent', 'TriggerClientEvent', 'TriggerLatentClientEvent'];
const OWNED = /^palm6_/;

module.exports = {
    id: 'events',
    title: 'the palm6_* event graph has no orphans',
    protects:
        'An event raised with no handler is a feature that silently does nothing. A '
        + 'handler nothing raises is dead code that still occupies a network name: a '
        + 'client-facing RegisterNetEvent with no producer is an entry point nobody is '
        + 'watching. Both shapes survive every existing check in this repo, because both '
        + 'parse, load and boot perfectly.',
    keyFormat: "'dynamic:<file>' for a dynamic registration site, "
        + "'raised-unhandled:<event>' / 'registered-unraised:<event>' for an orphan",

    run(repo, allow) {
        const registered = new Map();
        const raised = new Map();
        const note = (map, name, loc) => {
            if (!map.has(name)) map.set(name, []);
            map.get(name).push(loc);
        };

        const dynamicSites = [];
        const violations = [];

        for (const f of repo.luaFiles) {
            for (const fn of REGISTER) {
                for (const m of f.code.matchAll(new RegExp('\\b' + fn + '\\s*\\(', 'g'))) {
                    const open = m.index + m[0].length - 1;
                    const lits = firstArgLiterals(f, open);
                    if (lits.length === 0) {
                        dynamicSites.push({ file: f.rel, line: f.lineAt(m.index), fn });
                        continue;
                    }
                    for (const l of lits) note(registered, l.value, f.rel + ':' + l.line + ' (' + fn + ')');
                }
            }
            for (const fn of RAISE) {
                for (const m of f.code.matchAll(new RegExp('\\b' + fn + '\\s*\\(', 'g'))) {
                    const open = m.index + m[0].length - 1;
                    const lits = firstArgLiterals(f, open);
                    if (lits.length === 0) {
                        dynamicSites.push({ file: f.rel, line: f.lineAt(m.index), fn });
                        continue;
                    }
                    for (const l of lits) note(raised, l.value, f.rel + ':' + l.line + ' (' + fn + ')');
                }
            }
        }

        // ---- dynamic sites: declared, or a failure -------------------------
        for (const d of dynamicSites) {
            const key = 'dynamic:' + d.file;
            const entry = allow.find('events', key);
            if (!entry) {
                violations.push({
                    key,
                    what: d.fn + '() registers or raises a name this checker cannot read '
                        + '(the first argument is not a literal). Declare it in '
                        + 'tools/audit/allowlist.js with the names it resolves to and why, '
                        + 'or the graph below is quietly incomplete.',
                    where: [d.file + ':' + d.line],
                });
                continue;
            }
            for (const name of (entry.registers || [])) {
                note(registered, name, d.file + ':' + d.line + ' (dynamic, declared in allowlist.js)');
            }
            for (const name of (entry.raises || [])) {
                note(raised, name, d.file + ':' + d.line + ' (dynamic, declared in allowlist.js)');
            }
        }

        // ---- orphans -------------------------------------------------------
        for (const [name, locs] of [...raised].sort()) {
            if (!OWNED.test(name) || registered.has(name)) continue;
            violations.push({
                key: 'raised-unhandled:' + name,
                what: "'" + name + "' is raised but no resource in this tree registers a handler for it",
                where: locs.slice(0, 4),
            });
        }
        for (const [name, locs] of [...registered].sort()) {
            if (!OWNED.test(name) || raised.has(name)) continue;
            violations.push({
                key: 'registered-unraised:' + name,
                what: "'" + name + "' has a handler but nothing in this tree ever raises it",
                where: locs.slice(0, 4),
            });
        }

        return {
            violations,
            stats: [
                registered.size + ' event names registered, ' + raised.size + ' raised',
                dynamicSites.length + ' dynamic site(s), all declared in allowlist.js',
            ],
        };
    },
};
