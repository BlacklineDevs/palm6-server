// ============================================================================
// tools/audit/lib/calls.js - reading arguments off a call site.
//
// The scanner blanks string literals out of the code stream, so a check cannot
// just regex the argument out of the raw text. These helpers pair a call's
// paren span (measured on the blanked stream, where parens inside strings no
// longer exist to confuse the balance) with the literal records the scanner
// kept, and hand back the literals that fall inside a given argument.
//
// firstArgLiterals returns a LIST, not a single value, and that is the point.
// This codebase raises at least one event name through a ternary:
//
//   TriggerServerEvent(ok and 'palm6_fc_combat:accept'
//                         or 'palm6_fc_combat:decline')
//     -- palm6_fc_combat/client/main.lua
//
// A "first literal wins" reader sees only :accept and reports :decline as an
// event nobody raises. Returning every literal in the first argument gets both,
// with no special case for ternaries, and the same code also covers
//   RegisterCommand(Config.Interior.CaptureCommand or 'bizshell', ...)
// which is the same shape wearing different clothes.
// ============================================================================
'use strict';

/**
 * End index (exclusive) of the call whose '(' is at openIdx.
 * @param {string} code blanked code stream
 * @param {number} openIdx index of the '('
 */
function callEnd(code, openIdx) {
    let i = openIdx;
    let depth = 0;
    do {
        const c = code[i];
        if (c === '(') depth++;
        else if (c === ')') depth--;
        i++;
    } while (i < code.length && depth > 0);
    return i;
}

/**
 * Every string literal inside the FIRST argument of the call at openIdx.
 * @param {object} file
 * @param {number} openIdx index of the '('
 * @returns {Array<{value: string, line: number, start: number, end: number}>}
 */
function firstArgLiterals(file, openIdx) {
    const code = file.code;
    let i = openIdx;
    let depth = 0;
    let comma = -1;
    do {
        const c = code[i];
        if (c === '(' || c === '{' || c === '[') depth++;
        else if (c === ')' || c === '}' || c === ']') depth--;
        else if (c === ',' && depth === 1 && comma === -1) comma = i;
        i++;
    } while (i < code.length && depth > 0);
    const end = comma === -1 ? i : comma;
    return file.strings.filter((s) => s.start > openIdx && s.end <= end);
}

/**
 * The Nth (0-based) argument's raw text, with strings still blanked.
 * @param {object} file
 * @param {number} openIdx
 * @param {number} n
 * @returns {string|null}
 */
function argText(file, openIdx, n) {
    const code = file.code;
    const parts = [];
    let i = openIdx;
    let depth = 0;
    let start = openIdx + 1;
    do {
        const c = code[i];
        if (c === '(' || c === '{' || c === '[') depth++;
        else if (c === ')' || c === '}' || c === ']') {
            depth--;
            if (depth === 0) { parts.push(code.slice(start, i)); break; }
        } else if (c === ',' && depth === 1) { parts.push(code.slice(start, i)); start = i + 1; }
        i++;
    } while (i < code.length);
    return parts[n] === undefined ? null : parts[n];
}

/**
 * Text of the LAST argument of the call at openIdx, strings still blanked.
 *
 * Splitting a Lua call on top-level commas and indexing does NOT work for
 * `RegisterCommand('x', function(...) ... end, true)`: a `for k, v in ...` in
 * the handler body sits at the same paren depth as the argument separators, so
 * "argument 2" lands in the middle of the function. Taking the text after the
 * LAST depth-1 comma is immune to that, and the restricted flag is always the
 * last argument when it is present at all.
 * @param {object} file
 * @param {number} openIdx
 * @returns {string}
 */
function lastArgText(file, openIdx) {
    const code = file.code;
    let i = openIdx;
    let depth = 0;
    let lastComma = -1;
    let close = -1;
    do {
        const c = code[i];
        if (c === '(' || c === '{' || c === '[') depth++;
        else if (c === ')' || c === '}' || c === ']') {
            depth--;
            if (depth === 0) { close = i; break; }
        } else if (c === ',' && depth === 1) lastComma = i;
        i++;
    } while (i < code.length);
    if (close === -1) return '';
    return code.slice(lastComma === -1 ? openIdx + 1 : lastComma + 1, close);
}

module.exports = { callEnd, firstArgLiterals, argText, lastArgText };
