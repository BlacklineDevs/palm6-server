/* palm6_mapeditor prop catalog — NUI logic (vanilla, no build step).
 *
 * The client (client/nui.lua) drives everything via SendNUIMessage:
 *   {action:'open', groups:[{category, models:[...]}, ...]}   -> show + render
 *   {action:'close'}                                          -> hide
 * Clicking a prop POSTs to the spawnProp callback; the client spawns it into
 * the editor at the player's aim and closes the browser so they can position it.
 *
 * Thumbnails come straight from RAGE's public object database (the same source
 * the odb website uses). The image filename is "<name>-<joaat(name)>.jpg", and
 * the model hash IS joaat(name), so we compute it here — nothing is bundled.
 */
'use strict';

var RES = 'palm6_mapeditor';
var THUMB_BASE = 'https://cdn.rage.mp/public/odb/imgs-small/';
var SEARCH_CAP = 400;   // most props any single search renders at once

var groups = [];        // [{category, models:[...]}]
var allModels = [];     // flat list of raw model names
var searchIndex = [];   // [[normalizedName, rawName], ...] — normalized = lowercase, alnum-only
var activeCat = -1;     // >=0 while browsing a category, -1 while searching
var lastCat = -1;       // last browsed category, restored when the search clears
var modelCat = {};      // model -> category name (shown in the card description)
var imgOk = 0, imgFail = 0;   // thumbnail load tally (diagnostic; shown in footer)

// Normalize a name/query for matching: lowercase, strip every non-alphanumeric.
// This makes "traffic light", "traffic_light" and "trafficlight" all match
// prop_traffic_light_01, and makes matching case-insensitive.
function norm(s) { return String(s || '').toLowerCase().replace(/[^a-z0-9]/g, ''); }

// A readable title from a model name: drop a common prefix, underscores->spaces,
// Title-Case. e.g. prop_barrel_02a -> "Barrel 02a".
function prettify(model) {
    var s = String(model).replace(/^(prop_|p_|v_|ba_|xm_|apa_|bkr_|ex_|gr_|h4_|imp_|mp_|sf_|sm_|vw_|w_)/i, '').replace(/_/g, ' ').trim();
    s = s.replace(/\b\w/g, function (c) { return c.toUpperCase(); });
    return s || model;
}

function updateThumbStat() {
    if (el.thumbstat) el.thumbstat.textContent = 'thumbnails: ' + imgOk + ' loaded · ' + imgFail + ' failed';
}

// Deterministic hue per category so a category reads as a cohesive colour set
// (its swatch, its props' fallback tiles and chips all share it).
function catHue(s) { return joaat(s || 'prop') % 360; }

// Fuzzy match score of a normalized name against a normalized query, or -1.
// Substring hits rank highest (earlier = better); otherwise a subsequence match
// (all query chars in order) still qualifies, so "brl" -> barrel, "traflt" ->
// traffic_light. Mirrors the ox_lib browser's scoring.
function fuzzyScore(name, q) {
    var idx = name.indexOf(q);
    if (idx !== -1) return 1000 - idx;
    var qi = 0, pos = 0;
    for (var i = 0; i < name.length && qi < q.length; i++) {
        if (name.charCodeAt(i) === q.charCodeAt(qi)) { qi++; pos += i; }
    }
    if (qi === q.length) return 100 - pos / (name.length || 1);
    return -1;
}

// Two-letter monospace mark for the generative fallback, from the readable name.
function initials(model) {
    var parts = prettify(model).split(/\s+/).filter(Boolean);
    var s = (parts[0] ? parts[0][0] : '') + (parts[1] ? parts[1][0] : (parts[0] && parts[0][1] ? parts[0][1] : ''));
    return (s || '?').toUpperCase().slice(0, 2);
}

// GTA one-at-a-time (Jenkins) hash of the lowercased name = the model hash the
// odb filenames use. Verified against known props (prop_roadcone02a=3258159972).
function joaat(key) {
    key = String(key).toLowerCase();
    var h = 0;
    for (var i = 0; i < key.length; i++) {
        h = (h + key.charCodeAt(i)) >>> 0;
        h = (h + (h << 10)) >>> 0;
        h = (h ^ (h >>> 6)) >>> 0;
    }
    h = (h + (h << 3)) >>> 0;
    h = (h ^ (h >>> 11)) >>> 0;
    h = (h + (h << 15)) >>> 0;
    return h >>> 0;
}
// odb filenames are lowercase; joaat already lowercases, so lowercase the name
// too or a mixed-case archetype would request a wrong-case file and 404.
function thumbUrl(model) { return THUMB_BASE + String(model).toLowerCase() + '-' + joaat(model) + '.jpg'; }

