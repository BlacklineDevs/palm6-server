// ============================================================================
// CHECK: command-aces
// Both directions of the command <-> ACE contract in custom.cfg:
//   A. every RegisterCommand(..., restricted = true) has a command.<name> ACE
//   B. every add_ace ... command.<name> names a command that exists here
//
// THE DYNAMIC-NAME TRAP AGAIN, in a second dialect. Several commands are
// registered under a config constant rather than a literal:
//   RegisterCommand(Config.DiagCommand, ...)                  -- palm6_perf
//   RegisterCommand(Config.Command, ...)                      -- palm6_economy, palm6_mapeditor
//   RegisterCommand(Config.Interior.CaptureCommand or 'bizshell', ...)
// A literal-only reader concludes /diag, /economy, /mapedit and /bizshell do
// not exist and reports four false "ACE for a command nobody registers"
// failures. So the first argument is read as (a) every literal in it, which
// covers the `or 'bizshell'` fallback, plus (b) a lookup of any Config.a.b path
// against `Config.a.b = '<literal>'` in the same resource.
//
// Direction A is the one with teeth. ox_lib's addCommand auto-grants
// command.<name> to group.admin, but a plain RegisterCommand(..., true) does
// not: FiveM restricts it to principals that hold the ACE, and the only one
// this server grants blanket is `add_ace group.owner command allow`. So a
// restricted command with no ACE line is reachable by the owner and by nobody
// else - including every admin who is supposed to have it.
// ============================================================================
'use strict';

const { firstArgLiterals, lastArgText, argText } = require('../lib/calls');
const { matchEnd } = require('../lib/luablocks');

/**
 * Resolve `Config.a.b` style paths against `Config.a.b = '<literal>'`
 * assignments in the SAME resource.
 *
 * Only the full dotted path counts. An earlier version also matched the last
 * segment on its own ("CaptureCommand = 'bizshell'" anywhere in the resource),
 * which invented command names out of unrelated table keys and would have
 * masked a real missing-ACE finding. Narrow and occasionally silent beats wide
 * and confidently wrong for a check people are asked to gate on.
 */
function resolveConfigPath(resource, expr) {
    const out = [];
    for (const m of expr.matchAll(/\b((?:Config|CONFIG)(?:\.[A-Za-z_]\w*)+)\b/g)) {
        const dotted = m[1];
        const segs = dotted.split('.');
        for (const f of resource.files) {
            // Flat form: Config.a.b = 'literal'
            const re = new RegExp('(^|[^\\w.])' + dotted.replace(/\./g, '\\.') + '\\s*=\\s*', 'g');
            for (const a of f.code.matchAll(re)) {
                const lit = f.literalAfter(a.index + a[0].length);
                if (lit) out.push(lit.value);
            }
            // Nested form: Config.a = { b = 'literal' }. Resolved by finding
            // the parent assignment, taking its balanced table span, and
            // looking for the last segment only INSIDE that span - so a key of
            // the same name in an unrelated table cannot leak in.
            if (segs.length < 3) continue;
            const parent = segs.slice(0, -1).join('.');
            const key = segs[segs.length - 1];
            const pre = new RegExp('(^|[^\\w.])' + parent.replace(/\./g, '\\.') + '\\s*=\\s*\\{', 'g');
            for (const a of f.code.matchAll(pre)) {
                let i = a.index + a[0].length - 1;
                let depth = 0;
                do {
                    const c = f.code[i];
                    if (c === '{') depth++;
                    else if (c === '}') depth--;
                    i++;
                } while (i < f.code.length && depth > 0);
                const spanStart = a.index;
                const spanEnd = i;
                const kre = new RegExp('(^|[^\\w.])' + key + '\\s*=\\s*', 'g');
                const span = f.code.slice(spanStart, spanEnd);
                for (const k of span.matchAll(kre)) {
                    const lit = f.literalAfter(spanStart + k.index + k[0].length);
                    if (lit && lit.start < spanEnd) out.push(lit.value);
                }
            }
        }
    }
    return out;
}

/**
 * Per-resource map of command-registering WRAPPERS to the restricted flag they
 * hardcode.
 *
 * Nearly every resource here has `function Bridge.RegisterCommand(name, handler)
 * RegisterCommand(name, handler, false) end`. Two of them - palm6_perf and
 * palm6_economy - have a wrapper with the SAME name that passes `true`. Reading
 * only the bare RegisterCommand call therefore classifies /diag and /economy as
 * unrestricted, and would classify any future restricted-via-wrapper command as
 * unrestricted too, which is a silent hole in direction A. So the wrapper is
 * resolved: a function whose first parameter is passed straight through to
 * RegisterCommand inherits that call's restricted flag.
 */
