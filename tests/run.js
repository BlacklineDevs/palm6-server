#!/usr/bin/env node
// ============================================================================
// palm6 Lua unit test runner.
//
// WHY THIS EXISTS
// The server's money, sentence, heat and capture decisions are Lua. Until this
// directory existed the only automated checks were a parser (does it PARSE) and
// a jsdom suite for NUI JavaScript, so not one line of the Lua LOGIC was ever
// executed by anything except the live server. These suites run the real Lua
// through fengari, a Lua 5.3 VM in JavaScript, so an assertion here is a
// statement about the code that ships and not about a mental model of it.
//
// WHAT IT DOES NOT DO
// It does not emulate FiveM. There are no natives, no MySQL, no events and no
// Bridge. Only code that is pure (inputs in, value out) is testable this way,
// which is exactly the code that decides numbers. See README.md for the honest
// list of what could not be reached.
//
// Each suite file gets its OWN fresh Lua state, so a Config a suite mutates
// cannot leak into another suite.
// ============================================================================
'use strict';

const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring } = require('fengari');

const TESTS_DIR = __dirname;
const SUITES_DIR = path.join(TESTS_DIR, 'suites');
const REPO = path.resolve(TESTS_DIR, '..');

const totals = { passed: 0, failed: 0, suites: 0, brokenSuites: 0 };

// Lua cannot read files here: fengari does not ship the io library, so file
// access is handed in from JavaScript. Returns nil + message on failure so the
// harness can raise a readable error instead of a nil index.
function jsReadFile(L) {
    const p = lua.lua_tojsstring(L, 1);
    let s;
    try {
        s = fs.readFileSync(p, 'utf8');
    } catch (e) {
        lua.lua_pushnil(L);
        lua.lua_pushstring(L, to_luastring(String(e.message)));
        return 2;
    }
    lua.lua_pushstring(L, to_luastring(s));
    return 1;
}

// Called by the harness at the end of every suite so the per-state tallies can
// be summed across states.
function jsReport(L) {
    const passed = lauxlib.luaL_checkinteger(L, 2);
    const failed = lauxlib.luaL_checkinteger(L, 3);
    totals.passed += passed;
    totals.failed += failed;
    return 0;
}

function setGlobalString(L, name, value) {
    lua.lua_pushstring(L, to_luastring(value));
    lua.lua_setglobal(L, to_luastring(name));
}

function setGlobalFn(L, name, fn) {
    lua.lua_pushjsfunction(L, fn);
    lua.lua_setglobal(L, to_luastring(name));
}

// Load and run one Lua file in an existing state. Returns an error string, or
// null on success. Errors are never swallowed: they are surfaced to the caller
// which turns them into a loud suite-level failure.
function doFile(L, file) {
    const src = fs.readFileSync(file, 'utf8');
    if (lauxlib.luaL_loadbuffer(L, to_luastring(src), null, to_luastring('@' + file)) !== lua.LUA_OK) {
        const msg = lua.lua_tojsstring(L, -1);
        lua.lua_pop(L, 1);
        return 'load error: ' + msg;
    }
    if (lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) {
        const msg = lua.lua_tojsstring(L, -1);
        lua.lua_pop(L, 1);
        return 'runtime error: ' + msg;
    }
    return null;
}

function runSuite(file) {
    const L = lauxlib.luaL_newstate();
    lualib.luaL_openlibs(L);
    setGlobalString(L, 'REPO', REPO.replace(/\\/g, '/'));
    setGlobalString(L, 'SUITE_FILE', path.basename(file));
    setGlobalFn(L, '__readFile', jsReadFile);
    setGlobalFn(L, '__report', jsReport);

    const harnessErr = doFile(L, path.join(TESTS_DIR, 'lib', 'harness.lua'));
    if (harnessErr) {
        console.error('FATAL: harness.lua failed to load: ' + harnessErr);
        process.exit(2);
    }

    totals.suites += 1;
    const err = doFile(L, file);
    if (err) {
        // A suite that blows up mid-way has NOT passed. Counting it as one
        // failure and printing the Lua error is the whole point: a harness that
        // exits 0 on a crashed suite is worse than no harness.
        totals.failed += 1;
        totals.brokenSuites += 1;
        console.log('');
        console.log('  SUITE ABORTED: ' + path.basename(file));
        console.log('    ' + err);
    }
}

function main() {
    const filter = process.argv[2] || null;
    if (!fs.existsSync(SUITES_DIR)) {
        console.error('no suites directory at ' + SUITES_DIR);
        process.exit(2);
    }
    const files = fs.readdirSync(SUITES_DIR)
        .filter((f) => f.endsWith('.lua'))
        .filter((f) => !filter || f.indexOf(filter) !== -1)
        .sort();
    if (files.length === 0) {
        console.error('no suite files matched' + (filter ? ' filter "' + filter + '"' : ''));
        process.exit(2);
    }

    console.log('palm6 Lua unit tests (fengari, real Lua 5.3 execution)');
    console.log('repo: ' + REPO);
    for (const f of files) runSuite(path.join(SUITES_DIR, f));

    console.log('');
    console.log('============================================================');
    console.log('TOTAL: ' + (totals.passed + totals.failed) + ' assertions, '
        + totals.passed + ' passed, ' + totals.failed + ' failed, across '
        + totals.suites + ' suite(s)');
    if (totals.brokenSuites > 0) {
        console.log(totals.brokenSuites + ' suite(s) aborted before finishing.');
    }
    console.log('============================================================');
    process.exit(totals.failed > 0 ? 1 : 0);
}

main();
