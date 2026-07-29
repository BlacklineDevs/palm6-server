// ============================================================================
// CHECK: migrations
// Migration numbering has TWO authorities, and sql/ is not the only one.
//
// palm6_dbmigrate/server.lua owns numbers that have no sql/ file at all: 0067
// (racing) and 0068-0073 (business) exist only as entries in its STATEMENTS
// table. `ls sql/` shows a highest number of 0074 with an unbroken run up to
// 0066, which reads exactly like "0067 is free". It is not. Numbering a new
// sql/0067 by looking at the directory is a collision that no tool in this repo
// would have caught before this check existed.
//
// THREE FACTS ARE CHECKED
//  1. No number is claimed twice inside sql/.
//  2. Every number palm6_dbmigrate claims either has a matching sql/ file or is
//     declared dbmigrate-owned in allowlist.js. Every hole in the sequence is
//     declared too, so a hole is a decision on the record rather than an
//     accident nobody noticed.
//  3. Where BOTH authorities create the same table, the CREATE bodies match.
//     palm6_dbmigrate's own header demands this ("copied VERBATIM from its sql/
//     file") because a divergence is invisible on the live box, where the table
//     already exists, and only explodes on a fresh box or a restored backup.
//
// The check also prints the next free number across both authorities, which is
// the number a new migration should actually use.
// ============================================================================
'use strict';

const { scanSql } = require('../lib/lualex');

const NUM = /^(\d{4})/;