function wrapperFlags(resource) {
    const out = new Map();
    for (const f of resource.files) {
        for (const m of f.code.matchAll(/\bfunction\s+([A-Za-z_][\w.]*)\s*\(\s*([A-Za-z_]\w*)/g)) {
            const body = f.code.slice(m.index, matchEnd(f.code, m.index));
            const inner = body.match(new RegExp('(^|[^\\w.:])RegisterCommand\\s*\\(\\s*' + m[2] + '\\s*,[^)]*?,\\s*(true|false)\\s*\\)'));
            if (!inner) continue;
            out.set(m[1], inner[2] === 'true');
        }
    }
    return out;
}

module.exports = {
    id: 'command-aces',
    title: 'restricted commands and custom.cfg ACE grants agree in both directions',
    protects:
        'A RegisterCommand(..., true) with no matching add_ace is runnable by group.owner '
        + 'and literally nobody else, because owner holds the blanket `command` ace. Every '
        + 'admin and mod silently has no access to it. An add_ace for a command that no '
        + 'longer exists is the mirror image: it reads like coverage and grants nothing.',
    keyFormat: "'restricted-without-ace:<name>' or 'ace-without-command:<name>'",

    run(repo) {
        // ---- commands registered in this tree -----------------------------
        const commands = new Map();   // name -> [{file, line, restricted}]
        const addCmd = (name, rec) => {
            if (!commands.has(name)) commands.set(name, []);
            commands.get(name).push(rec);
        };

        for (const res of repo.resources.values()) {
            const wrappers = wrapperFlags(res);
            for (const f of res.files) {
                // Bare RegisterCommand plus any wrapper whose name ends in it
                // (Bridge.RegisterCommand is the house pattern). Only the BARE
                // form can carry the restricted flag; the wrappers in this repo
                // all hardcode `false` inside themselves.
                for (const m of f.code.matchAll(/(^|[^\w.:])((?:[A-Za-z_]\w*\.)?RegisterCommand)\s*\(/g)) {
                    // Skip the wrapper's own DEFINITION line: `function
                    // Bridge.RegisterCommand(name, handler)` is not a call.
                    if (/\bfunction\s+$/.test(f.code.slice(Math.max(0, m.index - 12), m.index + m[1].length))) continue;
                    const bare = m[2] === 'RegisterCommand';
                    const open = m.index + m[0].length - 1;
                    const names = firstArgLiterals(f, open).map((l) => l.value);
                    const arg0 = argText(f, open, 0) || '';
                    for (const n of resolveConfigPath(res, arg0)) {
                        if (!names.includes(n)) names.push(n);
                    }
                    if (names.length === 0) continue;   // a wrapper's own `name` parameter
                    // restricted is the LAST argument when present. See
                    // lib/calls.js lastArgText for why indexing by position
                    // does not work on a Lua handler body.
                    const restricted = bare
                        ? /^\s*true\s*$/.test(lastArgText(f, open))
                        : (wrappers.get(m[2]) === true);
                    for (const n of names) {
                        addCmd(n, { file: f.rel, line: f.lineAt(m.index + m[1].length), restricted });
                    }
                }
                // ox_lib's lib.addCommand auto-grants command.<name> to
                // group.admin, so it never needs an add_ace line. Collected so
                // direction B does not report a false missing command.
                for (const m of f.code.matchAll(/\blib\.addCommand\s*\(/g)) {
                    const open = m.index + m[0].length - 1;
                    for (const l of firstArgLiterals(f, open)) {
                        addCmd(l.value, { file: f.rel, line: l.line, restricted: false, oxlib: true });
                    }
                }
            }
        }

        // ---- add_ace lines in custom.cfg -----------------------------------
        const aces = new Map();   // command name -> [cfg line]
        for (const m of repo.cfg.code.matchAll(/^[ \t]*add_ace[ \t]+(\S+)[ \t]+command\.(\S+)[ \t]+(\S+)/gm)) {
            const name = m[2];
            if (!aces.has(name)) aces.set(name, []);
            aces.get(name).push('custom.cfg:' + repo.cfg.lineAt(m.index));
        }

        const violations = [];

        // ---- A: restricted with no ACE -------------------------------------
        for (const [name, recs] of [...commands].sort()) {
            if (!recs.some((r) => r.restricted)) continue;
            if (aces.has(name)) continue;
            violations.push({
                key: 'restricted-without-ace:' + name,
                what: "/" + name + " is RegisterCommand(..., true) but custom.cfg has no "
                    + '`add_ace <group> command.' + name + ' allow` line, so only group.owner '
                    + '(via the blanket `command` ace) can run it',
                where: recs.filter((r) => r.restricted).map((r) => r.file + ':' + r.line),
            });
        }

        // ---- B: ACE with no command ----------------------------------------
        for (const [name, lines] of [...aces].sort()) {
            if (commands.has(name)) continue;
            violations.push({
                key: 'ace-without-command:' + name,
                what: 'add_ace grants command.' + name + ' but no resource in this repo '
                    + 'registers a command by that name',
                where: lines,
            });
        }

        return {
            violations,
            stats: [
                commands.size + ' distinct command names registered ('
                    + [...commands.values()].filter((r) => r.some((x) => x.restricted)).length + ' restricted)',
                aces.size + ' distinct command.<name> ACE grants in custom.cfg',
            ],
        };
    },
};
