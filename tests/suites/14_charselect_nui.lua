-- ============================================================================
-- 14_charselect_nui.lua — palm6_charselect's NUI
--
-- These are TEXT assertions over the shipped HTML/CSS/JS, not behaviour tests
-- (fengari runs Lua, not a browser). They exist because every defect pinned
-- here was invisible to code review and only showed up when the page was
-- actually rendered in a browser — and each one would ship silently again if
-- the line came back.
--
-- 1. [hidden] MUST WIN. `.create-panel` is position:fixed inset:0 with
--    display:flex and pointer-events:auto. The UA's `[hidden]{display:none}`
--    has the weakest specificity in CSS, so the class rule beat it and the
--    "hidden" create panel was a full-viewport invisible sheet lying on top
--    of everything. Measured in Chrome: document.elementFromPoint() at the
--    centre of a character card returned #createPanel, not the card. THE
--    ENTIRE CHARACTER-SELECT SCREEN WAS UNCLICKABLE, and there is no ESC
--    path off it by design — a player could not select a character at all.
--
-- 2. The qbx_core field shape. The NUI read char.firstname / char.lastname /
--    char.playtime / char.lastPlayed. None of those are fields qbx_core
--    returns (server/storage/players.lua: charinfo/money/job/gang are decoded
--    tables, and last-played is `lastLoggedOut` in UNIX SECONDS). Every card
--    rendered "Unnamed / Never played", and delete was impossible because the
--    type-to-confirm word came from the same missing field.
--
-- 3. The devtools preview stub has to use the REAL shape. The old stub
--    invented the same non-existent fields, which is exactly why nobody
--    caught #2 — the stub agreed with the code instead of with the API.
-- ============================================================================

T.begin('palm6_charselect NUI — the defects that only showed up rendered')

local CSS  = 'resources/[custom]/palm6_charselect/html/style.css'
local JS   = 'resources/[custom]/palm6_charselect/html/script.js'
local HTML = 'resources/[custom]/palm6_charselect/html/index.html'

local css, js, html = T.source(CSS), T.source(JS), T.source(HTML)