var el = {
    app: document.getElementById('app'),
    cats: document.getElementById('cats'),
    grid: document.getElementById('grid'),
    search: document.getElementById('search'),
    clear: document.getElementById('clear'),
    close: document.getElementById('close'),
    count: document.getElementById('count'),
    ctx: document.getElementById('ctx'),
    thumbstat: document.getElementById('thumbstat'),
};

function post(cb, body) {
    return fetch('https://' + RES + '/' + cb, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(body || {}),
    }).catch(function () { /* dev / browser-preview: no NUI host, ignore */ });
}

// One prop card: a thumbnail (shimmer -> odb image, or a generative category-hued
// schematic swatch when the odb has no preview) + title + monospace model id +
// category chip. onload/onerror update the footer tally so a mass load failure
// (e.g. the game blocking the CDN) is visible, not silent.
function makeCard(model) {
    var cat = modelCat[model] || '';
    var card = document.createElement('div');
    card.className = 'card';
    card.setAttribute('role', 'button');
    card.tabIndex = 0;
    card.title = model;
    card.style.setProperty('--h', catHue(cat));

    var thumb = document.createElement('div');
    thumb.className = 'thumb loading';
    thumb.setAttribute('data-glyph', initials(model));
    var img = document.createElement('img');
    img.alt = '';
    img.onload = function () { imgOk++; updateThumbStat(); thumb.classList.remove('loading'); };
    img.onerror = function () {
        imgFail++; updateThumbStat();
        thumb.classList.remove('loading'); thumb.classList.add('fallback'); img.remove();
    };
    img.src = thumbUrl(model);
    thumb.appendChild(img);

    var hint = document.createElement('div');
    hint.className = 'spawn-hint';
    hint.textContent = 'SPAWN';
    thumb.appendChild(hint);

    var meta = document.createElement('div');
    meta.className = 'meta';
    var title = document.createElement('div');
    title.className = 'title';
    title.textContent = prettify(model);
    var sub = document.createElement('div');
    sub.className = 'sub';
    var mid = document.createElement('div');
    mid.className = 'mid';
    mid.textContent = model;
    sub.appendChild(mid);
    if (cat) {
        var chip = document.createElement('span');
        chip.className = 'chip';
        chip.textContent = cat;
        sub.appendChild(chip);
    }
    meta.appendChild(title);
    meta.appendChild(sub);

    card.appendChild(thumb);
    card.appendChild(meta);
    card.addEventListener('click', function () { spawn(model); });
    card.addEventListener('keydown', function (ev) {
        if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); spawn(model); }
    });
    return card;
}

// capped=true only for search (bounds huge result sets). Category browsing
// renders the whole category. Thumbnails load eagerly; the browser throttles the
// request queue, and off-screen images are cheap (~4KB each).
function renderGrid(models, ctxLabel, capped) {
    el.grid.scrollTop = 0;
    el.grid.textContent = '';
    imgOk = 0; imgFail = 0; updateThumbStat();
    if (!models || models.length === 0) {
        var e = document.createElement('div');
        e.className = 'empty';
        var big = document.createElement('span');
        big.className = 'big';
        big.textContent = 'Nothing here';
        e.appendChild(big);
        e.appendChild(document.createTextNode('Pick another category or try a different search.'));
        el.grid.appendChild(e);
        el.ctx.textContent = ctxLabel || '';
        return;
    }
    var frag = document.createDocumentFragment();
    var n = capped ? Math.min(models.length, SEARCH_CAP) : models.length;
    for (var i = 0; i < n; i++) frag.appendChild(makeCard(models[i]));
    el.grid.appendChild(frag);
    if (capped && models.length > n) {
        var more = document.createElement('div');
        more.className = 'empty';
        more.textContent = '+ ' + (models.length - n) + ' more · refine your search';
        el.grid.appendChild(more);
    }
    el.ctx.textContent = ctxLabel || '';
}

