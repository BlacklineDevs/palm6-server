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
 *
 * FEATURES (parity with the paid cfx "Advanced Map & Prop Editor"):
 *   - Favorites: star any prop; a pinned "Favorites" view collects them.
 *   - Recent: the last props you spawned, auto-tracked, pinned view.
 *   - Smart search: conceptual keyword aliases ("trash"->bin/dumpster,
 *     "seat"->chair/bench) on top of fuzzy substring/subsequence matching.
 * Favorites + Recent persist in localStorage (per-resource, survives restarts),
 * so the tool remembers your working set with no server round-trip.
 */
'use strict';

var RES = 'palm6_mapeditor';
var SEARCH_CAP = 400;    // most props any single search renders at once
var RECENT_MAX = 60;     // spawned-prop history depth
var LS_FAV = 'palm6_mapeditor.favs';
var LS_RECENT = 'palm6_mapeditor.recent';

var groups = [];        // [{category, models:[...]}]
var allModels = [];     // flat list of raw model names
var modelSet = {};      // model -> true (membership, for fav/recent validity)
var searchIndex = [];   // [[normalizedName, rawName], ...] — normalized = lowercase, alnum-only
var modelCat = {};      // model -> category name (shown in the card description)
var view = { type: 'cat', i: 0 };   // current view: {type:'cat',i} | 'fav' | 'recent' | 'search'
var lastBrowse = { type: 'cat', i: 0 }; // last non-search view, restored when search clears
var imgOk = 0, imgFail = 0;   // thumbnail load tally (diagnostic; shown in footer)
// Thumbnails come from client Lua as data: URIs (CEF blocks the CDN directly).
var thumbData = {};     // model -> dataURI | false(no image) | undefined(unknown)
var awaiting = {};      // model -> [ {img, thumb}, ... ] cards waiting on a result
var thumbSent = {};     // model -> true once we've asked Lua (dedupe)

// Favorites (Set-like object) + recent (ordered, most-recent-first).
var favs = {};          // model -> true
var recent = [];        // [model, ...] most recent first
var kits = [];          // [{name, props, lights}, ...] blueprint kits (prefabs) from Lua
var scene = [];         // [{id, model, x, y, z}, ...] session placed props (outliner)
var sceneLights = [];   // [{id, kind, x, y, z, r, g, b}, ...] session lights (outliner)
var live = [];          // [{id, model, x, y, z}, ...] committed live-map props

// ---- persistence (localStorage; degrades to memory-only if unavailable) -----
function lsGet(key) {
    try { return JSON.parse(localStorage.getItem(key) || 'null'); } catch (e) { return null; }
}
function lsSet(key, val) {
    try { localStorage.setItem(key, JSON.stringify(val)); } catch (e) { /* private/quota: keep memory-only */ }
}
function loadPrefs() {
    var f = lsGet(LS_FAV);
    if (f && typeof f === 'object') { for (var k in f) if (f[k]) favs[k] = true; }
    var r = lsGet(LS_RECENT);
    if (Array.isArray(r)) recent = r.filter(function (m) { return typeof m === 'string'; }).slice(0, RECENT_MAX);
}
function saveFavs() { lsSet(LS_FAV, favs); }
function saveRecent() { lsSet(LS_RECENT, recent); }

// Normalize a name/query for matching: lowercase, strip every non-alphanumeric.
// This makes "traffic light", "traffic_light" and "trafficlight" all match
// prop_traffic_light_01, and makes matching case-insensitive.
function norm(s) { return String(s || '').toLowerCase().replace(/[^a-z0-9]/g, ''); }

// Conceptual keyword aliases — the "cognitive" layer over literal matching.
// When the whole query equals one of these words, we also match the listed
// terms, so "trash" finds bins and dumpsters even though no prop is literally
// named "trash". The literal query is always included too.
var ALIASES = {
    trash: ['bin', 'garbage', 'dumpster', 'rubbish', 'wastebin'],
    bin: ['bin', 'garbage', 'dumpster', 'trash'],
    garbage: ['bin', 'garbage', 'dumpster', 'trash'],
    cone: ['roadcone', 'cone', 'trafficcone'],
    seat: ['chair', 'seat', 'bench', 'stool', 'sofa', 'couch'],
    chair: ['chair', 'seat', 'stool', 'seating'],
    couch: ['couch', 'sofa'],
    sofa: ['sofa', 'couch'],
    light: ['light', 'lamp', 'lantern', 'neon', 'spotlight'],
    lamp: ['lamp', 'light', 'lantern', 'lamppost'],
    lighting: ['light', 'lamp', 'lantern', 'neon'],
    plant: ['plant', 'bush', 'pot', 'flower', 'shrub', 'fern', 'palm'],
    tree: ['tree', 'palm', 'pine', 'bush', 'trunk'],
    flower: ['flower', 'plant', 'pot', 'rose'],
    bush: ['bush', 'shrub', 'hedge', 'plant'],
    wall: ['wall', 'fence', 'barrier', 'partition'],
    fence: ['fence', 'barrier', 'railing', 'gate'],
    barrier: ['barrier', 'barrel', 'cone', 'fence', 'roadblock'],
    box: ['box', 'crate', 'carton', 'pallet'],
    crate: ['crate', 'box', 'pallet', 'carton'],
    container: ['container', 'crate', 'box', 'cargo'],
    table: ['table', 'desk', 'bench', 'counter'],
    desk: ['desk', 'table', 'counter'],
    door: ['door', 'gate', 'hatch', 'shutter'],
    window: ['window', 'glass', 'pane'],
    sign: ['sign', 'billboard', 'placard', 'poster'],
    barrel: ['barrel', 'drum', 'keg'],
    drum: ['drum', 'barrel'],
    rock: ['rock', 'stone', 'boulder', 'cliff'],
    stone: ['stone', 'rock', 'boulder'],
    fire: ['fire', 'flame', 'campfire', 'bonfire', 'brazier'],
    water: ['water', 'fountain', 'pool', 'hydrant'],
    food: ['food', 'burger', 'pizza', 'fruit', 'veg', 'meat'],
    money: ['money', 'cash', 'cashpile', 'gold'],
    weapon: ['weapon', 'gun', 'rifle', 'pistol', 'knife'],
    gun: ['gun', 'rifle', 'pistol', 'weapon'],
    tv: ['tv', 'television', 'screen', 'monitor'],
    screen: ['screen', 'tv', 'monitor', 'display'],
    car: ['car', 'vehicle', 'wreck'],
    barricade: ['barrier', 'barricade', 'roadblock', 'fence'],
    ramp: ['ramp', 'slope', 'skate'],
    ladder: ['ladder', 'stairs', 'step'],
    tent: ['tent', 'canopy', 'gazebo'],
    speaker: ['speaker', 'subwoofer', 'amp', 'audio'],
    cctv: ['cctv', 'camera', 'security'],
    cover: ['cover', 'wall', 'barrier', 'sandbag']
};

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
// Apply a resolved thumbnail to a card: a data: URI -> show it; false -> the
// generative fallback tile. Updates the load tally either way.
function applyThumb(model, img, thumb, data) {
    if (data) {
        img.onload = function () { imgOk++; updateThumbStat(); thumb.classList.remove('loading'); };
        img.onerror = function () {
            imgFail++; updateThumbStat();
            thumb.classList.remove('loading'); thumb.classList.add('fallback');
            if (img.parentNode) img.remove();
        };
        img.src = data;
    } else {
        imgFail++; updateThumbStat();
        thumb.classList.remove('loading'); thumb.classList.add('fallback');
        if (img.parentNode) img.remove();
    }
}