--- The source with FULL-LINE `//` comments removed.
---
--- Three separate assertions in this session's suites passed or failed for the
--- wrong reason because they matched the prose in a comment rather than the
--- code it describes - including one that stayed green when the behaviour it
--- guarded was deliberately broken. Comments here deliberately quote the exact
--- expressions being asserted against ("this used to read char.playtime"),
--- which makes a naive `notcontains` on the shipped text useless.
---
--- Only lines that are ENTIRELY a comment are dropped. Trailing `//` is left
--- alone on purpose: stripping it would also eat the `https://` inside real
--- fetch URLs in this file, and over-stripping turns a notcontains into a
--- false pass, which is the failure mode being fixed.
--- @param commentPrefix string the LANGUAGE's line-comment token. This takes
--- the token rather than assuming `//` because the one-argument version of
--- this helper was handed a Lua file and silently stripped nothing - so an
--- assertion went on matching the `--` comment that quoted the very expression
--- it was asserting the absence of. Same helper shape as 15_appearance_nui.lua.
local function codeOnly(source, commentPrefix)
    local pattern = '^%s*' .. commentPrefix:gsub('%p', '%%%0')
    local out = {}
    for line in (source .. '\n'):gmatch('([^\n]*)\n') do
        if not line:match(pattern) then out[#out + 1] = line end
    end
    return table.concat(out, '\n')
end

local jsCode = codeOnly(js, '//')

-- ---------------------------------------------------------------------------
T.section('the hidden-attribute defeat that made the screen unclickable')
-- ---------------------------------------------------------------------------

T.contains('the stylesheet forces [hidden] to win over any display rule',
    css, '[hidden] { display: none !important; }')

-- The reason that rule has to exist: these two are full-viewport, clickable,
-- and hidden by attribute alone. If either stops being display:flex the rule
-- is still harmless; if the rule goes, they swallow every click again.
T.contains('the create panel is still a full-viewport fixed overlay',
    css, '.create-panel {')
T.contains('...that is still display:flex (which is what defeated [hidden])',
    css, '  display: flex;')
T.contains('the create panel is still hidden by ATTRIBUTE in the markup',
    html, 'id="createPanel" class="create-panel" hidden')
T.contains('the delete panel is too',
    html, 'id="deletePanel" class="create-panel" hidden')

-- ---------------------------------------------------------------------------
T.section('qbx_core character shape — the fields that actually exist')
-- ---------------------------------------------------------------------------

T.contains('names are read from charinfo, not off the character root',
    js, 'charinfoOf(char).firstname')

T.notcontains('the old top-level firstname read is gone from the live code',
    jsCode, 'char.firstname ||')

T.contains('last-played is read from lastLoggedOut',
    js, 'formatLastPlayed(char.lastLoggedOut)')

T.contains('...and converted from UNIX SECONDS to milliseconds',
    js, 'unixSeconds * 1000')

-- Playtime is BACK, but from a different source. The original assertion here
-- was `notcontains 'formatPlaytime'`, written when the hardcoded card line was
-- removed because qbx_core tracks no playtime anywhere. That is still true of
-- qbx_core - so the number now comes from this resource's OWN
-- palm6_charselect_playtime table, keyed by the same ownership-checked
-- citizenid list as the appearance lookup. What must never come back is
-- reading it off the character object qbx_core returns.
T.notcontains('playtime is never read off the qbx_core character object',
    jsCode, 'char.playtime')
T.contains('...it comes from this resource\'s own per-citizenid map',
    js, 'playtimeByCitizenid[char.citizenid]')
T.contains('the server owns its own playtime table',
    T.source('resources/[custom]/palm6_charselect/server/main.lua'),
    'CREATE TABLE IF NOT EXISTS `palm6_charselect_playtime`')

-- The delete gate: the confirm word must come from a field that exists, or
-- the submit button can never unlock.
T.contains('the delete confirm word comes from the real name accessor',
    js, 'const first = firstNameOf(char) || "this character";')

-- ---------------------------------------------------------------------------
T.section('the devtools stub must agree with the API, not with the code')
-- ---------------------------------------------------------------------------

T.contains('the preview stub uses a real nested charinfo table',
    js, 'charinfo: { firstname: "Jordan"')
T.contains('the preview stub uses a real money table',
    js, 'money: { cash: 1240, bank: 18650 }')
T.contains('the preview stub uses lastLoggedOut in seconds',
    js, 'lastLoggedOut: Math.floor(Date.now() / 1000)')

-- ---------------------------------------------------------------------------
T.section('layout invariants — the centre belongs to the character')
-- ---------------------------------------------------------------------------

-- The rebuild's whole premise: this page is a transparent surface over the
-- live game view and the ped stands in the middle of the frame. If the centre
-- column ever takes pointer-events or gets a background, it is covering the
-- character again — which is what the previous card-grid layout did.
T.contains('the centre column exists', css, '.ped-slot {')
T.contains('...and does not take pointer events', css, '  pointer-events: none;')
T.contains('the page itself is transparent over the game view',
    css, 'background: transparent !important;')

-- A commit fade that is silently outranked by a filled entrance animation is
-- the same defect shape as #1: a rule that reads correctly and does nothing.
T.contains('the commit state cancels the entrance animations it has to override',
    css, '  animation: none;')

-- ---------------------------------------------------------------------------
T.section('the error toast cannot cover an interactive control')
-- ---------------------------------------------------------------------------
--
-- It sat at `bottom: 6vh`, which is clear of the action bar at 1080p and lands
-- directly on "Delete Character" at 720p - measured in an emulated 1280x720
-- viewport: banner 634-673 over a button at 630-667. It is pointer-events:none
-- so it never blocked the click, but an error message covering an interactive
-- control is still wrong, and 1280x720 is a real FiveM resolution.
T.contains('the error banner is anchored to the TOP of the screen', css, '  top: 11vh;')
T.notcontains('...not above the action bar', css, '  bottom: 6vh;')
T.contains('it still never eats a click', css, '  pointer-events: none;')

-- ---------------------------------------------------------------------------
T.section('playtime — server-owned, and never silently discarded')
-- ---------------------------------------------------------------------------

local server = T.source('resources/[custom]/palm6_charselect/server/main.lua')
local serverCode = codeOnly(server, '--')   -- comments here quote these very calls

-- The clock starts where the server has CONFIRMED the login, not where a
-- client claims one. Anchored inside confirmSelect rather than anywhere in the
-- file.
local confirmBody = T.slice(
    'resources/[custom]/palm6_charselect/server/main.lua',
    "RegisterNetEvent('palm6_charselect:confirmSelect'",
    "RegisterNetEvent('palm6_charselect:confirmCreate'")
T.contains('a play session starts on the server-confirmed login',
    confirmBody, 'sessions[src] = { citizenid = citizenid, since = os.time() }')

-- ORDER: bank the old session BEFORE replacing it. Server ids are reused and a
-- player can switch character without disconnecting; overwriting discards
-- everything the previous character accrued since its last flush.
local flushAt = confirmBody:find('\n    flushSession(src, false)', 1, true)
local startAt = confirmBody:find('\n    sessions[src] = {', 1, true)
T.istrue('an existing session is banked BEFORE a new one replaces it',
    flushAt ~= nil and startAt ~= nil and flushAt < startAt)

-- THE CITIZENID IS THE SERVER'S, NOT THE CLIENT'S.
--
-- confirmSelect used to take the citizenid as an event argument and write it
-- into palm6_charselect_playtime having proved only that SOME character was
-- loaded. Every other write in this resource goes through
-- Bridge.OwnsCharacter/FilterOwned; this was the one that gated nothing, and
-- the unchecked length reached a VARCHAR(50) column via a bare
-- MySQL.query.await on the flush thread.
T.contains('confirmSelect reads the citizenid off qbx_core, not off the payload',
    confirmBody, 'local citizenid = Bridge.GetLoadedCitizenId(src)')
T.contains('...and therefore takes no argument at all',
    confirmBody, "RegisterNetEvent('palm6_charselect:confirmSelect', function()")
T.contains('Bridge.GetLoadedCitizenId reads qbx_core PlayerData',
    codeOnly(T.source('resources/[custom]/palm6_charselect/bridge/sv_framework.lua'), '--'),
    'player.PlayerData.citizenid')

-- D15: a brand new character's first session used to bank as zero, because
-- sessions[src] is only ever written by a confirm handler and the create path
-- fired none. It also proceeded into the teardown, the appearance editor and a
-- spawn without any proof the qbx_core login had taken.
local createConfirmBody = T.slice(
    'resources/[custom]/palm6_charselect/server/main.lua',
    "RegisterNetEvent('palm6_charselect:confirmCreate'",
    "RegisterNetEvent('palm6_charselect:deleteCharacter'")
T.contains('a newly created character starts a session too',
    createConfirmBody, 'sessions[src] = { citizenid = citizenid, since = os.time() }')
T.contains('...proved the same way, off qbx_core',
    createConfirmBody, 'local citizenid = Bridge.GetLoadedCitizenId(src)')
T.contains('...and answers with its own event, not the select cinematic',
    createConfirmBody, "TriggerClientEvent('palm6_charselect:createAccepted', src)")
T.contains('the create path asks for that confirmation',
    codeOnly(T.source('resources/[custom]/palm6_charselect/client/main.lua'), '--'),
    "TriggerServerEvent('palm6_charselect:confirmCreate')")

-- D14a: flushSession yields on the DB write. Anything landing during that await
-- re-reads the same session.since and issues a second identical credit, which
-- a burst of confirm events makes client-triggerable. The bookkeeping has to be
-- advanced BEFORE the write, not after it.
local flushBody = T.slice(
    'resources/[custom]/palm6_charselect/server/main.lua',
    'local function flushSession(src, keepOpen)',
    "AddEventHandler('playerDropped'")
local advanceAt = flushBody:find('sessions[src] = nil', 1, true)
local writeAt = flushBody:find('Bridge.AddPlaytime(session.citizenid, elapsed)', 1, true)
T.istrue('the session is closed BEFORE the yielding write, not after',
    advanceAt ~= nil and writeAt ~= nil and advanceAt < writeAt)

-- D14b: flushSession yields, so traversing `sessions` with pairs() while it
-- mutates is undefined per the Lua manual - confirmSelect inserts a key and
-- playerDropped deletes one. The thread dying loses every player's unbanked
-- time, which is why it is also pcall'd.
T.notcontains('the periodic flush does not traverse a table it mutates mid-yield',
    serverCode, 'for src in pairs(sessions) do\n            flushSession')
T.contains('...it iterates a key snapshot instead',
    serverCode, 'for src in pairs(sessions) do srcs[#srcs + 1] = src end')
T.contains('...and one bad flush cannot kill the thread',
    serverCode, 'local ok, err = pcall(flushSession, src, true)')

-- The audit enforces this too, but it is worth failing here with a reason.
T.notcontains('no onResourceStop flush — MySQL .await must not be reachable from one',
    serverCode, "AddEventHandler('onResourceStop'")

T.contains('the periodic flush exists, since a crash never fires playerDropped',
    serverCode, 'Wait(Config.PlaytimeFlushIntervalMs)')
T.contains('...and disconnect banks the session',
    serverCode, "AddEventHandler('playerDropped'")

-- ---------------------------------------------------------------------------
T.section('TIER 0 — the four that break the server for everyone')
-- ---------------------------------------------------------------------------
--
-- All four came out of a multi-agent adversarial audit and every one of them
-- was reachable on the ordinary join path.

local bridge = T.source('resources/[custom]/palm6_charselect/bridge/cl_game.lua')
local bridgeCode = codeOnly(bridge, '--')
local clientLua = T.source('resources/[custom]/palm6_charselect/client/main.lua')
local clientCode = codeOnly(clientLua, '--')

-- D1. A solo tutorial session instances the player into their OWN network
-- session: while it is open they cannot see, or be seen by, anyone else. It
-- was started on every join path and ended nowhere in the repo, so every
-- player was permanently invisible to every other player.
T.contains('the solo tutorial session is ENDED, not just started',
    bridgeCode, 'NetworkEndTutorialSession()')
T.contains('...and the invincibility window is bounded by wall clock, not by waiting on it',
    bridgeCode, 'while waited < cfg.invincibleMs do')
T.notcontains('...so it never again waits for something to end a session nothing ends',
    bridgeCode, 'while NetworkIsInTutorialSession()')

-- D2. A fresh freemode ped has no component variation - it is the bare body.
-- Wardrobe.CaptureAll then captured "naked" and applyToRealPlayer wrote it
-- back on every join forever.
T.contains('the creator preview ped is dressed before anything captures it',
    codeOnly(T.source('resources/[custom]/palm6_appearance/bridge/cl_game.lua'), '--'),
    'SetPedDefaultComponentVariation(ped)')

-- D3. Taking the screen over must not depend on the fallible qbx_core call:
-- returning early with the FiveM loading screen still up hid the error toast
-- AND left the player unspawned, with the admin bail-out unable to help.
T.contains('the screen is taken over before the qbx_core round trip',
    clientCode, 'local function takeOverScreen()')
local takeoverAt = clientCode:find('\n    takeOverScreen()', 1, true)
local fetchAt = clientCode:find('local ok, characters, maxSlots = Game.GetCharacters()', 1, true)
T.istrue('...literally before it, not after',
    takeoverAt ~= nil and fetchAt ~= nil and takeoverAt < fetchAt)
T.contains('the admin bail-out also closes the loading screen',
    clientCode, 'Game.ShutdownLoadingScreen()\n    SetNuiFocus(false, false)')

-- D4. A soft delete does NOT free a qbx_core slot. The old arithmetic claimed
-- it did and self-cancelled at cap: deleting every character produced
-- "0 / 0 slots" with create disabled, nothing to play, focus held, no cancel -
-- and it survived rejoins.
T.notcontains('the slot count no longer pretends a soft delete frees a slot',
    clientCode, 'math.max(maxSlots - hiddenCount, #visible)')
T.contains('...it reports what is actually consumed',
    clientCode, 'local usedSlots = #visible + hiddenCount')
T.contains('...and the NUI disables create off that, not off the visible count',
    jsCode, 'const slotsFull = usedSlots >= currentMaxSlots;')

-- ---------------------------------------------------------------------------
T.section('security — no client string reaches a native unchecked')
-- ---------------------------------------------------------------------------

-- The NUI asks for sounds by KEY; client/main.lua maps the key through its
-- own table. Same rule that fixed palm6_radialmenu's dispatch.
T.contains('the sound callback is allowlisted on the Lua side',
    T.source('resources/[custom]/palm6_charselect/client/main.lua'),
    'local UI_SOUNDS = {')
T.contains('...and the native only ever sees a value from that table',
    T.source('resources/[custom]/palm6_charselect/client/main.lua'),
    'local soundName = UI_SOUNDS[data and data.name]')

-- Character names are player-typed and land in this DOM.
T.notcontains('the NUI never assigns innerHTML from character data',
    jsCode, '.innerHTML = `')

-- ---------------------------------------------------------------------------
T.section('one character on the stage, and it is the focused one')
-- ---------------------------------------------------------------------------
--
-- Two things decided who stood on the stage and they disagreed on any mixed
-- roster. The NUI focused card 1 while Lua staged previewable[1] - the first
-- character WITH an appearance, not the first CARD - so character 1's initials
-- medallion and "No saved appearance" note were painted over character 2's
-- live ped. Moving focus onto a character without an appearance posted
-- nothing at all, so the previous ped stayed lit while the nameplate and rail
-- switched: one character's body under another character's name.

T.contains('focus always tells Lua, previewable or not',
    jsCode, 'post("previewCharacter", { citizenid });')
T.notcontains('...it is no longer gated on the previewable set',
    jsCode, 'if (previewableIds.has(citizenid)) post("previewCharacter"')
T.contains('the NUI remembers what it last ASKED for', jsCode, 'stageRequestId = citizenid;')
T.contains('...and ignores an answer for anything else',
    jsCode, 'if (data.citizenid !== stageRequestId) break;')
T.contains('once previewability is known, the focused character is re-requested',
    jsCode, 'post("previewCharacter", { citizenid: focusedCitizenid });')

T.contains('Lua answers "nothing to show" instead of staying silent',
    clientCode, "SendNUIMessage({ action = 'stage', citizenid = citizenid, live = false })")
T.contains('...and destroys the ped that is no longer wanted',
    clientCode, 'Game.DestroyStagePed()')
T.notcontains('Lua no longer picks a character to stage by itself',
    clientCode, 'if previewable[1] then showOnStage(previewable[1]) end')

-- A re-render (after a delete) left the deleted character standing spotlit
-- next to "Create your first character": renderCharacters never touched
-- has-stage, and the only other thing that clears it is `hide`.
local renderBody = T.slice(
    'resources/[custom]/palm6_charselect/html/script.js',
    '  function renderCharacters(characters, maxSlots, nameRules, slotInfo) {',
    '  function openCreatePanel(')
T.contains('a re-render clears the stage first', renderBody, 'overlay.classList.remove("has-stage");')
T.contains('an emptied roster tells Lua to clear the ped', renderBody, 'post("clearStage", {});')
T.contains('...and Lua has that callback', clientCode, "RegisterNUICallback('clearStage', function(_, cb)")

-- ---------------------------------------------------------------------------
T.section('an in-flight stage spawn cannot outlive the scene')
-- ---------------------------------------------------------------------------
--
-- Game.SetStageCharacter yields twice - a ground probe (up to 2s while
-- collision streams in around a freshly connected client) and a model load (up
-- to 5s). Hit PLAY inside that window and teardown ran DestroyStagePed while
-- stagePed was still nil, then the suspended spawn resumed and created its ped
-- into a scene that no longer existed. Nothing destroyed it afterwards
-- (onResourceStop's cleanup is gated on isOpen, false by then), leaving a
-- frozen invincible clone near the spawn point plus a Wait(0) turntable thread
-- whose own generation guard could never go false.

T.contains('the caller\'s token is passed INTO the bridge, not only checked around it',
    clientCode, 'local ok = Game.SetStageCharacter(citizenid, appearance.model, appearance, function()')
T.contains('the bridge takes it', bridgeCode, 'function Game.SetStageCharacter(citizenid, modelName, appearance, isCancelled)')
T.contains('...and combines it with "the scene is gone", which a token cannot express',
    bridgeCode, 'return sceneTornDown or (isCancelled ~= nil and isCancelled())')
T.contains('every teardown path sets that flag', bridgeCode, 'sceneTornDown = true')
T.contains('...and SetupScene clears it', bridgeCode, 'sceneTornDown = false')
T.contains('the ground probe is re-checked after', bridgeCode, 'if cancelled() then return false end   -- probeGroundZ yields for up to 2s')
T.contains('the model wait is re-checked inside the loop',
    bridgeCode, 'if cancelled() then SetModelAsNoLongerNeeded(hash); return false end')
T.contains('the turntable thread also exits on teardown',
    bridgeCode, 'while myGeneration == turntableGeneration and not sceneTornDown and ped and DoesEntityExist(ped) do')

-- ORDER: the final cancellation check must come AFTER the ped is registered in
-- `stagePed`, or DestroyStagePed cannot reach the handle and the ped is
-- orphaned - which is the original bug with an extra step.
local stageBody = T.slice(
    'resources/[custom]/palm6_charselect/bridge/cl_game.lua',
    'function Game.SetStageCharacter(citizenid, modelName, appearance, isCancelled)',
    'function Game.DestroyStagePed()')
local registerAt = stageBody:find('stagePed = ped', 1, true)
local finalCheckAt = stageBody:find('if cancelled() then\n        Game.DestroyStagePed()', 1, true)
T.istrue('the ped is registered BEFORE the final cancellation check',
    registerAt ~= nil and finalCheckAt ~= nil and registerAt < finalCheckAt)

-- ---------------------------------------------------------------------------
T.section('the admin bail-out rescues instead of making it worse')
-- ---------------------------------------------------------------------------
--
-- forceRelease ran SetNuiFocus(false,false) + TeardownScene unconditionally
-- with no coordination with palm6_appearance. The likeliest moment to need it
-- is mid-creation, which is inside THAT resource: NUI focus and
-- RenderScriptCams are per-client and global, so the rescue stripped the
-- editor's cursor and camera while it still rendered full-screen - and create
-- mode has no cancel or Escape. It also never spawned, while autospawn was
-- disabled at boot.

T.contains('the editor is closed before focus is touched',
    clientCode, 'pcall(function() exports.palm6_appearance:forceCloseEditor() end)')

local releaseBody = T.slice(
    'resources/[custom]/palm6_charselect/client/main.lua',
    "RegisterNetEvent('palm6_charselect:forceRelease', function(loaded)",
    "RegisterNUICallback('selectCharacter'")
local editorAt = releaseBody:find('forceCloseEditor', 1, true)
local focusAt = releaseBody:find('SetNuiFocus(false, false)', 1, true)
T.istrue('...strictly before, not merely nearby', editorAt ~= nil and focusAt ~= nil and editorAt < focusAt)

-- Whether qbx_core has a player object decides what the rescue may DO, and
-- only the server can answer it. Spawning fires QBCore:*:OnPlayerLoaded, which
-- seven other palm6_* resources act on - it must never fire for a client with
-- no character.
T.contains('the server tells the client whether a character is loaded',
    T.source('resources/[custom]/palm6_charselect/server/main.lua'),
    "TriggerClientEvent('palm6_charselect:forceRelease', targetId, loaded)")
T.contains('a loaded player gets spawned, which is what finishes the rescue',
    releaseBody, 'Game.SpawnAtPosition(Config.DefaultSpawn)')
T.contains('...and one with no character is put back into charselect instead',
    releaseBody, 'requestCharSelect()')

T.done()
