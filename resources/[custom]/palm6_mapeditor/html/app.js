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

// Normalize a name/query for matching: lowercase, strip every non-alphanumeric.
// This makes "traffic light", "traffic_light" and "trafficlight" all match
// prop_traffic_light_01, and makes matching case-insensitive.
function norm(s) { return String(s || '').toLowerCase().replace(/[^a-z0-9]/g, ''); }

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
};

function post(cb, body) {
    return fetch('https://' + RES + '/' + cb, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(body || {}),
    }).catch(function () { /* dev / browser-preview: no NUI host, ignore */ });
}

// Build one prop card. loading="lazy" means the browser only fetches a thumbnail
// once the card scrolls into view, so a 500-prop category costs almost nothing.
function makeCard(model) {
    var card = document.createElement('div');
    card.className = 'card';
    card.title = model;

    var thumb = document.createElement('div');
    thumb.className = 'thumb';
    var img = document.createElement('img');
    img.loading = 'lazy';
    img.alt = '';
    img.src = thumbUrl(model);
    img.onerror = function () { thumb.classList.add('fallback'); img.remove(); };
    thumb.appendChild(img);

    var name = document.createElement('div');
    name.className = 'name';
    name.textContent = model;

    card.appendChild(thumb);
    card.appendChild(name);
    card.addEventListener('click', function () { spawn(model); });
    return card;
}

// capped=true only for search (bounds huge result sets). Category browsing
// passes capped=false and renders the whole category — loading="lazy" means
// off-screen thumbnails aren't fetched, so even a 600-prop category stays cheap
// and every prop is reachable by scrolling (not hidden behind "refine search").
function renderGrid(models, ctxLabel, capped) {
    el.grid.scrollTop = 0;
    el.grid.textContent = '';
    if (!models || models.length === 0) {
        var e = document.createElement('div');
        e.className = 'empty';
        e.textContent = 'no props here';
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
        more.textContent = '+ ' + (models.length - n) + ' more — refine your search';
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
        var label = document.createElement('span');
        label.textContent = g.category || '(unnamed)';
        var n = document.createElement('span');
        n.className = 'n';
        n.textContent = (g.models || []).length;
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
        var idx = searchIndex[i][0].indexOf(q);
        if (idx !== -1) hits.push([idx, searchIndex[i][1]]);
    }
    hits.sort(function (a, b) { return a[0] - b[0] || (a[1] < b[1] ? -1 : 1); });
    renderGrid(hits.map(function (h) { return h[1]; }), 'search: "' + q + '" — ' + hits.length + ' match(es)', true);
}

function spawn(model) {
    if (!/^[A-Za-z0-9_]+$/.test(model)) return;
    hide();                       // snappy: hide immediately, client releases focus
    post('spawnProp', { model: model });
}

function show(g) {
    groups = Array.isArray(g) ? g : [];
    allModels = []; searchIndex = [];
    groups.forEach(function (grp) {
        if (!grp || !Array.isArray(grp.models)) return;
        grp.models.forEach(function (m) {
            if (typeof m !== 'string') return;
            allModels.push(m);
            searchIndex.push([norm(m), m]);
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
    setTimeout(function () { el.search.focus(); }, 30);
}
function hide() { el.app.classList.add('hidden'); }

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