// Get a thumbnail for a card: from cache if known, else register the card as
// waiting and ask client Lua once (it proxies the CDN and replies via message).
function requestThumb(model, img, thumb) {
    var d = thumbData[model];
    if (d !== undefined) { applyThumb(model, img, thumb, d); return; }
    thumb.classList.add('loading');   // shimmer only once a real fetch is in flight
    (awaiting[model] = awaiting[model] || []).push({ img: img, thumb: thumb });
    if (!thumbSent[model]) {
        thumbSent[model] = true;
        post('thumb', { model: model });
        // Safety net: never buffer forever. If no reply in 12s, show the tile.
        setTimeout(function () { if (thumbData[model] === undefined) onThumb(model, false); }, 12000);
    }
}

// Lua delivered a thumbnail result — cache it and update every card waiting on it.
function onThumb(model, data) {
    thumbData[model] = (data === undefined ? false : data);
    var list = awaiting[model];
    if (list) {
        awaiting[model] = null;
        for (var i = 0; i < list.length; i++) applyThumb(model, list[i].img, list[i].thumb, thumbData[model]);
    }
    // If the detail panel is open on this model, refresh its preview meta +
    // description now that we know whether the image exists.
    if (detailOpen && detailModelName === model) refreshDetailMeta(model);
}

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
    detail: document.getElementById('detail'),
    detailPreview: document.getElementById('detailPreview'),
    detailTitle: document.getElementById('detailTitle'),
    detailModel: document.getElementById('detailModel'),
    detailChip: document.getElementById('detailChip'),
    detailMeta: document.getElementById('detailMeta'),
    detailDesc: document.getElementById('detailDesc'),
    detailFav: document.getElementById('detailFav'),
    detailSpawnLabel: document.getElementById('detailSpawnLabel'),
};

function post(cb, body) {
    return fetch('https://' + RES + '/' + cb, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(body || {}),
    }).catch(function () { /* dev / browser-preview: no NUI host, ignore */ });
}

