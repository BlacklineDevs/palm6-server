// ============================================================================
// tools/audit/selftest.js - proof that every check can FAIL.
//
// A gate that cannot fail is worse than no gate: it converts "nobody looked"
// into "it passed". So this builds TWO synthetic repos in a temp directory and
// runs every check against both:
//
//   CLEAN  - a small, correct server layout. Every check must report ZERO
//            violations. This half proves the checks are not simply always
//            angry, which would make the failing half meaningless.
//   BROKEN - the same layout with one deliberate violation planted per check.
//            Every check must report its planted key. This half proves each
//            check actually detects the thing it claims to.
//
// Run: node tools/audit/run.js --self-test
// ============================================================================
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { loadRepo } = require('./lib/repo');

function write(root, rel, body) {
    const full = path.join(root, rel);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, body, 'utf8');
}

const MANIFEST = (opts) => `fx_version 'cerulean'
game 'gta5'
${opts.shared ? `shared_scripts { ${opts.shared.map((s) => `'${s}'`).join(', ')} }\n` : ''}${opts.server ? `server_scripts { '@oxmysql/lib/MySQL.lua', ${opts.server.map((s) => `'${s}'`).join(', ')} }\n` : ''}${opts.client ? `client_scripts { ${opts.client.map((s) => `'${s}'`).join(', ')} }\n` : ''}`;

// ---------------------------------------------------------------------------
// The CLEAN tree. Everything here is deliberately consistent.
// ---------------------------------------------------------------------------
function buildClean(root) {
    const R = 'resources/[custom]/';

    write(root, 'custom.cfg', [
        '# synthetic fixture',
        'ensure palm6_eventguard',
        'ensure palm6_dbmigrate',
        'ensure palm6_alpha',
        'ensure palm6_beta',
        '',
        'add_ace group.admin command.alphaonly allow',
    ].join('\n') + '\n');

    write(root, 'sql/0001_init.sql', [
        '-- base',
        'CREATE TABLE IF NOT EXISTS `palm6_alpha_state` (',
        '    id INT PRIMARY KEY',
        ') ENGINE=InnoDB;',
    ].join('\n') + '\n');

    // ---- palm6_eventguard ------------------------------------------------
    write(root, R + 'palm6_eventguard/fxmanifest.lua', MANIFEST({ shared: ['config.lua'], server: ['server/main.lua'] }));
    write(root, R + 'palm6_eventguard/config.lua', [
        'Config = {}',
        'Config.Events = {',
        "    ['palm6_alpha:doThing'] = { calls = 5, window_seconds = 60 },",
        '}',
    ].join('\n') + '\n');
    // The real palm6_eventguard registers its guards by looping over
    // Config.Events, which is a DYNAMIC registration site and is declared as
    // such in allowlist.js. The fixture registers literally instead, so that
    // the clean tree contains no dynamic site at all and the "a new dynamic
    // site fails the check" plant below is testing only itself.
    write(root, R + 'palm6_eventguard/server/main.lua', [
        "AddEventHandler('palm6_alpha:doThing', function() end)",
    ].join('\n') + '\n');

    // ---- palm6_dbmigrate --------------------------------------------------
    write(root, R + 'palm6_dbmigrate/fxmanifest.lua', MANIFEST({ server: ['server.lua'] }));
    write(root, R + 'palm6_dbmigrate/server.lua', [
        'local STATEMENTS = {',
        "    { name = '0001 palm6_alpha_state', sql = [[",
        'CREATE TABLE IF NOT EXISTS `palm6_alpha_state` (',
        '    id INT PRIMARY KEY',
        ') ENGINE=InnoDB]] },',
        '}',
        'return STATEMENTS',
    ].join('\n') + '\n');

    // ---- palm6_alpha ------------------------------------------------------
    write(root, R + 'palm6_alpha/fxmanifest.lua', MANIFEST({ server: ['server/main.lua'], client: ['client/main.lua'] }));
    write(root, R + 'palm6_alpha/server/main.lua', [
        "RegisterNetEvent('palm6_alpha:doThing', function()",
        "    MySQL.query.await('SELECT id FROM palm6_alpha_state')",
        'end)',
        '',
        'local function flush(inline)',
        '    if inline then',
        "        MySQL.query('UPDATE palm6_alpha_state SET id = 1')",
        '    else',
        "        MySQL.query.await('UPDATE palm6_alpha_state SET id = 1')",
        '    end',
        'end',
        '',
        "AddEventHandler('onResourceStop', function(res)",
        '    if res ~= GetCurrentResourceName() then return end',
        '    flushInline()',
        'end)',
        '',
        'function flushInline()',
        '    print(1)',
        'end',
        '',
        "RegisterCommand('alphaonly', function(src) print(src) end, true)",
        '',
        "exports('AlphaSummary', function() return {} end)",
        '',
        'local ok = pcall(function() return exports.palm6_beta:BetaSummary() end)',
        'print(ok, flush)',
    ].join('\n') + '\n');
    write(root, R + 'palm6_alpha/client/main.lua', [
        "TriggerServerEvent('palm6_alpha:doThing')",
    ].join('\n') + '\n');

    // ---- palm6_beta -------------------------------------------------------
    write(root, R + 'palm6_beta/fxmanifest.lua', MANIFEST({ server: ['server/main.lua'] }));
    write(root, R + 'palm6_beta/server/main.lua', [
        "exports('BetaSummary', function() return {} end)",
        'local ok = pcall(function() return exports.palm6_alpha:AlphaSummary() end)',
        'print(ok)',
    ].join('\n') + '\n');
}

