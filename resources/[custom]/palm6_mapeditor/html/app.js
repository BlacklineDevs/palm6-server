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
var allModels = [];     // flat list for search
var activeCat = -1;

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
function thumbUrl(model) { return THUMB_BASE + model + '-' + joaat(model) + '.jpg'; }

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

function renderGrid(models, ctxLabel) {
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
    var n = Math.min(models.length, SEARCH_CAP);
    for (var i = 0; i < n; i++) frag.appendChild(makeCard(models[i]));
    el.grid.appendChild(frag);
    if (models.length > n) {
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
        var row = document.createElement('div');
        row.className = 'cat' + (i === activeCat ? ' active' : '');
        var label = document.createElement('span');
        label.textContent = g.category;
        var n = document.createElement('span');
        n.className = 'n';
        n.textContent = (g.models || []).length;
        row.appendChild(label);
        row.appendChild(n);
        row.addEventListener('click', function () { selectCat(i); });
        el.cats.appendChild(row);
    });
}

function selectCat(i) {
    activeCat = i;
    el.search.value = '';
    el.clear.style.display = 'none';
    renderCats();
    var g = groups[i];
    renderGrid(g ? g.models : [], (g ? g.category : ''));
}

function runSearch(q) {
    q = String(q || '').toLowerCase().replace(/\s+/g, '');
    el.clear.style.display = q ? 'block' : 'none';
    if (q.length < 2) { if (activeCat >= 0) selectCat(activeCat); return; }
    activeCat = -1;
    renderCats();
    var hits = [];
    for (var i = 0; i < allModels.length; i++) {
        var idx = allModels[i].indexOf(q);
        if (idx !== -1) hits.push([idx, allModels[i]]);
    }
    hits.sort(function (a, b) { return a[0] - b[0] || (a[1] < b[1] ? -1 : 1); });
    renderGrid(hits.map(function (h) { return h[1]; }), 'search: "' + q + '" — ' + hits.length + ' match(es)');
}

function spawn(model) {
    if (!/^[A-Za-z0-9_]+$/.test(model)) return;
    hide();                       // snappy: hide immediately, client releases focus
    post('spawnProp', { model: model });
}

function show(g) {
    groups = Array.isArray(g) ? g : [];
    allModels = [];
    groups.forEach(function (grp) { (grp.models || []).forEach(function (m) { allModels.push(m); }); });
    el.count.textContent = allModels.length.toLocaleString();
    activeCat = groups.length ? 0 : -1;
    el.search.value = '';
    el.clear.style.display = 'none';
    renderCats();
    if (activeCat >= 0) { var gg = groups[0]; renderGrid(gg.models, gg.category); }
    else renderGrid([], '');
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