// ---- favorites + recent --------------------------------------------------
function isFav(model) { return !!favs[model]; }
function toggleFav(model) {
    if (favs[model]) { delete favs[model]; } else { favs[model] = true; }
    saveFavs();
    // Keep every visible card's star in sync (a model can appear more than once).
    var stars = el.grid.querySelectorAll('.fav[data-model="' + cssEsc(model) + '"]');
    for (var i = 0; i < stars.length; i++) stars[i].classList.toggle('on', !!favs[model]);
    renderCats();  // refresh the Favorites count in the rail
    // If we're looking at the Favorites view, unstarring should drop the card.
    if (view.type === 'fav' && !favs[model]) selectFav();
}
function pushRecent(model) {
    recent = recent.filter(function (m) { return m !== model; });
    recent.unshift(model);
    if (recent.length > RECENT_MAX) recent.length = RECENT_MAX;
    saveRecent();
}
function favModels() {
    // Favorites in a stable order: catalog order, filtered to still-valid models.
    return allModels.filter(function (m) { return favs[m]; });
}
function recentModels() {
    return recent.filter(function (m) { return modelSet[m]; });
}
// Escape a model name for use in a CSS attribute selector (defensive; names are
// [A-Za-z0-9_] so this rarely matters, but keeps querySelectorAll safe).
function cssEsc(s) { return String(s).replace(/["\\]/g, '\\$&'); }

// Lazy thumbnail loading: a card requests its image only when it scrolls into
// view, so opening a big category never floods the server proxy (cap 16) and
// starves later requests into the fallback tile. IntersectionObserver is reliable
// in CEF (the earlier failure was a hand-rolled getBoundingClientRect loader, not
// IO). rootMargin fetches a screen ahead so scrolling stays ahead of the loads.
var thumbObserver = null;
function observeThumb(model, img, thumb) {
    if (!('IntersectionObserver' in window)) { requestThumb(model, img, thumb); return; }
    if (!thumbObserver) {
        thumbObserver = new IntersectionObserver(function (entries) {
            for (var i = 0; i < entries.length; i++) {
                if (!entries[i].isIntersecting) continue;
                var t = entries[i].target;
                thumbObserver.unobserve(t);
                var im = t.querySelector('img'), m = t.getAttribute('data-model');
                if (m && im) requestThumb(m, im, t);
            }
        }, { root: el.grid, rootMargin: '350px 0px' });
    }
    thumbObserver.observe(thumb);
}

// One prop card: a thumbnail (shimmer -> odb image, or a generative category-hued
// schematic swatch when the odb has no preview) + title + monospace model id +
// category chip, with a favorite star. onload/onerror update the footer tally so
// a mass load failure (e.g. the game blocking the CDN) is visible, not silent.
// showChip=false suppresses the category chip when every card shares one category.
function makeCard(model, showChip) {
    var cat = modelCat[model] || '';
    var card = document.createElement('div');
    card.className = 'card';
    card.setAttribute('role', 'button');
    card.tabIndex = 0;
    card.title = model;
    card.style.setProperty('--h', catHue(cat));

    var thumb = document.createElement('div');
    thumb.className = 'thumb';
    thumb.setAttribute('data-glyph', initials(model));
    thumb.setAttribute('data-model', model);
    var img = document.createElement('img');
    img.alt = '';
    thumb.appendChild(img);
    observeThumb(model, img, thumb);   // lazy: request only when scrolled into view

    // Favorite star (top-left). Click toggles without spawning.
    var star = document.createElement('button');
    star.className = 'fav' + (isFav(model) ? ' on' : '');
    star.setAttribute('data-model', model);
    star.setAttribute('aria-label', 'Toggle favorite');
    star.title = 'Favorite (F)';
    star.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 2.5l2.9 6 6.6.9-4.8 4.6 1.2 6.5L12 18.9 6.1 21l1.2-6.5L2.5 9.9l6.6-.9z"/></svg>';
    star.addEventListener('click', function (ev) { ev.stopPropagation(); toggleFav(model); });
    star.addEventListener('keydown', function (ev) { if (ev.key === 'Enter' || ev.key === ' ') ev.stopPropagation(); });
    thumb.appendChild(star);

    var hint = document.createElement('div');
    hint.className = 'spawn-hint';
    hint.textContent = 'INSPECT';   // click opens the detail view, not an instant spawn
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
    if (cat && showChip) {
        var chip = document.createElement('span');
        chip.className = 'chip';
        chip.textContent = cat;
        sub.appendChild(chip);
    }
    meta.appendChild(title);
    meta.appendChild(sub);

    card.appendChild(thumb);
    card.appendChild(meta);
    card.addEventListener('click', function () { openDetail(model); });
    card.addEventListener('keydown', function (ev) {
        if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); openDetail(model); }
        else if (ev.key === 'f' || ev.key === 'F') { ev.preventDefault(); toggleFav(model); }
    });
    return card;
}

// Render an empty-state block (used for empty categories, no search hits, and
// the empty Favorites/Recent views). icon + headline + hint.
function emptyState(headline, hint) {
    var e = document.createElement('div');
    e.className = 'empty';
    var big = document.createElement('span');
    big.className = 'big';
    big.textContent = headline;
    e.appendChild(big);
    if (hint) e.appendChild(document.createTextNode(hint));
    return e;
}

// capped=true only for search (bounds huge result sets). showChip controls the
// per-card category chip: hidden when the whole grid is one category (redundant),
// shown for search / Favorites / Recent where results span categories.
function renderGrid(models, ctxLabel, capped, showChip, emptyHead, emptyHint) {
    el.grid.scrollTop = 0;
    if (thumbObserver) thumbObserver.disconnect();   // stop watching the old cards
    el.grid.textContent = '';
    imgOk = 0; imgFail = 0; updateThumbStat();
    if (!models || models.length === 0) {
        el.grid.appendChild(emptyState(emptyHead || 'Nothing here', emptyHint || 'Pick another category or try a different search.'));
        el.ctx.textContent = ctxLabel || '';
        return;
    }
    var frag = document.createDocumentFragment();
    var n = capped ? Math.min(models.length, SEARCH_CAP) : models.length;
    for (var i = 0; i < n; i++) frag.appendChild(makeCard(models[i], showChip));
    el.grid.appendChild(frag);
    if (capped && models.length > n) {
        var more = document.createElement('div');
        more.className = 'empty';
        more.textContent = '+ ' + (models.length - n) + ' more · refine your search';
        el.grid.appendChild(more);
    }
    el.ctx.textContent = ctxLabel || '';
}

// SVG glyphs for the two pinned pseudo-categories.
var ICON_STAR = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 2.5l2.9 6 6.6.9-4.8 4.6 1.2 6.5L12 18.9 6.1 21l1.2-6.5L2.5 9.9l6.6-.9z"/></svg>';
var ICON_RECENT = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 4a8 8 0 1 0 7.5 5.3" fill="none" stroke-width="2" stroke-linecap="round"/><path d="M12 7v5l3.5 2" fill="none" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><path d="M12 2.5l3 2.2-3 2.2z"/></svg>';
// Blueprint kits: outline paths (fill none) + one filled node dot.
var ICON_KIT = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 4h16v16H4z" fill="none" stroke-width="1.7"/><path d="M8 4v5h5V4M13 9h7M13 9v11M4 14h9M8 14v6" fill="none" stroke-width="1.7"/><circle cx="17" cy="15" r="1.5"/></svg>';
var ICON_SCENE = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3l9 5-9 5-9-5 9-5Z" fill="none" stroke-width="1.7"/><path d="M3 12l9 5 9-5M3 16l9 5 9-5" fill="none" stroke-width="1.7"/></svg>';
var ICON_CUBE = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3l8 4.5v9L12 21l-8-4.5v-9L12 3Z" fill="none"/><path d="M4.5 7.7l7.5 4.2 7.5-4.2M12 12v8.5" fill="none"/></svg>';
var ICON_TRASH = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16M9 7V4h6v3M7 7l1 13h8l1-13" fill="none"/><path d="M10 11v5M14 11v5" fill="none"/></svg>';
var ICON_WORLD = '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="8.5" fill="none" stroke-width="1.7"/><path d="M3.8 12h16.4M12 3.5c2.1 2.3 3.2 5.1 3.2 8.5S14.1 18.2 12 20.5C9.9 18.2 8.8 15.4 8.8 12S9.9 5.8 12 3.5Z" fill="none" stroke-width="1.7"/></svg>';
var ICON_EDIT = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 20h9" fill="none"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4 12.5-12.5z" fill="none"/></svg>';

function makeSpecialRow(id, label, icon, count, active) {
    var row = document.createElement('div');
    row.className = 'cat special is-' + id + (active ? ' active' : '');
    row.innerHTML = '<span class="ic">' + icon + '</span>';
    var name = document.createElement('span');
    name.className = 'c-name';
    name.textContent = label;
    var n = document.createElement('span');
    n.className = 'n';
    n.textContent = count;
    row.appendChild(name);
    row.appendChild(n);
    row.addEventListener('click', function () {
        el.search.value = ''; el.clear.style.display = 'none';
        if (id === 'fav') selectFav();
        else if (id === 'recent') selectRecent();
        else if (id === 'kits') selectKits();
        else if (id === 'live') selectLive();
        else selectScene();
    });
    return row;
}

function renderCats() {
    el.cats.textContent = '';

    // Pinned pseudo-categories: Scene + Live map + Blueprint kits + Favorites + Recent.
    el.cats.appendChild(makeSpecialRow('scene', 'Scene', ICON_SCENE, scene.length + sceneLights.length, view.type === 'scene'));
    el.cats.appendChild(makeSpecialRow('live', 'Live map', ICON_WORLD, live.length, view.type === 'live'));
    el.cats.appendChild(makeSpecialRow('kits', 'Blueprint kits', ICON_KIT, kits.length, view.type === 'kits'));
    el.cats.appendChild(makeSpecialRow('fav', 'Favorites', ICON_STAR, favModels().length, view.type === 'fav'));
    el.cats.appendChild(makeSpecialRow('recent', 'Recent', ICON_RECENT, recentModels().length, view.type === 'recent'));
    var sep = document.createElement('div');
    sep.className = 'cat-sep';
    el.cats.appendChild(sep);

    groups.forEach(function (g, i) {
        if (!g) return;
        var row = document.createElement('div');
        row.className = 'cat' + (view.type === 'cat' && i === view.i ? ' active' : '');
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
    view = { type: 'cat', i: i }; lastBrowse = view;
    renderCats();
    var g = groups[i];
    // Single-category grid: chip is redundant, hide it.
    renderGrid(g ? g.models : [], (g ? g.category : ''), false, false);
}

function selectFav() {
    view = { type: 'fav' }; lastBrowse = view;
    renderCats();
    renderGrid(favModels(), 'Favorites', false, true,
        'No favorites yet', 'Click the star on any prop to pin it here.');
}

function selectRecent() {
    view = { type: 'recent' }; lastBrowse = view;
    renderCats();
    renderGrid(recentModels(), 'Recently spawned', false, true,
        'Nothing spawned yet', 'Props you place show up here for quick reuse.');
}

// ---- blueprint kits (prefabs) --------------------------------------------
function onKits(list) {
    kits = Array.isArray(list) ? list : [];
    if (el.app && !el.app.classList.contains('hidden')) renderCats();  // refresh rail count
    if (view.type === 'kits') selectKits();
}

function makeKitCard(kit) {
    var card = document.createElement('div');
    card.className = 'card kit-card';
    card.setAttribute('role', 'button');
    card.tabIndex = 0;
    card.title = kit.name;

    var tile = document.createElement('div');
    tile.className = 'kit-tile';
    tile.innerHTML = ICON_KIT;
    var badge = document.createElement('div');
    badge.className = 'kit-badge';
    badge.textContent = kit.props + (kit.props === 1 ? ' prop' : ' props');
    tile.appendChild(badge);

    var meta = document.createElement('div'); meta.className = 'meta';
    var title = document.createElement('div'); title.className = 'title'; title.textContent = prettify(kit.name);
    var sub = document.createElement('div'); sub.className = 'sub';
    var info = document.createElement('div'); info.className = 'mid';
    info.textContent = kit.props + ' props' + (kit.lights ? ' · ' + kit.lights + ' lights' : '');
    sub.appendChild(info);
    meta.appendChild(title); meta.appendChild(sub);

    card.appendChild(tile); card.appendChild(meta);
    card.addEventListener('click', function () { openKitDetail(kit); });
    card.addEventListener('keydown', function (ev) {
        if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); openKitDetail(kit); }
    });
    return card;
}

function selectKits() {
    view = { type: 'kits' }; lastBrowse = view;
    renderCats();
    el.grid.scrollTop = 0;
    if (thumbObserver) thumbObserver.disconnect();
    el.grid.textContent = '';
    imgOk = 0; imgFail = 0; updateThumbStat();
    if (!kits.length) {
        el.grid.appendChild(emptyState('No blueprint kits yet',
            'Build props in the editor and save them with /mapprefabsave <name>. They appear here to stamp anywhere.'));
        el.ctx.textContent = 'Blueprint kits';
        return;
    }
    var frag = document.createDocumentFragment();
    for (var i = 0; i < kits.length; i++) frag.appendChild(makeKitCard(kits[i]));
    el.grid.appendChild(frag);
    el.ctx.textContent = kits.length + (kits.length === 1 ? ' blueprint kit' : ' blueprint kits');
}

// ---- scene outliner ------------------------------------------------------
function onScene(list, lights) {
    scene = Array.isArray(list) ? list : [];
    sceneLights = Array.isArray(lights) ? lights : [];
    if (el.app && !el.app.classList.contains('hidden')) renderCats();  // refresh Scene count
    if (view.type === 'scene') selectScene(true);
}

function makeLightRow(item) {
    var row = document.createElement('div');
    row.className = 'scene-row'; row.tabIndex = 0; row.setAttribute('role', 'button'); row.title = 'Jump to light';
    var sw = document.createElement('span'); sw.className = 'scene-ic light-swatch';
    var dot = document.createElement('span'); dot.className = 'light-dot';
    dot.style.setProperty('--lc', 'rgb(' + (item.r || 255) + ',' + (item.g || 200) + ',' + (item.b || 140) + ')');
    sw.appendChild(dot);
    var main = document.createElement('div'); main.className = 'scene-main';
    var nm = document.createElement('div'); nm.className = 'scene-name'; nm.textContent = (item.kind === 'spot' ? 'Spot light' : 'Point light');
    var co = document.createElement('div'); co.className = 'scene-coords';
    co.textContent = item.x.toFixed(1) + ', ' + item.y.toFixed(1) + ', ' + item.z.toFixed(1);
    main.appendChild(nm); main.appendChild(co);
    var del = document.createElement('button'); del.className = 'scene-del'; del.title = 'Delete light'; del.setAttribute('aria-label', 'Delete light');
    del.innerHTML = ICON_TRASH;
    del.addEventListener('click', function (ev) { ev.stopPropagation(); post('sceneLightDelete', { id: item.id }); });
    row.appendChild(sw); row.appendChild(main); row.appendChild(del);
    row.addEventListener('click', function () { hide(); post('sceneLightGoto', { id: item.id }); });
    row.addEventListener('keydown', function (ev) {
        if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); hide(); post('sceneLightGoto', { id: item.id }); }
    });
    return row;
}

