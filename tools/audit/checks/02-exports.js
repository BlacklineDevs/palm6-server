// ============================================================================
// CHECK: exports
// Every cross-resource export call names a resource that exists, a function
// that resource really registers, and a realm the caller can actually reach.
//
// WHAT THIS DOES *NOT* CERTIFY - read this before trusting a green result.
// A declared fxmanifest `dependencies` entry does NOT make a bare
// `exports.other:Fn()` safe. `dependencies` only orders resources at BOOT. At
// runtime the target can be stopped, restarted or crashed, and indexing the
// export of a stopped resource raises. So a call being listed as a dependency
// proves nothing about a call site; only a pcall (or a GetResourceState check
// AND a pcall) does. This check deliberately does not try to rule on that,
// because the guard is often a resource-local helper that wraps pcall, and a
// check that guesses at wrappers produces false accusations - which is worse
// than no check. What it DOES prove is that the name on the other end exists
// and is reachable from the calling realm.
// ============================================================================
'use strict';

module.exports = {
    id: 'exports',
    title: 'every cross-resource export call resolves to a real, reachable export',
    protects:
        'A call to an export that does not exist, or exists only on the other realm, is '
        + 'a runtime nil-index. Where the call site is pcall-guarded (most are here) it '
        + 'does not even error: the feature just silently never works, forever.',
    keyFormat: "'<target>:<Fn> <- <caller file>' for a missing export, "
        + "'realm:<target>:<Fn> <- <caller file>' for a realm mismatch",

    run(repo) {
        // ---- registrations: exports('Name', fn), per resource per realm ----
        const reg = new Map();   // resource -> Map(name -> [{file, line, side}])
        for (const f of repo.luaFiles) {
            for (const m of f.code.matchAll(/\bexports\s*\(/g)) {
                const lit = f.literalAfter(m.index + m[0].length);
                if (!lit) continue;
                if (!reg.has(f.resource)) reg.set(f.resource, new Map());
                const byName = reg.get(f.resource);
                if (!byName.has(lit.value)) byName.set(lit.value, []);
                byName.get(lit.value).push({ file: f.rel, line: lit.line, side: f.side });
            }
        }

        // ---- calls: exports.target:Fn(...) and exports['target']:Fn(...) ---
        const calls = [];
        for (const f of repo.luaFiles) {
            for (const m of f.code.matchAll(/\bexports\s*\.\s*([A-Za-z_]\w*)\s*:\s*([A-Za-z_]\w*)/g)) {
                calls.push({ target: m[1], fn: m[2], file: f.rel, line: f.lineAt(m.index), side: f.side, res: f.resource });
            }
            for (const m of f.code.matchAll(/\bexports\s*\[/g)) {
                const lit = f.literalAfter(m.index + m[0].length);
                if (!lit) continue;   // exports[GetCurrentResourceName()] - self-call, nothing to resolve
                const tail = f.code.slice(lit.end, lit.end + 40).match(/^\s*\]\s*:\s*([A-Za-z_]\w*)/);
                if (!tail) continue;
                calls.push({ target: lit.value, fn: tail[1], file: f.rel, line: f.lineAt(m.index), side: f.side, res: f.resource });
            }
        }

        const violations = [];
        let resolved = 0;
        let external = 0;

        for (const c of calls) {
            // Out-of-repo target (ox_target, qbx_core, Renewed-Banking, ...):
            // nothing in this tree can prove or disprove its export list.
            if (!repo.resources.has(c.target)) { external++; continue; }
            const byName = reg.get(c.target);
            const defs = byName && byName.get(c.fn);
            if (!defs || defs.length === 0) {
                violations.push({
                    key: c.target + ':' + c.fn + ' <- ' + c.file,
                    what: 'exports.' + c.target + ':' + c.fn + '() - ' + c.target
                        + ' is in this repo and registers no export by that name',
                    where: [c.file + ':' + c.line],
                });
                continue;
            }
            resolved++;

            // Realm. A client script can only see the target's CLIENT exports;
            // a server script only its SERVER exports. `shared` satisfies both,
            // and an unclassified file (not listed in any *_scripts block)
            // proves nothing, so both are skipped rather than guessed at.
            if (!c.side || c.side === 'shared') continue;
            const reachable = defs.some((d) => !d.side || d.side === 'shared' || d.side === c.side);
            if (reachable) continue;
            violations.push({
                key: 'realm:' + c.target + ':' + c.fn + ' <- ' + c.file,
                what: 'exports.' + c.target + ':' + c.fn + '() is called from a ' + c.side
                    + ' script but ' + c.target + ' only registers it on the '
                    + defs.map((d) => d.side).join('/') + ' realm, so the call can never resolve',
                where: [c.file + ':' + c.line].concat(defs.map((d) => 'defined ' + d.side + ' @ ' + d.file + ':' + d.line)),
            });
        }

        return {
            violations,
            stats: [
                calls.length + ' export calls (' + resolved + ' resolved in-repo, ' + external + ' to out-of-repo resources)',
                [...reg.keys()].length + ' resources register at least one export',
            ],
        };
    },
};