// ---------------------------------------------------------------------------
// The BROKEN tree: clean, plus exactly one planted violation per check.
// Each plant records the allowlist key the check is expected to emit.
// ---------------------------------------------------------------------------
const PLANTS = [
    {
        check: 'tables',
        key: 'palm6_ghost',
        note: 'a query against a table nothing creates',
        apply(root) {
            const p = 'resources/[custom]/palm6_alpha/server/main.lua';
            fs.appendFileSync(path.join(root, p),
                "\nlocal r = MySQL.query.await('SELECT * FROM palm6_ghost WHERE id = ?', { 1 })\nprint(r)\n");
        },
    },
    {
        check: 'exports',
        key: 'palm6_beta:NoSuchExport <- resources/[custom]/palm6_alpha/server/main.lua',
        note: 'a call to an export the target resource does not register',
        apply(root) {
            fs.appendFileSync(path.join(root, 'resources/[custom]/palm6_alpha/server/main.lua'),
                '\nlocal ok2 = pcall(function() return exports.palm6_beta:NoSuchExport() end)\nprint(ok2)\n');
        },
    },
    {
        check: 'exports',
        key: 'realm:palm6_beta:BetaSummary <- resources/[custom]/palm6_alpha/client/main.lua',
        note: 'a client script calling an export that only exists on the server realm',
        apply(root) {
            fs.appendFileSync(path.join(root, 'resources/[custom]/palm6_alpha/client/main.lua'),
                '\nlocal ok3 = pcall(function() return exports.palm6_beta:BetaSummary() end)\nprint(ok3)\n');
        },
    },
    {
        check: 'events',
        key: 'raised-unhandled:palm6_alpha:shoutIntoTheVoid',
        note: 'an event raised with no handler anywhere',
        apply(root) {
            fs.appendFileSync(path.join(root, 'resources/[custom]/palm6_alpha/client/main.lua'),
                "\nTriggerServerEvent('palm6_alpha:shoutIntoTheVoid')\n");
        },
    },
    {
        check: 'events',
        key: 'registered-unraised:palm6_beta:deadHandler',
        note: 'a handler nothing raises',
        apply(root) {
            fs.appendFileSync(path.join(root, 'resources/[custom]/palm6_beta/server/main.lua'),
                "\nRegisterNetEvent('palm6_beta:deadHandler', function() end)\n");
        },
    },
    {
        check: 'events',
        key: 'dynamic:resources/[custom]/palm6_beta/server/main.lua',
        note: 'a NEW dynamic registration site that nobody declared in the allowlist',
        apply(root) {
            fs.appendFileSync(path.join(root, 'resources/[custom]/palm6_beta/server/main.lua'),
                '\nlocal nm = SomeConfig.name\nAddEventHandler(nm, function() end)\n');
        },
    },
    {
        check: 'events',
        key: 'raised-unhandled:palm6_alpha:ternaryB',
        note: 'the SECOND branch of a ternary raise - the branch a literal-string grep misses',
        apply(root) {
            fs.appendFileSync(path.join(root, 'resources/[custom]/palm6_alpha/client/main.lua'),
                "\nlocal yes = true\nTriggerServerEvent(yes and 'palm6_alpha:doThing' or 'palm6_alpha:ternaryB')\n");
        },
    },
    {
        check: 'stop-await',
        key: 'palm6_beta::(inline)',
        note: 'a MySQL .await written directly inside an onResourceStop handler',
        apply(root) {
            fs.appendFileSync(path.join(root, 'resources/[custom]/palm6_beta/server/main.lua'), [
                '',
                "AddEventHandler('onResourceStop', function(res)",
                '    if res ~= GetCurrentResourceName() then return end',
                "    MySQL.update.await('UPDATE palm6_alpha_state SET id = 2')",
                'end)',
            ].join('\n') + '\n');
        },
    },
    {
        check: 'stop-await',
        key: 'palm6_alpha::flushInline->flush',
        note: 'a MySQL .await reached INDIRECTLY, one call hop from the stop handler',
        apply(root) {
            const p = path.join(root, 'resources/[custom]/palm6_alpha/server/main.lua');
            fs.writeFileSync(p, fs.readFileSync(p, 'utf8')
                .replace('function flushInline()\n    print(1)\nend', 'function flushInline()\n    flush(false)\nend'), 'utf8');
        },
    },
    {
        check: 'command-aces',
        key: 'restricted-without-ace:betaonly',
        note: 'a RegisterCommand(..., true) with no add_ace line',
        apply(root) {
            fs.appendFileSync(path.join(root, 'resources/[custom]/palm6_beta/server/main.lua'),
                "\nRegisterCommand('betaonly', function(src) for _, v in pairs({}) do print(v) end end, true)\n");
        },
    },
    {
        check: 'command-aces',
        key: 'ace-without-command:phantom',
        note: 'an add_ace for a command nothing registers',
        apply(root) {
            fs.appendFileSync(path.join(root, 'custom.cfg'), 'add_ace group.admin command.phantom allow\n');
        },
    },
    {
        check: 'eventguard',
        key: 'palm6_beta:notANetEvent',
        note: 'a budget for a name no resource opens to the network',
        apply(root) {
            const p = path.join(root, 'resources/[custom]/palm6_eventguard/config.lua');
            fs.writeFileSync(p, fs.readFileSync(p, 'utf8')
                .replace('}\n', "    ['palm6_beta:notANetEvent'] = { calls = 1, window_seconds = 1 },\n}\n"), 'utf8');
        },
    },
    {
        check: 'eventguard',
        key: 'order:palm6_alpha',
        note: 'a guarded resource ensured BEFORE palm6_eventguard, which makes its budgets no-ops',
        apply(root) {
            const p = path.join(root, 'custom.cfg');
            fs.writeFileSync(p, fs.readFileSync(p, 'utf8')
                .replace('ensure palm6_eventguard', 'ensure palm6_alpha\nensure palm6_eventguard'), 'utf8');
        },
    },
    {
        check: 'ensure-list',
        key: 'palm6_gamma',
        note: 'a resource directory nobody ensures',
        apply(root) {
            write(root, 'resources/[custom]/palm6_gamma/fxmanifest.lua', MANIFEST({ server: ['server/main.lua'] }));
            write(root, 'resources/[custom]/palm6_gamma/server/main.lua', 'print(1)\n');
        },
    },
    {
        check: 'ensure-list',
        key: 'ensure-missing:palm6_deleted',
        note: 'an ensure for a directory that does not exist',
        apply(root) {
            fs.appendFileSync(path.join(root, 'custom.cfg'), 'ensure palm6_deleted\n');
        },
    },
    {
        check: 'migrations',
        key: 'duplicate:0001',
        note: 'two sql/ files claiming one migration number',
        apply(root) {
            write(root, 'sql/0001_again.sql', 'CREATE TABLE IF NOT EXISTS `palm6_dup` (id INT);\n');
        },
    },
    {
        check: 'migrations',
        key: 'dbmigrate-only:0003',
        note: 'a migration number that exists ONLY in palm6_dbmigrate, the trap sql/ cannot show you',
        apply(root) {
            const p = path.join(root, 'resources/[custom]/palm6_dbmigrate/server.lua');
            fs.writeFileSync(p, fs.readFileSync(p, 'utf8').replace('}\nreturn STATEMENTS', [
                "    { name = '0003 palm6_alpha_extra', sql = [[",
                'CREATE TABLE IF NOT EXISTS `palm6_alpha_extra` (id INT)]] },',
                '}',
                'return STATEMENTS',
            ].join('\n')), 'utf8');
        },
    },
    {
        check: 'migrations',
        key: 'gap:0002',
        note: 'a migration number claimed by neither authority',
        apply(root) { /* created as a side effect of the 0003 plant above */ },
    },
    {
        check: 'migrations',
        key: 'divergent:0001:palm6_alpha_state',
        note: "a palm6_dbmigrate CREATE that has drifted from its sql/ original - invisible on the live box",
        apply(root) {
            const p = path.join(root, 'resources/[custom]/palm6_dbmigrate/server.lua');
            fs.writeFileSync(p, fs.readFileSync(p, 'utf8')
                .replace('CREATE TABLE IF NOT EXISTS `palm6_alpha_state` (\n    id INT PRIMARY KEY\n) ENGINE=InnoDB]]',
                    'CREATE TABLE IF NOT EXISTS `palm6_alpha_state` (\n    id BIGINT PRIMARY KEY\n) ENGINE=InnoDB]]'), 'utf8');
        },
    },
];