function gotoScene(id) { hide(); post('sceneGoto', { id: id }); }

var sceneSel = {};        // id -> true (outliner multi-select)
var sceneSaving = false;  // naming bar open for "save selection as kit"
var sceneSaveName = '';
function sceneSelectedIds() {
    var out = [];
    for (var i = 0; i < scene.length; i++) if (sceneSel[scene[i].id]) out.push(scene[i].id);
    return out;
}

function makeSceneRow(item) {
    var row = document.createElement('div');
    row.className = 'scene-row' + (sceneSel[item.id] ? ' picked' : '');
    row.tabIndex = 0;
    row.setAttribute('role', 'button');
    row.title = 'Jump to ' + item.model;

    var check = document.createElement('input');
    check.type = 'checkbox'; check.className = 'scene-check';
    check.checked = !!sceneSel[item.id];
    check.setAttribute('aria-label', 'Select ' + item.model);
    check.addEventListener('click', function (ev) { ev.stopPropagation(); });
    check.addEventListener('change', function () {
        if (check.checked) sceneSel[item.id] = true; else delete sceneSel[item.id];
        selectScene(true);
    });

    var ic = document.createElement('span'); ic.className = 'scene-ic'; ic.innerHTML = ICON_CUBE;
    var main = document.createElement('div'); main.className = 'scene-main';
    var nm = document.createElement('div'); nm.className = 'scene-name'; nm.textContent = prettify(item.model);
    var co = document.createElement('div'); co.className = 'scene-coords';
    co.textContent = item.model + '  ·  ' + item.x.toFixed(1) + ', ' + item.y.toFixed(1) + ', ' + item.z.toFixed(1);
    main.appendChild(nm); main.appendChild(co);
    var del = document.createElement('button');
    del.className = 'scene-del'; del.title = 'Delete'; del.setAttribute('aria-label', 'Delete prop');
    del.innerHTML = ICON_TRASH;
    del.addEventListener('click', function (ev) { ev.stopPropagation(); post('sceneDelete', { id: item.id }); });

    row.appendChild(check); row.appendChild(ic); row.appendChild(main); row.appendChild(del);
    row.addEventListener('click', function () { gotoScene(item.id); });
    row.addEventListener('keydown', function (ev) {
        if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); gotoScene(item.id); }
        else if (ev.key === 'Delete') { ev.preventDefault(); post('sceneDelete', { id: item.id }); }
    });
    return row;
}

function sceneToolbar() {
    var selIds = sceneSelectedIds();
    var bar = document.createElement('div'); bar.className = 'scene-toolbar';

    var left = document.createElement('label'); left.className = 'scene-selall';
    var all = document.createElement('input'); all.type = 'checkbox';
    all.checked = selIds.length > 0 && selIds.length === scene.length;
    all.indeterminate = selIds.length > 0 && selIds.length < scene.length;
    all.setAttribute('aria-label', 'Select all');
    all.addEventListener('change', function () {
        if (all.checked) { scene.forEach(function (o) { sceneSel[o.id] = true; }); } else { sceneSel = {}; }
        selectScene(true);
    });
    var lab = document.createElement('span');
    lab.textContent = selIds.length > 0 ? (selIds.length + ' selected')
        : (scene.length + (scene.length === 1 ? ' object' : ' objects'));
    left.appendChild(all); left.appendChild(lab);
    bar.appendChild(left);

    if (selIds.length > 0) {
        var actions = document.createElement('div'); actions.className = 'scene-actions';
        var save = document.createElement('button'); save.className = 'scene-batch-save'; save.type = 'button';
        save.textContent = 'Save as kit';
        save.addEventListener('click', function () { sceneSaving = true; selectScene(true); });
        var clr = document.createElement('button'); clr.className = 'scene-batch-clear'; clr.type = 'button';
        clr.textContent = 'Clear';
        clr.addEventListener('click', function () { sceneSel = {}; sceneSaving = false; selectScene(true); });
        var del = document.createElement('button'); del.className = 'scene-batch-del'; del.type = 'button';
        del.textContent = 'Delete ' + selIds.length;
        del.addEventListener('click', function () { post('sceneDeleteMany', { ids: selIds }); sceneSel = {}; sceneSaving = false; selectScene(true); });
        actions.appendChild(save); actions.appendChild(clr); actions.appendChild(del);
        bar.appendChild(actions);
    }
    return bar;
}

function doSaveKit() {
    var ids = sceneSelectedIds();
    var name = (sceneSaveName || '').trim();
    if (!ids.length) { cancelSaveKit(); return; }
    if (!name) return;   // require a name
    post('sceneSaveKit', { name: name, ids: ids });
    sceneSaving = false; sceneSaveName = ''; sceneSel = {};
    selectScene(true);
}
function cancelSaveKit() { sceneSaving = false; sceneSaveName = ''; selectScene(true); }

function sceneSaveBar() {
    var bar = document.createElement('div'); bar.className = 'scene-savebar';
    var input = document.createElement('input');
    input.type = 'text'; input.className = 'scene-name-input'; input.maxLength = 48;
    input.placeholder = 'Kit name (e.g. downtown_checkpoint)…';
    input.value = sceneSaveName || '';
    input.addEventListener('input', function () { sceneSaveName = input.value; });
    input.addEventListener('keydown', function (ev) {
        if (ev.key === 'Enter') { ev.preventDefault(); doSaveKit(); }
        else if (ev.key === 'Escape') { ev.stopPropagation(); cancelSaveKit(); }
    });
    var cancel = document.createElement('button'); cancel.className = 'scene-batch-clear'; cancel.type = 'button';
    cancel.textContent = 'Cancel';
    cancel.addEventListener('click', cancelSaveKit);
    var go = document.createElement('button'); go.className = 'scene-save-go'; go.type = 'button';
    go.textContent = 'Save kit';
    go.addEventListener('click', doSaveKit);
    bar.appendChild(input); bar.appendChild(cancel); bar.appendChild(go);
    setTimeout(function () { input.focus(); }, 0);
    return bar;
}