/** Normalise SQL for comparison: collapse whitespace, drop backticks and case. */
function normalise(sql) {
    return sql.replace(/`/g, '').replace(/\s+/g, ' ').trim().toLowerCase();
}

/** Pull `CREATE TABLE ... ( ... )` bodies out of a SQL blob, keyed by table. */
function creates(sql) {
    const out = new Map();
    const re = /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?`?([A-Za-z_]\w*)`?\s*\(/gi;
    let m;
    while ((m = re.exec(sql)) !== null) {
        let i = m.index + m[0].length - 1;
        let depth = 0;
        do {
            const c = sql[i];
            if (c === '(') depth++;
            else if (c === ')') depth--;
            i++;
        } while (i < sql.length && depth > 0);
        out.set(m[1], sql.slice(m.index, i));
    }
    return out;
}

module.exports = {
    id: 'migrations',
    title: 'migration numbering is consistent across BOTH authorities',
    protects:
        'sql/ is not the authority for the next free number. Reusing a number that '
        + 'palm6_dbmigrate already owns puts two different migrations under one identity, '
        + 'and tools/apply-migrations.sh tracks applied files by filename + sha256, so the '
        + 'collision resolves in whichever order the two happen to run.',
    keyFormat: "'dbmigrate-only:<NNNN>', 'gap:<NNNN>', 'duplicate:<NNNN>', 'divergent:<NNNN>:<table>'",

    run(repo) {
        const violations = [];

        // ---- sql/ ----------------------------------------------------------
        const sqlByNum = new Map();
        for (const f of repo.sqlFiles) {
            const m = f.name.match(NUM);
            if (!m) continue;
            if (!sqlByNum.has(m[1])) sqlByNum.set(m[1], []);
            sqlByNum.get(m[1]).push(f);
        }
        for (const [num, files] of [...sqlByNum].sort()) {
            if (files.length < 2) continue;
            violations.push({
                key: 'duplicate:' + num,
                what: 'migration number ' + num + ' is claimed by more than one file in sql/',
                where: files.map((f) => f.rel),
            });
        }

        // ---- palm6_dbmigrate ------------------------------------------------
        const dbm = repo.luaFiles.find((f) => /palm6_dbmigrate\/server\.lua$/.test(f.rel));
        const dbmByNum = new Map();
        if (dbm) {
            // Entries are { name = '0068 palm6_business', sql = [[ ... ]] }.
            // The name literal is read off the `name =` key, not off any string
            // in the file, so the long explanatory comments cannot leak in.
            for (const m of dbm.code.matchAll(/\bname\s*=\s*/g)) {
                const lit = dbm.literalAfter(m.index + m[0].length);
                if (!lit) continue;
                const num = lit.value.match(NUM);
                if (!num) continue;
                // The `sql = [[...]]` literal is the next long string after it.
                const body = dbm.strings.find((s) => s.start > lit.end && s.long);
                if (!dbmByNum.has(num[1])) dbmByNum.set(num[1], []);
                // Strip SQL comments from the embedded body before comparing.
                // The sql/ side is already comment-stripped, and the dbmigrate
                // copies carry extra explanatory `--` lines INSIDE the CREATE.
                // Comparing raw would report every one of them as a divergence.
                dbmByNum.get(num[1]).push({ label: lit.value, line: lit.line, sql: body ? scanSql(body.value) : '' });
            }
        } else {
            violations.push({
                key: 'missing-dbmigrate',
                what: 'palm6_dbmigrate/server.lua not found, so half the migration authority cannot be read',
                where: ['resources/[custom]/palm6_dbmigrate/server.lua'],
            });
        }

        // ---- numbers dbmigrate owns alone ----------------------------------
        for (const num of [...dbmByNum.keys()].sort()) {
            if (sqlByNum.has(num)) continue;
            const entries = dbmByNum.get(num);
            violations.push({
                key: 'dbmigrate-only:' + num,
                what: 'migration ' + num + ' exists ONLY in palm6_dbmigrate/server.lua and has no sql/ file. '
                    + 'Anyone picking the next number from `ls sql/` will collide with it.',
                where: entries.map((e) => 'resources/[custom]/palm6_dbmigrate/server.lua:' + e.line + '  ' + e.label),
            });
        }

        // ---- holes ----------------------------------------------------------
        const all = new Set([...sqlByNum.keys(), ...dbmByNum.keys()]);
        const max = Math.max(0, ...[...all].map(Number));
        for (let i = 1; i <= max; i++) {
            const num = String(i).padStart(4, '0');
            if (all.has(num)) continue;
            violations.push({
                key: 'gap:' + num,
                what: 'migration number ' + num + ' is claimed by neither sql/ nor palm6_dbmigrate. '
                    + 'A hole is fine if it is on purpose; record why, so nobody reuses a burnt number.',
                where: ['sql/', 'resources/[custom]/palm6_dbmigrate/server.lua'],
            });
        }

        // ---- verbatim copies -------------------------------------------------
        for (const [num, entries] of [...dbmByNum].sort()) {
            const files = sqlByNum.get(num);
            if (!files) continue;
            const fileCreates = new Map();
            for (const f of files) for (const [t, body] of creates(f.code)) fileCreates.set(t, { body, rel: f.rel });
            for (const e of entries) {
                for (const [table, body] of creates(e.sql)) {
                    const ref = fileCreates.get(table);
                    if (!ref) continue;        // dbmigrate creates a table that number's file does not: not this check's business
                    if (normalise(body) === normalise(ref.body)) continue;
                    violations.push({
                        key: 'divergent:' + num + ':' + table,
                        what: 'the CREATE TABLE for `' + table + '` in palm6_dbmigrate differs from the one in '
                            + ref.rel + '. palm6_dbmigrate\'s own header requires these to be verbatim copies, '
                            + 'because a divergence is invisible on the live box and only bites on a fresh one.',
                        where: ['resources/[custom]/palm6_dbmigrate/server.lua:' + e.line, ref.rel],
                    });
                }
            }
        }

        return {
            violations,
            stats: [
                sqlByNum.size + ' numbers in sql/, ' + dbmByNum.size + ' numbers in palm6_dbmigrate',
                'next free migration number across BOTH authorities: ' + String(max + 1).padStart(4, '0'),
            ],
        };
    },
};
