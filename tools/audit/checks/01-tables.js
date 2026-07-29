// ============================================================================
// CHECK: tables
// Every palm6_* table a query names has a CREATE TABLE somewhere in this repo.
// ============================================================================
'use strict';

// A table reference is a name in a SQL position: after FROM / JOIN / INTO /
// UPDATE / TABLE / TRUNCATE. Anchoring on the keyword is what keeps English
// prose out of the results: this repo's notify strings say things like
// "Update your gang", and a bare /palm6_\w+/ sweep over every literal would
// also pick up resource names passed to GetResourceState.
const REF = /\b(?:FROM|JOIN|INTO|UPDATE|TRUNCATE(?:\s+TABLE)?|(?:ALTER|DROP|CREATE)\s+TABLE(?:\s+IF\s+(?:NOT\s+)?EXISTS)?|TABLE\s+IF\s+(?:NOT\s+)?EXISTS)\s+`?([A-Za-z_]\w*)`?/gi;
const CREATE = /\bCREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?`?([A-Za-z_]\w*)`?/gi;

// Scope. The invariant is about tables this layer OWNS. qbx / ox recipe tables
// (players, player_vehicles, ...) are created by resources that are not in this
// repo, so demanding a CREATE for them would be demanding the impossible.
const OWNED = /^palm6_/;

module.exports = {
    id: 'tables',
    title: 'every palm6_* table referenced by a query has a creator',
    protects:
        'A referenced-but-never-created table does not error loudly. Nearly every query '
        + 'in this tree is pcall-wrapped, so the resource degrades to "does nothing" and '
        + 'the feature silently stops working on a fresh box or a restored backup, while '
        + 'looking fine on the live one where the table happens to already exist.',
    keyFormat: '<table name>',

    run(repo) {
        const refs = new Map();
        const creates = new Map();
        const note = (map, name, loc) => {
            if (!map.has(name)) map.set(name, []);
            map.get(name).push(loc);
        };

        // Lua: only STRING literals are searched. Comments never are, which
        // matters here because several config.lua files quote table names in
        // prose and custom.cfg literally spells out grep commands.
        for (const f of repo.luaFiles) {
            for (const s of f.strings) {
                for (const m of s.value.matchAll(REF)) note(refs, m[1], f.rel + ':' + s.line);
                for (const m of s.value.matchAll(CREATE)) note(creates, m[1], f.rel + ':' + s.line);
            }
        }
        // sql/: comment-stripped, then searched the same way.
        for (const f of repo.sqlFiles) {
            for (const m of f.code.matchAll(REF)) note(refs, m[1], f.rel + ':' + f.lineAt(m.index));
            for (const m of f.code.matchAll(CREATE)) note(creates, m[1], f.rel + ':' + f.lineAt(m.index));
        }

        const owned = [...refs.keys()].filter((t) => OWNED.test(t)).sort();
        const violations = [];
        for (const t of owned) {
            if (creates.has(t)) continue;
            violations.push({
                key: t,
                what: 'table `' + t + '` is queried but never created',
                where: refs.get(t).slice(0, 4),
            });
        }

        const createdOwned = [...creates.keys()].filter((t) => OWNED.test(t));
        return {
            violations,
            stats: [
                owned.length + ' palm6_* tables referenced',
                createdOwned.length + ' palm6_* tables created',
            ],
        };
    },
};