function selectScene(keepScroll) {
    view = { type: 'scene' }; lastBrowse = view;
    renderCats();
    var prev = keepScroll ? el.grid.scrollTop : 0;
    if (thumbObserver) thumbObserver.disconnect();
    el.grid.textContent = '';
    imgOk = 0; imgFail = 0; updateThumbStat();
    // prune selection of ids no longer in the scene
    var valid = {}; scene.forEach(function (o) { valid[o.id] = true; });
    Object.keys(sceneSel).forEach(function (k) { if (!valid[k]) delete sceneSel[k]; });

    if (!scene.length && !sceneLights.length) {
        el.grid.appendChild(emptyState('Nothing placed yet',
            'Spawn props or place lights to build your scene — they list here to jump to or remove.'));
        el.ctx.textContent = 'Scene';
        return;
    }
    if (!sceneSelectedIds().length) sceneSaving = false;   // no selection -> no naming bar
    var container = document.createElement('div'); container.className = 'scene-view';

    if (scene.length) {
        container.appendChild(sceneToolbar());
        if (sceneSaving) container.appendChild(sceneSaveBar());
        var list = document.createElement('div'); list.className = 'scene-list';
        for (var i = 0; i < scene.length; i++) list.appendChild(makeSceneRow(scene[i]));
        container.appendChild(list);
    }
    if (sceneLights.length) {
        var head = document.createElement('div'); head.className = 'scene-section';
        head.textContent = sceneLights.length + (sceneLights.length === 1 ? ' light' : ' lights');
        container.appendChild(head);
        var llist = document.createElement('div'); llist.className = 'scene-list';
        for (var j = 0; j < sceneLights.length; j++) llist.appendChild(makeLightRow(sceneLights[j]));
        container.appendChild(llist);
    }
    el.grid.appendChild(container);
    var total = scene.length + sceneLights.length;
    el.ctx.textContent = total + (total === 1 ? ' object in scene' : ' objects in scene');
    el.grid.scrollTop = prev;
}

// ---- live-map outliner ---------------------------------------------------
var liveSel = {};   // id -> true (live multi-select)
function liveSelectedIds() {
    var out = [];
    for (var i = 0; i < live.length; i++) if (liveSel[live[i].id]) out.push(live[i].id);
    return out;
}
function onLive(list) {
    live = Array.isArray(list) ? list : [];
    if (el.app && !el.app.classList.contains('hidden')) renderCats();  // refresh Live count
    if (view.type === 'live') selectLive(true);
}

function makeLiveRow(item) {
    var row = document.createElement('div');
    row.className = 'scene-row' + (liveSel[item.id] ? ' picked' : '');
    row.tabIndex = 0; row.setAttribute('role', 'button'); row.title = 'Jump to ' + item.model;

    var check = document.createElement('input');
    check.type = 'checkbox'; check.className = 'scene-check';
    check.checked = !!liveSel[item.id]; check.setAttribute('aria-label', 'Select ' + item.model);
    check.addEventListener('click', function (ev) { ev.stopPropagation(); });
    check.addEventListener('change', function () {
        if (check.checked) liveSel[item.id] = true; else delete liveSel[item.id];
        selectLive(true);
    });

    var ic = document.createElement('span'); ic.className = 'scene-ic'; ic.innerHTML = ICON_CUBE;
    var main = document.createElement('div'); main.className = 'scene-main';
    var nm = document.createElement('div'); nm.className = 'scene-name'; nm.textContent = prettify(item.model);
    var co = document.createElement('div'); co.className = 'scene-coords';
    co.textContent = item.model + '  ·  ' + item.x.toFixed(1) + ', ' + item.y.toFixed(1) + ', ' + item.z.toFixed(1);
    main.appendChild(nm); main.appendChild(co);

    var grab = document.createElement('button');
    grab.className = 'scene-grab'; grab.title = 'Grab to edit'; grab.setAttribute('aria-label', 'Grab to edit');
    grab.innerHTML = ICON_EDIT;
    grab.addEventListener('click', function (ev) { ev.stopPropagation(); hide(); post('liveGrab', { id: item.id }); });
    var del = document.createElement('button');
    del.className = 'scene-del'; del.title = 'Delete everywhere'; del.setAttribute('aria-label', 'Delete everywhere');
    del.innerHTML = ICON_TRASH;
    del.addEventListener('click', function (ev) { ev.stopPropagation(); post('liveDelete', { id: item.id }); });

    row.appendChild(check); row.appendChild(ic); row.appendChild(main); row.appendChild(grab); row.appendChild(del);
    row.addEventListener('click', function () { hide(); post('liveGoto', { id: item.id }); });
    row.addEventListener('keydown', function (ev) {
        if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); hide(); post('liveGoto', { id: item.id }); }
    });
    return row;
}

function liveToolbar(shown) {
    var selIds = liveSelectedIds();
    var bar = document.createElement('div'); bar.className = 'scene-toolbar';
    var left = document.createElement('label'); left.className = 'scene-selall';
    var all = document.createElement('input'); all.type = 'checkbox';
    all.checked = selIds.length > 0 && selIds.length === shown.length;
    all.indeterminate = selIds.length > 0 && selIds.length < shown.length;
    all.setAttribute('aria-label', 'Select all');
    all.addEventListener('change', function () {
        if (all.checked) { shown.forEach(function (o) { liveSel[o.id] = true; }); } else { liveSel = {}; }
        selectLive(true);
    });
    var lab = document.createElement('span');
    lab.textContent = selIds.length > 0 ? (selIds.length + ' selected')
        : (live.length + (live.length === 1 ? ' live prop' : ' live props'));
    left.appendChild(all); left.appendChild(lab);
    bar.appendChild(left);
    if (selIds.length > 0) {
        var actions = document.createElement('div'); actions.className = 'scene-actions';
        var clr = document.createElement('button'); clr.className = 'scene-batch-clear'; clr.type = 'button';
        clr.textContent = 'Clear';
        clr.addEventListener('click', function () { liveSel = {}; selectLive(true); });
        var del = document.createElement('button'); del.className = 'scene-batch-del'; del.type = 'button';
        del.textContent = 'Delete ' + selIds.length;
        del.addEventListener('click', function () { post('liveDeleteMany', { ids: selIds }); liveSel = {}; selectLive(true); });
        actions.appendChild(clr); actions.appendChild(del);
        bar.appendChild(actions);
    }
    return bar;
}

function selectLive(keepScroll) {
    view = { type: 'live' }; lastBrowse = view;
    renderCats();
    var prev = keepScroll ? el.grid.scrollTop : 0;
    if (thumbObserver) thumbObserver.disconnect();
    el.grid.textContent = '';
    imgOk = 0; imgFail = 0; updateThumbStat();
    var valid = {}; live.forEach(function (o) { valid[o.id] = true; });
    Object.keys(liveSel).forEach(function (k) { if (!valid[k]) delete liveSel[k]; });

    if (!live.length) {
        el.grid.appendChild(emptyState('Live map is empty',
            'Commit props with /mapcommit to publish them to the shared map — they list here to jump to, grab, or delete.'));
        el.ctx.textContent = 'Live map';
        return;
    }
    var container = document.createElement('div'); container.className = 'scene-view';
    var cap = Math.min(live.length, 500);
    var shown = live.slice(0, cap);
    container.appendChild(liveToolbar(shown));
    var list = document.createElement('div'); list.className = 'scene-list';
    for (var i = 0; i < cap; i++) list.appendChild(makeLiveRow(shown[i]));
    container.appendChild(list);
    if (live.length > cap) {
        var more = document.createElement('div'); more.className = 'empty';
        more.textContent = '+ ' + (live.length - cap) + ' more live props (showing first ' + cap + ')';
        container.appendChild(more);
    }
    el.grid.appendChild(container);
    el.ctx.textContent = live.length + (live.length === 1 ? ' live prop' : ' live props');
    el.grid.scrollTop = prev;
}

