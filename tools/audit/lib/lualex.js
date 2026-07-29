// ============================================================================
// tools/audit/lib/lualex.js - a minimal Lua scanner.
//
// WHY THIS EXISTS
// Every invariant in this directory is a question of the form "does the CODE
// do X". A plain regex over the raw bytes cannot answer that, because this
// repo's comments are unusually dense and unusually literal: custom.cfg and
// several config.lua files quote grep commands, event names and table names
// inside prose. A raw grep for `palm6_heat:AddHeat` matches the comment in
// custom.cfg that TELLS you to grep for it. That is not a hypothetical: that
// comment is at custom.cfg line 239 today.
//
// So before any check runs, a file is split into three streams:
//   - code:     everything that is not a comment and not a string literal
//   - strings:  the CONTENTS of string literals, with the line they start on
//   - comments: dropped entirely (never fed to a check)
//
// Checks that ask "is this name mentioned in SQL" read `strings`. Checks that
// ask "is this call made" read `code` plus the string arguments they resolve
// themselves. Nothing reads a comment.
//
// This is a scanner, not a parser. It knows string/comment/long-bracket
// syntax and nothing else. That is enough, and it cannot silently mis-handle
// a construct it does not know about, because everything it does not
// recognise falls through to `code` verbatim.
// ============================================================================
'use strict';

/**
 * Scan Lua source into a code stream and a list of string literals.
 *
 * The returned `code` is the same LENGTH as the input: comments and string
 * bodies are replaced with spaces (newlines preserved). That means a byte
 * offset into `code` is also a byte offset into the original file, so line
 * numbers computed from `code` are real file line numbers.
 *
 * @param {string} src raw file contents
 * @returns {{code: string, strings: Array<{value: string, line: number}>}}
 */
function scanLua(src) {
    const out = new Array(src.length).fill(' ');
    const strings = [];
    let i = 0;
    let line = 1;
    const n = src.length;

    // Keep newlines so line numbers survive into the code stream.
    const keepNewlines = (from, to) => {
        for (let k = from; k < to; k++) if (src[k] === '\n') out[k] = '\n';
    };

    // A STRING is blanked to NUL, not to spaces. That distinction matters:
    // spaces are whitespace, so a pattern like /name\s*=\s*/ would greedily
    // eat straight through a space-blanked string literal and land past the
    // very argument the caller was trying to read. That is not hypothetical -
    // it silently zeroed the migration check during development. NUL is not
    // whitespace, so a `\s*` stops dead at the edge of a literal.
    const blankString = (from, to) => {
        for (let k = from; k < to; k++) out[k] = (src[k] === '\n') ? '\n' : '\0';
    };

    // Long bracket: [[ ... ]] / [=[ ... ]=] / [==[ ... ]==]. Returns the index
    // just past the closer, or -1 when `at` is not the start of a long bracket.
    const longBracket = (at) => {
        if (src[at] !== '[') return -1;
        let j = at + 1;
        let eq = 0;
        while (src[j] === '=') { eq++; j++; }
        if (src[j] !== '[') return -1;
        const closer = ']' + '='.repeat(eq) + ']';
        const end = src.indexOf(closer, j + 1);
        if (end === -1) return n;            // unterminated: swallow the rest
        return end + closer.length;
    };

    while (i < n) {
        const c = src[i];

        if (c === '\n') { out[i] = '\n'; line++; i++; continue; }

        // Comment: -- line, or --[[ block.
        if (c === '-' && src[i + 1] === '-') {
            const lb = longBracket(i + 2);
            if (lb !== -1) {
                keepNewlines(i, lb);
                for (let k = i; k < lb; k++) if (src[k] === '\n') line++;
                i = lb;
                continue;
            }
            let j = i;
            while (j < n && src[j] !== '\n') j++;
            i = j;
            continue;
        }

        // Long string.
        if (c === '[') {
            const lb = longBracket(i);
            if (lb !== -1) {
                const startLine = line;
                // Body sits between the opener and the closer. Recovering the
                // exact opener length is not needed: strip the leading
                // [=*[ and trailing ]=*] by regex on the slice.
                const raw = src.slice(i, lb);
                const body = raw.replace(/^\[=*\[/, '').replace(/\]=*\]$/, '');
                strings.push({ value: body, line: startLine, start: i, end: lb, long: true });
                blankString(i, lb);
                for (let k = i; k < lb; k++) if (src[k] === '\n') line++;
                i = lb;
                continue;
            }
            out[i] = c; i++; continue;
        }

        // Quoted string.
        if (c === '"' || c === "'") {
            const quote = c;
            const startLine = line;
            let j = i + 1;
            let buf = '';
            while (j < n) {
                const d = src[j];
                if (d === '\\') {
                    // Only the escapes that can hide a quote matter here. The
                    // value is used for name matching, so \n vs literal n is
                    // not worth a full escape table; \\ and \" are.
                    const e = src[j + 1];
                    if (e === '\n') line++;
                    buf += (e === '\\' || e === '"' || e === "'") ? e : '';
                    j += 2;
                    continue;
                }
                if (d === quote) { j++; break; }
                if (d === '\n') { line++; break; }   // unterminated short string
                buf += d;
                j++;
            }
            strings.push({ value: buf, line: startLine, start: i, end: j, long: false });
            blankString(i, j);
            i = j;
            continue;
        }

        out[i] = c;
        i++;
    }

    return { code: out.join(''), strings };
}

/**
 * Strip `#` comments from a .cfg file, preserving length and newlines so byte
 * offsets stay usable as line numbers.
 * @param {string} src
 * @returns {string}
 */
function scanCfg(src) {
    return src.split('\n').map((l) => {
        const h = l.indexOf('#');
        if (h === -1) return l;
        return l.slice(0, h) + ' '.repeat(l.length - h);
    }).join('\n');
}

/**
 * Strip `--` line comments and block comments from SQL.
 * @param {string} src
 * @returns {string}
 */
function scanSql(src) {
    let s = src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '));
    s = s.split('\n').map((l) => {
        const h = l.indexOf('--');
        if (h === -1) return l;
        return l.slice(0, h) + ' '.repeat(l.length - h);
    }).join('\n');
    return s;
}

/**
 * Build a fast offset -> line lookup for a file scanned many times.
 * @param {string} src
 * @returns {(offset:number)=>number}
 */
function lineIndexer(src) {
    const starts = [0];
    for (let i = 0; i < src.length; i++) if (src[i] === '\n') starts.push(i + 1);
    return (offset) => {
        let lo = 0;
        let hi = starts.length - 1;
        while (lo < hi) {
            const mid = (lo + hi + 1) >> 1;
            if (starts[mid] <= offset) lo = mid; else hi = mid - 1;
        }
        return lo + 1;
    };
}

module.exports = { scanLua, scanCfg, scanSql, lineIndexer };
