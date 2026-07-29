// ============================================================================
// tools/audit/lib/luablocks.js - block matching and a per-resource call graph.
//
// One invariant needs more than pattern matching: "no MySQL .await is
// REACHABLE from an onResourceStop handler". Reachable, not "written inside".
// A handler that calls a local persist() which awaits is exactly as broken as
// one that awaits inline, and it is the shape you actually write.
//
// So this file does two things:
//   1. matchEnd(): find the `end` that closes a block, by counting Lua's
//      block openers on the COMMENT-AND-STRING-FREE code stream. Openers are
//      `function`, `if` and `do`; `for`/`while` are not counted because they
//      always carry their own `do`. `repeat`/`until` opens and closes nothing
//      that `end` participates in.
//   2. buildCallGraph(): per resource, per realm, map every named function to
//      the identifiers it calls, then answer "does X transitively reach a
//      MySQL .await".
//
// LIMITS, stated plainly because a check whose limits are hidden is a lie:
//   - resolution is by NAME within one resource and one realm. A call through
//     a table field held in a local variable is not followed.
//   - an anonymous function stored in a table and invoked later is not
//     followed.
//   Both of those make the check MISS things. Neither makes it invent things,
//   which is the direction that matters for a gate people are asked to trust.
// ============================================================================
'use strict';

const KEYWORD = /\b(function|if|do|end|repeat|until)\b/g;

/**
 * Index just past the `end` that closes the block opened at `openIdx`.
 * `openIdx` must point at the opening keyword itself.
 * @param {string} code comment-and-string-free Lua
 * @param {number} openIdx
 * @returns {number} index just past the closing `end`, or code.length
 */
function matchEnd(code, openIdx) {
    KEYWORD.lastIndex = openIdx;
    let depth = 0;
    let m;
    while ((m = KEYWORD.exec(code)) !== null) {
        const k = m[1];
        if (k === 'function' || k === 'if' || k === 'do') depth++;
        else if (k === 'end') {
            depth--;
            if (depth === 0) return m.index + 3;
        }
        // `repeat`/`until` pair with each other and never with `end`.
    }
    return code.length;
}

/**
 * Every named function definition in a file.
 * @param {{code: string, lineAt: (n:number)=>number, rel: string}} file
 * @returns {Array<{name: string, start: number, end: number, line: number}>}
 */
function functionDefs(file) {
    const out = [];
    const push = (name, kwIdx) => {
        const end = matchEnd(file.code, kwIdx);
        out.push({ name, start: kwIdx, end, line: file.lineAt(kwIdx) });
    };
    // function NAME(...) / function A.B(...) / function A:B(...)
    for (const m of file.code.matchAll(/\bfunction\s+([A-Za-z_][\w.:]*)\s*\(/g)) {
        push(m[1].replace(/:/g, '.'), m.index);
    }
    // local NAME = function(...)   and   A.B = function(...)
    for (const m of file.code.matchAll(/(?:local\s+)?([A-Za-z_][\w.]*)\s*=\s*function\s*\(/g)) {
        const kw = file.code.indexOf('function', m.index);
        push(m[1], kw);
    }
    return out;
}

/**
 * Identifiers called inside a code span. `a.b.c(` yields 'a.b.c' and 'c', so a
 * method stored under a table is still resolvable by its bare name.
 * @param {string} span
 * @returns {Set<string>}
 */
function calleesIn(span) {
    const out = new Set();
    for (const m of span.matchAll(/([A-Za-z_][\w.:]*)\s*\(/g)) {
        const full = m[1].replace(/:/g, '.');
        out.add(full);
        const last = full.split('.').pop();
        if (last) out.add(last);
    }
    return out;
}

/** Does this span contain a MySQL `.await` call? */
function hasAwait(span) {
    return /\.await\s*\(/.test(span);
}

/**
 * Build a name -> reachability answer for one resource realm.
 * @param {Array} files files of one resource in one realm
 * @returns {{reachesAwait: (names: Set<string>) => Array<{name: string, via: string[]}>,
 *            defs: Map<string, {file: object, def: object, direct: boolean}>}}
 */
function buildCallGraph(files) {
    const defs = new Map();          // name -> { file, def, direct, callees }
    for (const file of files) {
        for (const def of functionDefs(file)) {
            const span = file.code.slice(def.start, def.end);
            // A later definition of the same name shadows an earlier one for
            // reachability purposes only if it also awaits; keeping the
            // await-y one is the conservative choice for a safety check.
            const entry = {
                file, def,
                direct: hasAwait(span),
                callees: calleesIn(span),
            };
            const prev = defs.get(def.name);
            if (!prev || (entry.direct && !prev.direct)) defs.set(def.name, entry);
        }
    }

    // Memoised transitive search. Returns the chain of names that ends at a
    // direct await, or null.
    const memo = new Map();
    function chain(name, seen) {
        if (memo.has(name)) return memo.get(name);
        const e = defs.get(name);
        if (!e) return null;
        if (seen.has(name)) return null;
        seen.add(name);
        if (e.direct) { memo.set(name, [name]); return [name]; }
        for (const c of e.callees) {
            const sub = chain(c, seen);
            if (sub) { const r = [name].concat(sub); memo.set(name, r); return r; }
        }
        memo.set(name, null);
        return null;
    }

    return {
        defs,
        /** @param {Set<string>} names */
        reachesAwait(names) {
            const hits = [];
            for (const n of names) {
                const c = chain(n, new Set());
                if (c) hits.push({ name: n, via: c });
            }
            return hits;
        },
    };
}

module.exports = { matchEnd, functionDefs, calleesIn, hasAwait, buildCallGraph };