// Restore whatever view was active before the user started typing a search.
function restoreBrowse() {
    if (lastBrowse.type === 'live') { selectLive(); return; }
    if (lastBrowse.type === 'scene') { selectScene(); return; }
    if (lastBrowse.type === 'kits') { selectKits(); return; }
    if (lastBrowse.type === 'fav') { selectFav(); return; }
    if (lastBrowse.type === 'recent') { selectRecent(); return; }
    var ci = lastBrowse.type === 'cat' ? lastBrowse.i : 0;
    if (ci < 0 || ci >= groups.length) ci = groups.length ? 0 : -1;
    if (ci < 0) { view = { type: 'cat', i: -1 }; renderCats(); renderGrid([], '', false, false); return; }
    selectCat(ci);
}

function runSearch(rawInput) {
    var raw = String(rawInput || '');
    el.clear.style.display = raw ? 'block' : 'none';
    var q = norm(raw);
    if (q.length < 2) {
        // Not a search (empty/cleared/too short): restore the last browsed view.
        // Never leaves stale search results on screen, and never touches the
        // input, so a single typed char isn't wiped mid-type.
        restoreBrowse();
        return;
    }
    view = { type: 'search' };
    renderCats();
    // Smart layer: expand the query into conceptual terms (aliases) + the literal.
    var terms = ALIASES[q] ? ALIASES[q].slice() : [];
    if (terms.indexOf(q) === -1) terms.push(q);
    var isAlias = ALIASES[q] && ALIASES[q].length > 0;
    var hits = [];
    for (var i = 0; i < searchIndex.length; i++) {
        var name = searchIndex[i][0], best = -1;
        for (var t = 0; t < terms.length; t++) {
            var sc = fuzzyScore(name, terms[t]);
            if (sc > best) best = sc;
        }
        if (best >= 0) hits.push([best, searchIndex[i][1]]);
    }
    // Higher score first; tie-break alphabetically for stable ordering.
    hits.sort(function (a, b) { return b[0] - a[0] || (a[1] < b[1] ? -1 : 1); });
    var label = hits.length + ' match(es) for "' + q + '"' + (isAlias ? ' + related' : '');
    renderGrid(hits.map(function (h) { return h[1]; }), label, true, true,
        'No matches', 'Try a shorter or more general word.');
}

function spawn(model) {
    if (!/^[A-Za-z0-9_]+$/.test(model)) return;
    pushRecent(model);            // remember it for the Recent view
    hide();                       // snappy: hide immediately, client releases focus
    post('spawnProp', { model: model });
}

// --- prop detail view -----------------------------------------------------
// Clicking a card opens this instead of spawning: a large preview, metadata, a
// generated description, a favorite toggle, and the Spawn button that actually
// places the prop. Reuses the thumbnail pipeline + favorites so nothing is duped.
var detailOpen = false;
var detailModelName = null;
var detailMode = 'prop';      // 'prop' | 'kit'
var detailKitName = null;

function setDetailButton(label) { if (el.detailSpawnLabel) el.detailSpawnLabel.textContent = label; }

// A short, honest, deterministic blurb (GTA props ship no official descriptions).
function describe(model, cat) {
    var c = cat ? cat.toLowerCase() : 'general';
    var s = prettify(model) + ' is a ' + c + ' asset from the GTA V object library. ';
    if (thumbData[model] === false) s += 'No preview image has been generated for this model yet, but it is indexed and ready to place. ';
    s += 'Spawn it to drop the prop at your crosshair, then position it with the editor controls or the gizmo.';
    return s;
}

function metaRow(k, v) {
    var row = document.createElement('div'); row.className = 'meta-row';
    var dt = document.createElement('dt'); dt.textContent = k;
    var dd = document.createElement('dd'); dd.textContent = v;
    row.appendChild(dt); row.appendChild(dd);
    return row;
}

function openDetail(model) {
    if (!modelSet[model]) return;
    detailModelName = model;
    detailMode = 'prop'; detailKitName = null;
    if (el.detailFav) el.detailFav.style.display = '';
    setDetailButton('Spawn prop');
    var cat = modelCat[model] || '';

    // Preview reuses the exact thumbnail pipeline (server proxy -> data URI).
    el.detailPreview.textContent = '';
    var thumb = document.createElement('div');
    thumb.className = 'thumb';
    thumb.setAttribute('data-glyph', initials(model));
    thumb.style.setProperty('--h', catHue(cat));
    var img = document.createElement('img'); img.alt = '';
    thumb.appendChild(img);
    el.detailPreview.appendChild(thumb);
    requestThumb(model, img, thumb);

    el.detailTitle.textContent = prettify(model);
    el.detailModel.textContent = model;
    if (cat) { el.detailChip.textContent = cat; el.detailChip.style.display = ''; }
    else { el.detailChip.style.display = 'none'; }
    el.detailDesc.textContent = describe(model, cat);

    el.detailMeta.textContent = '';
    el.detailMeta.appendChild(metaRow('Category', cat || 'Uncategorized'));
    el.detailMeta.appendChild(metaRow('Model', model));
    el.detailMeta.appendChild(metaRow('Hash', String(joaat(model))));
    var res = thumbData[model] === false ? 'no image' : (thumbData[model] ? '384 × 216' : 'loading…');
    el.detailMeta.appendChild(metaRow('Preview', res));

    el.detailFav.classList.toggle('on', isFav(model));

    el.detail.classList.remove('hidden');
    el.detail.setAttribute('aria-hidden', 'false');
    detailOpen = true;
}

// Update just the Preview meta row + description in place (no rebuild/flicker),
// e.g. when a slow thumbnail resolves while the detail is open.
function refreshDetailMeta(model) {
    var res = thumbData[model] === false ? 'no image' : (thumbData[model] ? '384 × 216' : 'loading…');
    var rows = el.detailMeta.querySelectorAll('.meta-row dd');
    if (rows[3]) rows[3].textContent = res;
    el.detailDesc.textContent = describe(model, modelCat[model] || '');
}

function closeDetail() {
    if (!detailOpen) return;
    detailOpen = false;
    el.detail.classList.add('hidden');
    el.detail.setAttribute('aria-hidden', 'true');
    detailModelName = null;
    detailKitName = null;
}

// Detail view for a blueprint kit (prefab): reuses the panel with a blueprint
// preview tile, kit metadata, and a "Stamp at aim" button in place of Spawn.
function openKitDetail(kit) {
    detailMode = 'kit';
    detailKitName = kit.name;

    el.detailPreview.textContent = '';
    var tile = document.createElement('div');
    tile.className = 'thumb kit-detail-tile';
    tile.innerHTML = ICON_KIT;
    el.detailPreview.appendChild(tile);

    el.detailTitle.textContent = prettify(kit.name);
    el.detailModel.textContent = kit.name;
    el.detailChip.textContent = 'PREFAB'; el.detailChip.style.display = '';
    el.detailDesc.textContent = 'A saved blueprint of ' + kit.props + (kit.props === 1 ? ' prop' : ' props') +
        (kit.lights ? ' and ' + kit.lights + (kit.lights === 1 ? ' light' : ' lights') : '') +
        '. Stamp it at your crosshair to drop the whole group as one placement, then reposition or /mapcommit to publish it live.';

    el.detailMeta.textContent = '';
    el.detailMeta.appendChild(metaRow('Type', 'Blueprint kit'));
    el.detailMeta.appendChild(metaRow('Props', String(kit.props)));
    el.detailMeta.appendChild(metaRow('Lights', String(kit.lights)));
    el.detailMeta.appendChild(metaRow('Target', 'Your aim'));

    if (el.detailFav) el.detailFav.style.display = 'none';
    setDetailButton('Stamp at aim');

    el.detail.classList.remove('hidden');
    el.detail.setAttribute('aria-hidden', 'false');
    detailOpen = true;
}

