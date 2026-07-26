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
    if (!list) return;
    awaiting[model] = null;
    for (var i = 0; i < list.length; i++) applyThumb(model, list[i].img, list[i].thumb, thumbData[model]);
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
    thumb.className = 'thumb loading';
    thumb.setAttribute('data-glyph', initials(model));
    var img = document.createElement('img');
    img.alt = '';
    thumb.appendChild(img);
    requestThumb(model, img, thumb);   // resolves from client Lua (CEF blocks the CDN)

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
    card.addEventListener('click', function () { spawn(model); });
    card.addEventListener('keydown', function (ev) {
        if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); spawn(model); }
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

function makeSpecialRow(id, label, icon, count, active) {
    var row = document.createElement('div');
    row.className = 'cat special' + (active ? ' active' : '');
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
        if (id === 'fav') selectFav(); else selectRecent();
    });
    return row;
}

function renderCats() {
    el.cats.textContent = '';

    // Pinned pseudo-categories: Favorites + Recent, always at the top.
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

// Restore whatever view was active before the user started typing a search.
function restoreBrowse() {
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

function show(g) {
    groups = Array.isArray(g) ? g : [];
    allModels = []; searchIndex = []; modelCat = {}; modelSet = {};
    groups.forEach(function (grp) {
        if (!grp || !Array.isArray(grp.models)) return;
        grp.models.forEach(function (m) {
            if (typeof m !== 'string') return;
            allModels.push(m);
            modelSet[m] = true;
            searchIndex.push([norm(m), m]);
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
    setTimeout(function () { el.search.focus(); }, 30);
}
function hide() { el.app.classList.add('hidden'); el.app.setAttribute('aria-hidden', 'true'); helpHide(); activityHide(); }

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

// True while any typing field has focus, so single-key shortcuts (H/L) don't
// fire while the user is typing a query or a log filter.
function typing() {
    var a = document.activeElement;
    return a && (a === el.search || a === logFilterInput || a.tagName === 'INPUT');
}

document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') {
        // Escape backs out of an open overlay first, then closes the browser.
        if (helpOpen) { helpHide(); return; }
        if (activityOpen) { activityHide(); return; }
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
    else if (d.action === 'close') hide();
    else if (d.action === 'thumb') onThumb(d.model, d.data);
});

loadPrefs();
