// ============================================================================
// CHECK: eventguard
// Every palm6_eventguard budget names an event that is really a NET event, and
// palm6_eventguard is ensured before every resource it guards.
//
// TWO FACTS, BOTH LOAD-BEARING
//
// 1. A budget for a name nothing RegisterNetEvent's is dead weight. The guard
//    hooks with AddEventHandler, so a name no resource opens to the network can
//    never carry a client call and the budget guards nothing. config.lua says
//    this in its own header; this check is that sentence made executable.
//    palm6_eventguard's own registrations are excluded when looking for the
//    owner, or every budget would trivially prove itself.
//
// 2. ORDER. FiveM appends handlers in registration order and CancelEvent() only
//    stops handlers that have not run yet, so a guard registered AFTER the
//    owning resource cannot drop anything. The budget still exists, the boot
//    banner still counts it, and it does nothing. custom.cfg repeats this
//    warning five times; nothing enforced it until now.
// ============================================================================
'use strict';

module.exports = {
    id: 'eventguard',
    title: 'every eventguard budget guards a real net event, and guards it first',
    protects:
        'A budget on a name nothing net-registers is inert. A budget on a resource '
        + 'ensured BEFORE palm6_eventguard is also inert. Both look identical to a '
        + 'working ratelimit from the console banner, which counts budgets, not effect.',
    keyFormat: "'<event name>' for an unowned budget, 'order:<resource>' for a late guard",

    run(repo) {
        const cfgFile = repo.luaFiles.find((f) => /palm6_eventguard\/config\.lua$/.test(f.rel));
        if (!cfgFile) {
            return {
                violations: [{
                    key: 'missing-config',
                    what: 'palm6_eventguard/config.lua not found, so no budget can be verified',
                    where: ['resources/[custom]/palm6_eventguard/config.lua'],
                }],
                stats: [],
            };
        }

        // Budgets are table keys: ['name'] = { calls = n, window_seconds = n }.
        // Reading them as KEYS rather than as any-string-in-the-file keeps the
        // long prose comments in that file (which quote event names constantly)
        // out of the result.
        const budgets = [];
        for (const s of cfgFile.strings) {
            const before = cfgFile.code.slice(Math.max(0, s.start - 4), s.start);
            const after = cfgFile.code.slice(s.end, s.end + 10);
            if (/\[\s*$/.test(before) && /^\s*\]\s*=/.test(after)) {
                budgets.push({ name: s.value, line: s.line });
            }
        }

        // Net registrations, excluding palm6_eventguard itself.
        const net = new Map();
        for (const f of repo.luaFiles) {
            if (f.resource === 'palm6_eventguard') continue;
            for (const m of f.code.matchAll(/\bRegisterNetEvent\s*\(/g)) {
                const lit = f.literalAfter(m.index + m[0].length);
                if (!lit) continue;
                if (!net.has(lit.value)) net.set(lit.value, []);
                net.get(lit.value).push({ file: f.rel, line: lit.line, resource: f.resource });
            }
        }

        const violations = [];
        for (const b of budgets) {
            if (net.has(b.name)) continue;
            violations.push({
                key: b.name,
                what: "budget for '" + b.name + "' but no resource in this repo calls "
                    + 'RegisterNetEvent for that name, so the budget can never fire',
                where: ['resources/[custom]/palm6_eventguard/config.lua:' + b.line],
            });
        }

        // Ensure order.
        const order = [];
        for (const m of repo.cfg.code.matchAll(/^[ \t]*ensure[ \t]+(\S+)/gm)) {
            order.push({ name: m[1], line: repo.cfg.lineAt(m.index) });
        }
        const guardIdx = order.findIndex((o) => o.name === 'palm6_eventguard');
        if (guardIdx === -1) {
            violations.push({
                key: 'order:not-ensured',
                what: 'palm6_eventguard has no ensure line in custom.cfg, so none of its budgets load',
                where: ['custom.cfg'],
            });
        } else {
            const owners = new Set();
            for (const b of budgets) for (const r of (net.get(b.name) || [])) owners.add(r.resource);
            for (const owner of [...owners].sort()) {
                const i = order.findIndex((o) => o.name === owner);
                if (i === -1 || i > guardIdx) continue;
                violations.push({
                    key: 'order:' + owner,
                    what: owner + ' is ensured at custom.cfg:' + order[i].line + ', BEFORE palm6_eventguard at '
                        + 'custom.cfg:' + order[guardIdx].line + '. Its guards register at the end of the '
                        + 'handler chain, so CancelEvent() cannot stop the owning handler and every budget '
                        + 'for its events is a no-op.',
                    where: ['custom.cfg:' + order[i].line],
                });
            }
        }

        return {
            violations,
            stats: [
                budgets.length + ' budgets declared',
                (guardIdx === -1 ? 'palm6_eventguard not ensured' : 'palm6_eventguard ensured at position ' + (guardIdx + 1) + ' of ' + order.length),
            ],
        };
    },
};