function stampKit(name) {
    hide();                       // close so the stamp lands at the crosshair
    post('stampPrefab', { name: name });
}

function show(g) {
    groups = Array.isArray(g) ? g : [];
    allModels = []; searchIndex = []; modelCat = {}; modelSet = {};
    groups.forEach(function (grp) {
        if (!grp || !Array.isArray(grp.models)) return;
        grp.models.forEach(function (m) {
            if (typeof m !== 'string') return;
            // A model can be listed in more than one category; index it once so the
            // count, search results and Favorites never show duplicate cards. (The
            // category grids still render from groups[i].models, so a shared prop
            // still appears under each of its categories when browsing.)
            if (!modelSet[m]) { allModels.push(m); searchIndex.push([norm(m), m]); modelSet[m] = true; }
            if (grp.category && !modelCat[m]) modelCat[m] = grp.category;
        });
    });
    el.count.textContent = allModels.length.toLocaleString();
    view = { type: 'cat', i: groups.length ? 0 : -1 };
    lastBrowse = view;
    el.search.value = '';
    el.clear.style.display = 'none';
    renderCats();
    var gg = groups[view.i];
    renderGrid(gg ? gg.models : [], gg ? gg.category : '', false, false);
    el.app.classList.remove('hidden');
    el.app.setAttribute('aria-hidden', 'false');
    // Don't steal focus into the search box when we opened straight onto an
    // overlay (/maphelp, /maplog): a focused #search makes typing() true, which
    // would kill the H/L toggle that dismisses the overlay.
    setTimeout(function () { if (!helpOpen && !activityOpen) el.search.focus(); }, 30);
}
function hide() { el.app.classList.add('hidden'); el.app.setAttribute('aria-hidden', 'true'); helpHide(); activityHide(); closeDetail(); }

// --- controls & commands reference ----------------------------------------
// Mirrors README.md exactly (the authoritative command list). Kept as data so
// the in-game help sheet, the README and the actual commands stay in step.
var KEYS_LIVE = [
    ['LMB', 'hold to carry to aim'], ['Arrows', 'nudge on ground'],
    ['Shift + ↑/↓', 'height'], ['Q / E', 'rotate'],
    ['Space', 'snap to surface'], ['Esc', 'exit editor']
];
var KEYS_GIZMO = [
    ['W', 'move'], ['R', 'rotate'], ['S', 'scale'],
    ['Q', 'world / local'], ['LAlt', 'to ground'], ['Enter', 'confirm']
];
var CMD_GROUPS = [
    { name: 'Editor', cmds: [
        ['/mapedit', 'toggle the editor'],
        ['/propui', 'this visual prop browser'],
        ['/props · /propsearch <q>', 'catalog browse / fuzzy search'],
        ['/prop <model>', 'spawn a specific model at aim'],
        ['/matnext · /matprev · /matcat', 'cycle the quick-prop catalog'],
        ['/matpick', 'select the object nearest aim'],
        ['/mapcam', 'freecam — WASD fly, mouse look, wheel zoom'],
        ['/matdup', 'duplicate selected'],
        ['/matundo', 'undo last spawn / delete'],
        ['/matdel · /mapclear', 'delete selected / all']
    ] },
    { name: 'Transform', cmds: [
        ['/matgizmo', 'visual move / rotate / scale handles'],
        ['/mataxis', 'cycle rotate axis (yaw/pitch/roll)'],
        ['/matrot <rx ry rz>', 'set exact rotation'],
        ['/matfreeze · /matcollision', 'toggle freeze / collision'],
        ['/matcopy', 'copy selected coords to clipboard'],
        ['/mattp', 'teleport yourself to selected']
    ] },
    { name: 'Mass tools', cmds: [
        ['/matgrid <rows cols spacing>', 'grid-spawn the selected model'],
        ['/matscatter <count radius>', 'scatter copies with random yaw'],
        ['/matareadel <radius>', 'delete placed props within radius']
    ] },
    { name: 'Lights', cmds: [
        ['/matlight [point|spot]', 'place a light at aim'],
        ['/matlightcolor <r g b>', 'set light colour'],
        ['/matlightrange <n> · /matlightint <n>', 'range / intensity'],
        ['/matlightpick · /matlightdel', 'select / delete light']
    ] },
    { name: 'World erase', cmds: [
        ['/materase · /materaseundo', 'hide vanilla prop (personal) / undo'],
        ['/mapworlderase', 'erase vanilla prop for everyone (saved)'],
        ['/mapworldrestore', 'restore nearest world-erase']
    ] },
    { name: 'Live maps', cmds: [
        ['/mapcommit [map]', 'publish session (props + lights) live'],
        ['/maplist', 'list live maps and their counts'],
        ['/maplivedel', 'delete the live prop you aim at'],
        ['/maplivegrab', 'grab a live prop back to edit'],
        ['/maplightdel', 'delete nearest live light'],
        ['/mapwipe <map>', 'delete an entire live map']
    ] },
    { name: 'Prefabs', cmds: [
        ['/mapprefabsave <name>', 'save session as a reusable prefab'],
        ['/mapprefabstamp <name> [yaw]', 'stamp a prefab at aim, rotated'],
        ['/mapprefablist · /mapprefabdel <name>', 'list / delete prefabs']
    ] },
    { name: 'Scene entities', cmds: [
        ['/matped <model> [scenario]', 'place a scene ped'],
        ['/matveh <model>', 'place a scene vehicle'],
        ['/matentdel', 'remove scene ped / vehicle at aim'],
        ['/mapworkmap <name>', 'set which map entities place onto'],
        ['/mapentwipe [map] · /mapentlist', 'wipe / count scene entities']
    ] },
    { name: 'Export', cmds: [
        ['/mapexport [name]', 'export session → Lua / JSON / ymap.xml'],
        ['/mapexportlive <map>', 'export the live map → Lua / JSON / ymap.xml'],
        ['/mapload <file>', 'reload a saved export']
    ] }
];

var helpBuilt = false, helpOpen = false;
var elHelp, elHelpBody;

function keycapRow(pairs, title) {
    var sec = document.createElement('div');
    sec.className = 'help-keys';
    var h = document.createElement('div'); h.className = 'help-keys-t'; h.textContent = title;
    sec.appendChild(h);
    var row = document.createElement('div'); row.className = 'help-keys-row';
    pairs.forEach(function (p) {
        var item = document.createElement('div'); item.className = 'kc';
        var k = document.createElement('kbd'); k.textContent = p[0];
        var lab = document.createElement('span'); lab.textContent = p[1];
        item.appendChild(k); item.appendChild(lab); row.appendChild(item);
    });
    sec.appendChild(row);
    return sec;
}