// An allowlist stub that excuses nothing: the synthetic trees must stand or
// fall on the checks alone.
const NO_ALLOW = { find() { return null; }, stale() { return []; } };

function runChecks(root) {
    const checks = require('./lib/checks').loadChecks();
    const repo = loadRepo(root);
    const out = new Map();
    for (const c of checks) out.set(c.id, c.run(repo, NO_ALLOW));
    return out;
}

function main() {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'palm6-audit-selftest-'));
    const clean = path.join(tmp, 'clean');
    const broken = path.join(tmp, 'broken');
    buildClean(clean);
    buildClean(broken);
    for (const p of PLANTS) p.apply(broken);

    console.log('palm6 audit self-test');
    console.log('fixtures: ' + tmp);
    console.log('');

    let failures = 0;

    // ---- half 1: the clean tree must be silent -----------------------------
    console.log('CLEAN fixture - every check must report zero violations');
    const cleanRes = runChecks(clean);
    for (const [id, r] of cleanRes) {
        const ok = r.violations.length === 0;
        if (!ok) failures++;
        console.log('  ' + (ok ? 'ok  ' : 'BAD ') + id
            + (ok ? '' : '  -> ' + r.violations.map((v) => v.key).join(', ')));
    }

    // ---- half 2: every plant must be caught ---------------------------------
    console.log('');
    console.log('BROKEN fixture - every planted violation must be reported');
    const brokenRes = runChecks(broken);
    for (const p of PLANTS) {
        const r = brokenRes.get(p.check);
        const found = r && r.violations.some((v) => v.key === p.key);
        if (!found) failures++;
        console.log('  ' + (found ? 'ok  ' : 'BAD ') + p.check.padEnd(13) + p.note);
        if (!found) {
            console.log('        expected key: ' + p.key);
            console.log('        reported:     ' + (r ? r.violations.map((v) => v.key).join(' | ') : '(check did not run)'));
        }
    }

    console.log('');
    console.log('='.repeat(76));
    if (failures === 0) {
        console.log('SELF-TEST PASSED: ' + PLANTS.length + ' planted violations, all detected; '
            + cleanRes.size + ' checks silent on a correct tree.');
    } else {
        console.log('SELF-TEST FAILED: ' + failures + ' problem(s). The checker cannot be trusted until this passes.');
    }
    console.log('='.repeat(76));
    process.exit(failures === 0 ? 0 : 1);
}

module.exports = { main };
