#!/usr/bin/env node
// ============================================================================
// tools/audit/run.js - repo-wide invariant checker.
//
// Every invariant here was established BY HAND at some point in the last few
// days, at real cost, and each was true only at the moment it was checked. A
// hand audit does not survive the next resource anyone adds. This runs all of
// them in one command and exits non-zero if any fails.
//
//   node tools/audit/run.js              # everything
//   node tools/audit/run.js tables       # one check, by id or substring
//   node tools/audit/run.js --list       # what the ids are
//   node tools/audit/run.js --root PATH  # audit a different tree
//   node tools/audit/run.js --self-test  # prove every check can FAIL
//
// No dependencies. tests/ has exactly one (fengari) and this needs none, so
// `node tools/audit/run.js` works on a clean clone with nothing installed.
// ============================================================================
'use strict';

const path = require('path');
const { loadRepo } = require('./lib/repo');
const { loadChecks } = require('./lib/checks');

// ---------------------------------------------------------------------------
// Allowlist wrapper. It is deliberately strict: an entry with no reason, or
// with a check id that does not exist, fails the run outright. An allowlist you
// can add to carelessly is not an allowlist, it is a mute button.
// ---------------------------------------------------------------------------
function loadAllowlist(checkIds) {
    const raw = require('./allowlist');
    const problems = [];
    raw.forEach((e, i) => {
        const at = 'allowlist.js entry #' + (i + 1) + ' (' + (e.key || 'no key') + ')';
        if (!e.check) problems.push(at + ': missing `check`');
        else if (!checkIds.has(e.check)) problems.push(at + ': `check: "' + e.check + '"` is not a check id');
        if (!e.key) problems.push(at + ': missing `key`');
        if (!e.reason || String(e.reason).trim().length < 20) {
            problems.push(at + ': missing or trivial `reason`. An allowlist entry without a real reason is a bug.');
        }
    });
    const used = new Set();
    return {
        problems,
        find(check, key) {
            const e = raw.find((x) => x.check === check && x.key === key);
            if (e) used.add(e);
            return e || null;
        },
        stale() {
            return raw.filter((e) => !used.has(e));
        },
    };
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------
function report(results, allow, opts) {
    const line = '-'.repeat(76);
    let failed = 0;

    for (const r of results) {
        const status = r.violations.length === 0 ? 'PASS' : 'FAIL';
        if (status === 'FAIL') failed++;
        console.log('');
        console.log(line);
        console.log(status + '  ' + r.id + '  -  ' + r.title);
        console.log(line);
        for (const s of (r.stats || [])) console.log('      ' + s);
        if (r.allowed.length > 0) {
            console.log('      ' + r.allowed.length + ' known exception(s) allowlisted:');
            for (const a of r.allowed) console.log('        - ' + a.key);
        }
        if (r.violations.length === 0) continue;
        console.log('');
        console.log('      ' + r.violations.length + ' VIOLATION(S):');
        for (const v of r.violations) {
            console.log('');
            console.log('      * ' + v.what);
            for (const w of (Array.isArray(v.where) ? v.where : [v.where])) {
                console.log('          at ' + w);
            }
            console.log('          allowlist key: ' + v.key);
        }
    }

    const stale = allow.stale();
    if (stale.length > 0 && !opts.filtered) {
        console.log('');
        console.log(line);
        console.log('NOTE  ' + stale.length + ' allowlist entr(ies) matched nothing this run.');
        console.log(line);
        console.log('      A stale exception reads like coverage and grants none. Delete it,');
        console.log('      or find out why the thing it excused stopped being reported.');
        for (const s of stale) console.log('        - ' + s.check + ' / ' + s.key);
    }

    console.log('');
    console.log('='.repeat(76));
    console.log('RESULT: ' + (results.length - failed) + ' passed, ' + failed + ' failed, of '
        + results.length + ' invariant(s)');
    console.log('='.repeat(76));
    return failed;
}

// ---------------------------------------------------------------------------
function runAll(root, filter) {
    const checks = loadChecks().filter((c) => !filter || c.id.indexOf(filter) !== -1);
    if (checks.length === 0) {
        console.error('no check matched "' + filter + '". --list shows the ids.');
        process.exit(2);
    }
    const allow = loadAllowlist(new Set(loadChecks().map((c) => c.id)));
    if (allow.problems.length > 0) {
        console.error('');
        console.error('ALLOWLIST IS INVALID - refusing to run:');
        for (const p of allow.problems) console.error('  ' + p);
        process.exit(2);
    }

    const repo = loadRepo(root);
    console.log('palm6 repo invariant checker');
    console.log('root: ' + root);
    console.log('scanned: ' + repo.resources.size + ' resources, ' + repo.luaFiles.length
        + ' Lua files, ' + repo.sqlFiles.length + ' sql/ files');

    const results = [];
    for (const c of checks) {
        let raw;
        try {
            raw = c.run(repo, allow);
        } catch (e) {
            // A check that throws has NOT passed. Reporting it as one failure
            // with the stack is the whole point; a runner that exits 0 on a
            // crashed check is worse than no runner.
            results.push({
                id: c.id, title: c.title, stats: [], allowed: [],
                violations: [{ key: 'check-crashed', what: 'the check itself threw: ' + e.message, where: [String(e.stack).split('\n')[1] || ''] }],
            });
            continue;
        }
        const allowed = [];
        const violations = [];
        for (const v of raw.violations) {
            const e = allow.find(c.id, v.key);
            if (e) allowed.push({ key: v.key, reason: e.reason });
            else violations.push(v);
        }
        results.push({ id: c.id, title: c.title, stats: raw.stats, allowed, violations });
    }

    return report(results, allow, { filtered: Boolean(filter) });
}

function main() {
    const argv = process.argv.slice(2);
    let root = path.resolve(__dirname, '..', '..');
    let filter = null;
    for (let i = 0; i < argv.length; i++) {
        if (argv[i] === '--list') {
            for (const c of loadChecks()) {
                console.log(c.id.padEnd(14) + c.title);
                console.log('  protects: ' + c.protects);
                console.log('  allowlist key format: ' + c.keyFormat);
                console.log('');
            }
            return;
        }
        if (argv[i] === '--root') { root = path.resolve(argv[++i]); continue; }
        if (argv[i] === '--self-test') { require('./selftest').main(); return; }
        if (argv[i].startsWith('--')) { console.error('unknown option ' + argv[i]); process.exit(2); }
        filter = argv[i];
    }
    process.exit(runAll(root, filter) > 0 ? 1 : 0);
}

if (require.main === module) main();
module.exports = { runAll, loadChecks };