function buildHelp() {
    elHelp = document.getElementById('helpOverlay');
    elHelpBody = document.getElementById('helpBody');
    if (!elHelpBody) return;
    elHelpBody.textContent = '';

    var keys = document.createElement('div'); keys.className = 'help-keyblock';
    keys.appendChild(keycapRow(KEYS_LIVE, 'Live keys (something selected)'));
    keys.appendChild(keycapRow(KEYS_GIZMO, 'Gizmo mode (/matgizmo)'));
    elHelpBody.appendChild(keys);

    var grid = document.createElement('div'); grid.className = 'help-grid';
    CMD_GROUPS.forEach(function (g) {
        var card = document.createElement('div'); card.className = 'help-card';
        var h = document.createElement('div'); h.className = 'help-card-t'; h.textContent = g.name;
        card.appendChild(h);
        g.cmds.forEach(function (c) {
            var row = document.createElement('div'); row.className = 'help-cmd';
            var code = document.createElement('code'); code.textContent = c[0];
            var d = document.createElement('span'); d.textContent = c[1];
            row.appendChild(code); row.appendChild(d); card.appendChild(row);
        });
        grid.appendChild(card);
    });
    elHelpBody.appendChild(grid);
    helpBuilt = true;
}

function helpShow() {
    if (!helpBuilt) buildHelp();
    if (!elHelp) return;
    activityHide();          // only one overlay at a time, whatever opened it
    helpOpen = true;
    elHelp.classList.remove('hidden');
    elHelp.setAttribute('aria-hidden', 'false');
    elHelpBody.scrollTop = 0;
}
function helpHide() {
    if (!elHelp || !helpOpen) return;
    helpOpen = false;
    elHelp.classList.add('hidden');
    elHelp.setAttribute('aria-hidden', 'true');
}
function helpToggle() { if (helpOpen) helpHide(); else helpShow(); }

// --- activity log ---------------------------------------------------------
var activityLog = [];        // [{ts, msg, kind}, ...] oldest-first (from client Lua)
var activityOpen = false;
var elActivity, elLogBody, elLogFilter;

function pad2(n) { return (n < 10 ? '0' : '') + n; }
function clockOf(ts) {
    // ts is a unix time (seconds) from os.time(); render local HH:MM:SS.
    var d = new Date((Number(ts) || 0) * 1000);
    return pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds());
}

function renderActivity(filter) {
    if (!elLogBody) return;
    elLogBody.textContent = '';
    var q = norm(filter || '');
    // Newest first.
    var rows = [], any = false;
    for (var i = activityLog.length - 1; i >= 0; i--) {
        var e = activityLog[i];
        if (q && norm(e.msg).indexOf(q) === -1) continue;
        any = true;
        var row = document.createElement('div');
        row.className = 'log-row k-' + (e.kind || 'inform');
        var t = document.createElement('span'); t.className = 'log-t'; t.textContent = clockOf(e.ts);
        var dot = document.createElement('span'); dot.className = 'log-dot';
        var m = document.createElement('span'); m.className = 'log-m'; m.textContent = e.msg;
        row.appendChild(t); row.appendChild(dot); row.appendChild(m);
        rows.push(row);
    }
    if (!any) {
        elLogBody.appendChild(emptyState(
            activityLog.length ? 'No matching events' : 'No activity yet',
            activityLog.length ? 'Clear the filter to see everything.' : 'Actions you take in the editor show up here.'));
        return;
    }
    var frag = document.createDocumentFragment();
    for (var r = 0; r < rows.length; r++) frag.appendChild(rows[r]);
    elLogBody.appendChild(frag);
}

function onActivity(log) {
    if (Array.isArray(log)) activityLog = log;
    elActivity = document.getElementById('activityOverlay');
    elLogBody = document.getElementById('logBody');
    elLogFilter = document.getElementById('logFilter');
    renderActivity(elLogFilter ? elLogFilter.value : '');
}
function activityShow(log) {
    onActivity(log);
    if (!elActivity) return;
    helpHide();              // only one overlay at a time, whatever opened it
    activityOpen = true;
    elActivity.classList.remove('hidden');
    elActivity.setAttribute('aria-hidden', 'false');
    elLogBody.scrollTop = 0;
}
function activityHide() {
    if (!elActivity || !activityOpen) return;
    activityOpen = false;
    elActivity.classList.add('hidden');
    elActivity.setAttribute('aria-hidden', 'true');
}

// --- events ---------------------------------------------------------------
var searchTimer = null;
el.search.addEventListener('input', function (e) {
    clearTimeout(searchTimer);
    var v = e.target.value;
    searchTimer = setTimeout(function () { runSearch(v); }, 110);
});
el.clear.addEventListener('click', function () { el.search.value = ''; runSearch(''); el.search.focus(); });
el.close.addEventListener('click', function () { hide(); post('close'); });

var helpBtn = document.getElementById('help');
if (helpBtn) helpBtn.addEventListener('click', function () { helpToggle(); });
var helpCloseBtn = document.getElementById('helpClose');
if (helpCloseBtn) helpCloseBtn.addEventListener('click', function () { helpHide(); });
var logCloseBtn = document.getElementById('logClose');
if (logCloseBtn) logCloseBtn.addEventListener('click', function () { activityHide(); });
var logFilterInput = document.getElementById('logFilter');
if (logFilterInput) logFilterInput.addEventListener('input', function (e) { renderActivity(e.target.value); });

var detailBackBtn = document.getElementById('detailBack');
if (detailBackBtn) detailBackBtn.addEventListener('click', function () { closeDetail(); });
var detailSpawnBtn = document.getElementById('detailSpawn');
if (detailSpawnBtn) detailSpawnBtn.addEventListener('click', function () {
    if (detailMode === 'kit') { if (detailKitName) stampKit(detailKitName); }
    else if (detailModelName) spawn(detailModelName);
});
if (el.detailFav) el.detailFav.addEventListener('click', function () {
    if (detailMode !== 'prop' || !detailModelName) return;
    toggleFav(detailModelName);
    el.detailFav.classList.toggle('on', isFav(detailModelName));
});

// True while any typing field has focus, so single-key shortcuts (H/L) don't
// fire while the user is typing a query or a log filter.
function typing() {
    var a = document.activeElement;
    return a && (a === el.search || a === logFilterInput || a.tagName === 'INPUT');
}

document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') {
        // Escape backs out of an open overlay / detail first, then closes the browser.
        if (helpOpen) { helpHide(); return; }
        if (activityOpen) { activityHide(); return; }
        if (detailOpen) { closeDetail(); return; }
        hide(); post('close'); return;
    }
    if (typing()) return;
    if (e.key === 'h' || e.key === 'H') { e.preventDefault(); if (activityOpen) activityHide(); helpToggle(); }
    else if (e.key === 'l' || e.key === 'L') { e.preventDefault(); if (helpOpen) helpHide(); if (activityOpen) activityHide(); else activityShow(); }
});

window.addEventListener('message', function (e) {
    var d = e.data || {};
    if (d.action === 'open') { show(d.groups); if (d.help) helpShow(); if (d.activity) activityShow(d.activity); }
    else if (d.action === 'help') { if (el.app.classList.contains('hidden')) show(groups); helpShow(); }
    else if (d.action === 'activity') { if (el.app.classList.contains('hidden')) show(groups); activityShow(d.log); }
    // A prop was spawned from a slash command (/prop, /matnext, browser click):
    // record it for the Recent view even while the browser is closed. pushRecent
    // dedupes, so the browser-click path double-firing this is harmless.
    else if (d.action === 'recent') { if (typeof d.model === 'string') pushRecent(d.model); }
    else if (d.action === 'kits') onKits(d.kits);
    else if (d.action === 'scene') onScene(d.props, d.lights);
    else if (d.action === 'live') onLive(d.props);
    else if (d.action === 'close') hide();
    else if (d.action === 'thumb') onThumb(d.model, d.data);
});

loadPrefs();