function renderCats() {
    el.cats.textContent = '';
    groups.forEach(function (g, i) {
        if (!g) return;
        var row = document.createElement('div');
        row.className = 'cat' + (i === activeCat ? ' active' : '');
        var sw = document.createElement('span');
        sw.className = 'swatch';
        sw.style.background = 'hsl(' + catHue(g.category) + ', 55%, 56%)';
        var label = document.createElement('span');
        label.className = 'c-name';
        label.textContent = g.category || '(unnamed)';
        var n = document.createElement('span');
        n.className = 'n';
        n.textContent = (g.models || []).length;
        row.appendChild(sw);
        row.appendChild(label);
        row.appendChild(n);
        // Clicking a category is an explicit action: clear any search text first.
        row.addEventListener('click', function () {
            el.search.value = ''; el.clear.style.display = 'none'; selectCat(i);
        });
        el.cats.appendChild(row);
    });
}

// Pure state + render; does NOT touch the search input (so the search-cleared
// restore path can reuse it without wiping what the user is typing).
function selectCat(i) {
    activeCat = i; lastCat = i;
    renderCats();
    var g = groups[i];
    renderGrid(g ? g.models : [], (g ? g.category : ''), false);
}

function runSearch(rawInput) {
    var raw = String(rawInput || '');
    el.clear.style.display = raw ? 'block' : 'none';
    var q = norm(raw);
    if (q.length < 2) {
        // Not a search (empty/cleared/too short): restore the last browsed
        // category. Never leaves stale search results on screen, and never
        // touches the input, so a single typed char isn't wiped mid-type.
        var ci = lastCat >= 0 ? lastCat : (groups.length ? 0 : -1);
        activeCat = ci;
        renderCats();
        var gc = groups[ci];
        renderGrid(gc ? gc.models : [], gc ? gc.category : '', false);
        return;
    }
    activeCat = -1;
    renderCats();
    var hits = [];
    for (var i = 0; i < searchIndex.length; i++) {
        var sc = fuzzyScore(searchIndex[i][0], q);
        if (sc >= 0) hits.push([sc, searchIndex[i][1]]);
    }
    // Higher score first; tie-break alphabetically for stable ordering.
    hits.sort(function (a, b) { return b[0] - a[0] || (a[1] < b[1] ? -1 : 1); });
    renderGrid(hits.map(function (h) { return h[1]; }), hits.length + ' match(es) for "' + q + '"', true);
}

function spawn(model) {
    if (!/^[A-Za-z0-9_]+$/.test(model)) return;
    hide();                       // snappy: hide immediately, client releases focus
    post('spawnProp', { model: model });
}

function show(g) {
    groups = Array.isArray(g) ? g : [];
    allModels = []; searchIndex = []; modelCat = {};
    groups.forEach(function (grp) {
        if (!grp || !Array.isArray(grp.models)) return;
        grp.models.forEach(function (m) {
            if (typeof m !== 'string') return;
            allModels.push(m);
            searchIndex.push([norm(m), m]);
            if (grp.category && !modelCat[m]) modelCat[m] = grp.category;
        });
    });
    el.count.textContent = allModels.length.toLocaleString();
    activeCat = groups.length ? 0 : -1;
    lastCat = activeCat;
    el.search.value = '';
    el.clear.style.display = 'none';
    renderCats();
    var gg = groups[activeCat];
    renderGrid(gg ? gg.models : [], gg ? gg.category : '', false);
    el.app.classList.remove('hidden');
    el.app.setAttribute('aria-hidden', 'false');
    setTimeout(function () { el.search.focus(); }, 30);
}
function hide() { el.app.classList.add('hidden'); el.app.setAttribute('aria-hidden', 'true'); }

// --- events ---------------------------------------------------------------
var searchTimer = null;
el.search.addEventListener('input', function (e) {
    clearTimeout(searchTimer);
    var v = e.target.value;
    searchTimer = setTimeout(function () { runSearch(v); }, 110);
});
el.clear.addEventListener('click', function () { el.search.value = ''; runSearch(''); el.search.focus(); });
el.close.addEventListener('click', function () { hide(); post('close'); });

document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') { hide(); post('close'); }
});

window.addEventListener('message', function (e) {
    var d = e.data || {};
    if (d.action === 'open') show(d.groups);
    else if (d.action === 'close') hide();
});
