// ============================================================================
// CHECK: ensure-list
// custom.cfg's ensure list and resources/[custom] agree.
//   A. every `ensure <name>` names a directory that exists here
//   B. every resource directory here is ensured
//
// A resource directory with a manifest is a resource whether or not anyone
// remembered to start it, so directories are read from the tree and not from a
// list. `[config_overrides]` is a FiveM CATEGORY directory (the square brackets
// are the marker), so its children are the resources, not it - which is why
// qbx_core_overrides and friends resolve at all.
//
// Direction A catches a rename or a delete: FiveM prints one line at boot for
// an ensure it cannot resolve, in the middle of a few thousand, and then runs
// the server anyway.
// Direction B catches the opposite: a resource written, committed, and never
// started. Everything about it looks finished except that it is not running.
// The two deliberate exceptions are in allowlist.js with the reason each.
// ============================================================================
'use strict';

module.exports = {
    id: 'ensure-list',
    title: 'the custom.cfg ensure list and the resource tree agree',
    protects:
        'An ensure for a directory that no longer exists is one lost line in the boot '
        + 'log. A resource directory nobody ensures is a feature that was built, merged '
        + 'and never ran. Neither shows up in any other check.',
    keyFormat: "'<resource name>' (direction B) or 'ensure-missing:<name>' (direction A)",

    run(repo) {
        if (!repo.cfg.exists) {
            return {
                violations: [{ key: 'missing-cfg', what: 'custom.cfg not found at the repo root', where: ['custom.cfg'] }],
                stats: [],
            };
        }

        const ensured = new Map();
        for (const m of repo.cfg.code.matchAll(/^[ \t]*ensure[ \t]+(\S+)/gm)) {
            ensured.set(m[1], 'custom.cfg:' + repo.cfg.lineAt(m.index));
        }
        // `stop <name>` is a deliberate statement about a resource too: it is
        // how custom.cfg overrides the panel-managed server.cfg. Collected so
        // direction A does not report a stop target as a phantom ensure.
        const stopped = new Map();
        for (const m of repo.cfg.code.matchAll(/^[ \t]*stop[ \t]+(\S+)/gm)) {
            stopped.set(m[1], 'custom.cfg:' + repo.cfg.lineAt(m.index));
        }

        const violations = [];

        for (const [name, where] of [...ensured].sort()) {
            if (repo.resources.has(name)) continue;
            violations.push({
                key: 'ensure-missing:' + name,
                what: 'custom.cfg ensures ' + name + ' but there is no resource directory with a '
                    + 'manifest by that name under resources/[custom]',
                where: [where],
            });
        }

        for (const name of [...repo.resources.keys()].sort()) {
            if (ensured.has(name)) continue;
            const extra = stopped.has(name) ? ' (custom.cfg does `stop ' + name + '` at ' + stopped.get(name) + ')' : '';
            violations.push({
                key: name,
                what: 'resource ' + name + ' exists but custom.cfg never ensures it' + extra,
                where: [require('path').relative(repo.root, repo.resources.get(name).dir).replace(/\\/g, '/')],
            });
        }

        return {
            violations,
            stats: [
                ensured.size + ' ensure lines, ' + repo.resources.size + ' resource directories',
            ],
        };
    },
};
