// ============================================================================
// CHECK: stop-await
// No MySQL .await is reachable from an onResourceStop handler.
//
// WHY IT MATTERS
// oxmysql's `.await` form is Citizen.Await: it YIELDS the calling coroutine and
// resumes it when the query returns. During teardown the resource is never
// ticked again, so the coroutine is never resumed. A handler that awaits in a
// loop therefore writes the FIRST row and silently abandons every row after it,
// plus every statement below the loop. It looks like it works, because it does
// work when you test it by restarting a resource that only had one row to save.
//
// Both known-good exceptions in this repo carry the fix in their own comments:
// the callee takes an `inline` flag and uses the non-await call form, which
// hands the query to oxmysql (a separate, still-running resource) and returns.
//
// REACHABILITY, NOT PRESENCE. `AddEventHandler('onResourceStop', function()
// persistAll() end)` is exactly as broken as an inline await, so this walks the
// resource's own call graph. Its limits are documented in lib/luablocks.js and
// they all make it MISS things, never invent them.
// ============================================================================
'use strict';

const { firstArgLiterals, callEnd } = require('../lib/calls');
const { buildCallGraph, calleesIn, hasAwait } = require('../lib/luablocks');

module.exports = {
    id: 'stop-await',
    title: 'no MySQL .await is reachable from an onResourceStop handler',
    protects:
        'Teardown never resumes a yielded coroutine, so the first .await in a stop '
        + 'handler silently kills everything after it. The data loss is invisible until '
        + 'the day a deploy lands while several rows were dirty.',
    keyFormat: '<resource>::<call chain from the handler, joined by ->>',

    run(repo) {
        const violations = [];
        let handlers = 0;

        for (const res of repo.resources.values()) {
            // Server realm only: MySQL does not exist on the client, and
            // onClientResourceStop is a different event on a different realm.
            const serverFiles = res.files.filter((f) => f.side === 'server' || f.side === 'shared');
            if (serverFiles.length === 0) continue;
            const graph = buildCallGraph(serverFiles);

            for (const f of serverFiles) {
                for (const m of f.code.matchAll(/\bAddEventHandler\s*\(/g)) {
                    const open = m.index + m[0].length - 1;
                    const lits = firstArgLiterals(f, open);
                    if (!lits.some((l) => l.value === 'onResourceStop')) continue;
                    handlers++;
                    const body = f.code.slice(open, callEnd(f.code, open));
                    const line = f.lineAt(m.index);

                    if (hasAwait(body)) {
                        violations.push({
                            key: res.name + '::(inline)',
                            what: 'onResourceStop handler calls MySQL .await directly. The yield is '
                                + 'never resumed during teardown, so everything after the first await is lost.',
                            where: [f.rel + ':' + line],
                        });
                    }
                    for (const hit of graph.reachesAwait(calleesIn(body))) {
                        violations.push({
                            key: res.name + '::' + hit.via.join('->'),
                            what: 'onResourceStop handler reaches MySQL .await via ' + hit.via.join(' -> ')
                                + '. Either the awaiting path is unreachable from teardown (say why in '
                                + 'allowlist.js) or teardown loses every row after the first.',
                            where: [f.rel + ':' + line].concat(
                                hit.via.map((n) => {
                                    const d = graph.defs.get(n);
                                    return d ? (n + ' @ ' + d.file.rel + ':' + d.def.line) : n;
                                }),
                            ),
                        });
                    }
                }
            }
        }

        return {
            violations,
            stats: [handlers + ' server-side onResourceStop handler(s) inspected'],
        };
    },
};
