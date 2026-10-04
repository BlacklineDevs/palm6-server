-- ============================================================================
-- 15_appearance_nui.lua — palm6_appearance's and palm6_radialmenu's NUI
--
-- Text assertions over the shipped HTML/CSS/JS (fengari runs Lua, not a
-- browser). Every defect pinned here was found by RENDERING the page for the
-- first time, and each would return silently if the line came back.
--
-- 1. THE SAVE BAR MUST BE PINNED. The creator panel was one flat scroll
--    containing every section at once — measured at 1885px of content in a
--    945px panel — with "Save & Continue" ~940px below the fold. Character
--    creation is a MANDATORY step with no cancel path, so the primary action
--    of the screen was reachable only by scrolling a panel that gave no hint
--    it scrolled.
--
-- 2. THE HAIR PALETTE MUST COME FROM THE GAME. The swatch grid painted itself
--    with a generated HSL rainbow, so swatch 10 rendered lime green while the
--    hair it selects is brown. GTA's 64 hair colours are blacks, browns,
--    blondes, greys and reds. The real values are read with
--    GET_PED_HAIR_RGB_COLOR and passed in — captured, never authored, the same
--    rule docs/CUSTOM-CLOTHING.md applies to drawable indices.
--
-- 3. EYE COLOURS ARE NOT COLOURS. They are texture variations with no rgb
--    getter, so any swatch colour shown for them would be invented.
--
-- 4. The radial hub printed its own title twice, because the breadcrumb was
--    the whole stack and the root stack is one element.
-- ============================================================================

T.begin('palm6_appearance / palm6_radialmenu NUI — what rendering the pages found')

local A_CSS  = 'resources/[custom]/palm6_appearance/html/style.css'
local A_JS   = 'resources/[custom]/palm6_appearance/html/script.js'
local A_HTML = 'resources/[custom]/palm6_appearance/html/index.html'
local A_LUA  = 'resources/[custom]/palm6_appearance/client/main.lua'
local A_BRIDGE = 'resources/[custom]/palm6_appearance/bridge/cl_game.lua'
local R_JS   = 'resources/[custom]/palm6_radialmenu/html/script.js'

local acss, ajs, ahtml = T.source(A_CSS), T.source(A_JS), T.source(A_HTML)
local alua = T.source(A_LUA)

--- Source with FULL-LINE `//` comments removed - see the same helper in
--- 14_charselect_nui.lua for why. Comments in these files quote the exact
--- expressions being asserted against, so a `notcontains` over the raw text
--- matches the documentation instead of the code. One assertion in this very
--- suite stayed green while the behaviour it guarded was deliberately broken,
--- for exactly that reason. Trailing `//` is left alone so real URLs survive.
--- @param commentPrefix string the LANGUAGE's line-comment token. Passing the
--- wrong one silently strips nothing, which is how an assertion against a Lua
--- file went on matching the `--` comment that quoted the very code it was
--- asserting the absence of.
local function codeOnly(source, commentPrefix)
    local pattern = '^%s*' .. commentPrefix:gsub('%p', '%%%0')
    local out = {}
    for line in (source .. '\n'):gmatch('([^\n]*)\n') do
        if not line:match(pattern) then out[#out + 1] = line end
    end
    return table.concat(out, '\n')
end

local ajsCode = codeOnly(ajs, '//')
local aluaCode = codeOnly(alua, '--')

-- ---------------------------------------------------------------------------
T.section('the save bar is pinned, not scrolled away')
-- ---------------------------------------------------------------------------

-- Structural: the save bar has to live OUTSIDE the scroll container. If it
-- ever moves back inside #panel-body it scrolls with the content again.
T.contains('the panel body is the only scroll container', acss, '.panel-body {')
T.contains('...and it is the thing that scrolls', acss, '  overflow-y: auto;')
T.contains('the panel itself does NOT scroll', acss, '  overflow: hidden;')
T.contains('the save bar refuses to shrink', acss, '  flex: 0 0 auto;              /* never shrinks, never scrolls away */')

-- The markup order is the real guarantee: </div> closing #panel-body must come
-- BEFORE the save bar footer.
local bodyClose = ahtml:find('</div><!-- /#panel-body -->', 1, true)
local saveBar = ahtml:find('id="save%-bar"')
T.istrue('#panel-body is closed before the save bar in the markup',
    bodyClose ~= nil and saveBar ~= nil and bodyClose < saveBar)

-- ---------------------------------------------------------------------------
T.section('section tabs replaced the flat mega-scroll')
-- ---------------------------------------------------------------------------

T.contains('the panel has section tabs', ahtml, 'id="panel-tabs"')
T.contains('...covering Face', ahtml, 'data-section="head-blend-panel"')
T.contains('...Wardrobe', ahtml, 'data-section="wardrobe-panel"')
T.contains('...Colors', ahtml, 'data-section="appearance-colors"')
T.contains('...and Tattoos', ahtml, 'data-section="tattoos-panel"')
T.contains('every open resets to the Face section', ajs, 'setActiveSection("head-blend-panel")')

-- Same landmine as palm6_charselect: sections are hidden by ATTRIBUTE, and
-- `[hidden]` loses to any class rule that sets display.
T.contains('[hidden] is forced to win here too', acss, '[hidden] { display: none !important; }')

-- ---------------------------------------------------------------------------
T.section('the hair palette is read from the game, not invented')
-- ---------------------------------------------------------------------------

T.contains('the bridge reads the real per-index hair rgb',
    T.source(A_BRIDGE), 'function Game.GetHairRgbPalette(count)')
T.contains('...via the game native', T.source(A_BRIDGE), 'GetPedHairRgbColor')
T.contains('...guarded so a build without it degrades instead of erroring',
    T.source(A_BRIDGE), 'if not GetPedHairRgbColor then return palette end')

-- Derived from Config.HairColorRange rather than a separate count constant:
-- two constants stating the same fact is the kind of pair that drifts the
-- moment one is edited.
T.contains('the palette is sent to the NUI on open',
    T.source(A_LUA), 'hairPalette = Game.GetHairRgbPalette(')
T.contains('...sized from the declared colour range, not a duplicate constant',
    T.source(A_LUA), 'Config.HairColorRange.max - Config.HairColorRange.min + 1')
T.notcontains('no second source of truth for the palette size',
    T.source('resources/[custom]/palm6_appearance/shared/config.lua'), 'Config.HairColorCount =')

-- The stub has to send what the real payload sends, or the browser preview
-- reflects the stub instead of the product. This is the exact failure that let
-- palm6_charselect render "Unnamed" on every card through two reviews.
T.contains('the preview stub sends the REAL face-feature labels',
    ajs, '"Nose Width", "Nose Peak Height"')
T.contains('...and overlayDefs carrying count/hasColor like the real payload',
    ajs, 'hasColor: true, count: 34')

T.contains('the NUI paints swatches from that palette', ajs, 'function hairSwatchColor(i)')
T.notcontains('the generated HSL rainbow is gone', ajsCode, 'function hslSwatch')
-- Asserting on the swatch-painting CALL rather than on the string "hsl(",
-- which also appears in the comment explaining what was removed. A test that
-- matches its own documentation is a test that fails for the wrong reason.
T.contains('swatch colour comes from the caller-supplied palette function',
    ajs, 'const paint = colorFor(i);')

-- ---------------------------------------------------------------------------
T.section('swatch grids take NAMED options, not positional args')
-- ---------------------------------------------------------------------------
--
-- This section exists because of a regression introduced while fixing the
-- palette. buildSwatchGrid was (container, total, selectedId, onSelect);
-- inserting a `colorFor` parameter ahead of `onSelect` silently repurposed the
-- overlay call site's callback. Building an overlay colour grid then CALLED
-- the apply-colour callback once per swatch - 192 spurious setHeadOverlayColor
-- posts on open across the three colour-capable overlays, every one of them
-- left on colour 63 - the swatches rendered blank white, and clicking one
-- threw "onSelect is not a function". Measured in a browser: 192 posts before,
-- 0 after.
--
-- Named options cannot be silently reordered. That is the actual fix; these
-- assertions keep it.

T.contains('buildSwatchGrid takes an options object', ajs, 'function buildSwatchGrid(container, opts)')
T.contains('...and refuses to build without an onSelect rather than throwing per-click',
    ajs, 'if (typeof onSelect !== "function")')
T.contains('...with colorFor optional and defaulting to no paint',
    ajs, 'typeof opts.colorFor === "function" ? opts.colorFor : () => null')

T.notcontains('no positional call site survives', ajsCode, 'buildSwatchGrid(colorGrid, 64,')
T.notcontains('...for the hair grid either', ajsCode, 'buildSwatchGrid(hairColorGrid, hairPalette.length || 64, hairColor,')

T.contains('the overlay colour grid paints from the same live hair palette it applies',
    ajs, 'colorFor: hairSwatchColor,')

-- ---------------------------------------------------------------------------
T.section('eye colours are not given invented colours')
-- ---------------------------------------------------------------------------

T.contains('eye swatches render as numbered index chips', ajs, 'chip.classList.add("swatch--index")')
T.contains('...and the style exists for them', acss, '.swatch--index {')

-- ---------------------------------------------------------------------------
T.section('Reset — create mode had no way back from a bad randomize')
-- ---------------------------------------------------------------------------
--
-- Character creation is MANDATORY and has no cancel button, so a player who
-- hit "Randomize All" and hated the result was stuck with it. Reset reverts
-- the ped to how the screen opened. Exactly one of Cancel/Reset shows: edit
-- mode can discard and leave, create mode cannot.

T.contains('the reset button exists', ahtml, 'id="reset-btn"')
T.contains('...and is hidden outside create mode', ajs, 'resetBtn.classList.toggle("mode-hidden", currentMode !== "create")')
T.contains('...with a style rule to hide it', acss, '#reset-btn.mode-hidden { display: none; }')

T.contains('the opening look is snapshotted for reset', alua, 'openingPayload = buildAppearancePayload()')
T.contains('there is a reset callback', alua, "RegisterNUICallback('reset'")
T.contains('...that re-applies the snapshot through the guarded apply path',
    alua, 'applySavedAppearance(previewPed, openingPayload)')

-- ORDER IS LOAD-BEARING. HeadBlend.Reset() zeroes every cached blend/feature/
-- overlay value, so running it AFTER the apply would wipe what was just
-- restored: the ped would show the reverted look while every slider snapped to
-- 0. openAppearanceScreen uses the same clear-then-apply order.
-- Anchored to the CALL as it appears in code (newline + indent), not to the
-- bare name: the explanatory comment above it also contains "HeadBlend.Reset()",
-- and a first attempt at this assertion matched that instead - it stayed green
-- when the order was deliberately inverted. A test that matches its own
-- documentation guards nothing. Trap-verified after the fix.
local resetBody = T.slice(A_LUA, "RegisterNUICallback('reset'", "RegisterNUICallback('cancel'")
local clearAt = resetBody:find('\n    HeadBlend.Reset()', 1, true)
local applyAt = resetBody:find('\n    if not applySavedAppearance(previewPed, openingPayload)', 1, true)
T.istrue('reset clears module state BEFORE re-applying, not after',
    clearAt ~= nil and applyAt ~= nil and clearAt < applyAt)

-- The save bar is a fixed 380px at every resolution; three buttons only fit on
-- one line with the tightened metrics. Without them the labels wrap.
T.contains('the save bar keeps its three buttons on one line', acss, '#save-bar .btn {')
T.contains('...by refusing to wrap', acss, '  white-space: nowrap;')

-- ---------------------------------------------------------------------------
T.section('audit batch 2 — wardrobe, colour and snapshot defects')
-- ---------------------------------------------------------------------------

local wardrobe = codeOnly(T.source('resources/[custom]/palm6_appearance/client/wardrobe.lua'), '--')

-- D7. A snapshot that shares storage with its subject is not a snapshot. The
-- getters return the module-local tables and edits mutate them in place, so
-- Reset replayed whatever the player had just done - and HeadBlend.Reset()
-- zeroes faceFeatures IN PLACE, zeroing the snapshot about to be applied.
T.contains('the appearance payload is deep-copied', aluaCode, 'local function deepCopy(value)')
T.contains('...and buildAppearancePayload actually returns a copy', aluaCode, 'return deepCopy({')

-- D6. Both hair grids closed over buildColorGrids' parameters, which are only
-- seeded at open - so picking a highlight posted the OPENING hair colour and
-- SetHairColor wrote both, snapping the hair back.
T.contains('hair colour state is module-scoped, not captured at open',
    ajsCode, 'let currentHairColor = 0;')
T.notcontains('...so the highlight handler no longer posts a stale hair colour',
    ajsCode, 'highlightColorId: hairHighlight }')

-- D11. "No hat" is a choice. The server deliberately preserves active=false
-- entries; only the worn branch existed, so removing a prop never stuck.
T.contains('a cleared prop is applied, not dropped', aluaCode, 'Game.ClearPedProp(ped, entry.id)')

-- D12. Returning false on the first invalid candidate walled the cursor into
-- whichever arc of the ring it started in, with no feedback.
T.contains('component cycling searches past invalid drawables', wardrobe, 'for _ = 1, count do')
T.contains('...and only gives up when the whole collection is unusable',
    wardrobe, 'if not nextDrawable then return false end')
T.contains('texture cycling does the same', wardrobe, 'for _ = 1, textureCount do')

-- D9. A fresh preview ped wears no props, so the cached state had no
-- collection name and every click returned false forever. RandomizeAll already
-- had this fallback; the cycle path did not.
T.contains('prop cycling resolves a collection when the ped wears none',
    wardrobe, 'local collectionName = current.collectionName or Game.GetPedPropCollectionName(ped, propId)')

-- D8. The single largest wardrobe gap: texture/colourway selection was
-- unreachable - a registered Lua callback with no caller, no UI, and a
-- hardcoded reset to texture 0 on every drawable change.
T.contains('the NUI renders a colourway row', ajsCode, 'const texCallback = kind === "prop" ? "cyclePropTexture" : "cycleTexture";')
T.contains('...shown only when there is more than one colourway',
    ajsCode, 'texRow.hidden = !(total > 1);')
T.contains('...and refreshed from the same wardrobeState message',
    ajsCode, 'if (row) updateTextureRow(row, payload);')
T.contains('the prop-texture callback now exists', aluaCode, "RegisterNUICallback('cyclePropTexture'")
-- The subrow sets display:flex and is hidden by ATTRIBUTE, so the [hidden]
-- override is what keeps it from becoming the unclickable-panel bug again.
T.contains('[hidden] still wins over the new subrow display rule',
    acss, '[hidden] { display: none !important; }')

-- ---------------------------------------------------------------------------
T.section('the QA command is not a free barbershop')
-- ---------------------------------------------------------------------------
--
-- /palm6appearance opens the editor on demand. It was registered CLIENT-side
-- with restricted=false - unrestricted, and unrestrictable, because an ACE
-- check only means anything on the server. That was harmless while the editor
-- was inert (applied nothing, saved nothing). Making the editor actually work
-- turned the same command into a free, unlimited barbershop for every player:
-- retype it, change your face, and it persists - bypassing any barbershop fee
-- or job-locked look a server might add later.

local aserver = T.source('resources/[custom]/palm6_appearance/server/main.lua')

T.contains('the command is registered on the SERVER', aserver, "RegisterCommand('palm6appearance'")
T.contains('...as restricted', aserver, "end, true) -- restricted=true: requires the command.palm6appearance ACE")
T.notcontains('the client no longer registers it at all',
    aluaCode, "RegisterCommand('palm6appearance'")
T.contains('the client only opens it via a server-sent event',
    alua, "RegisterNetEvent('palm6_appearance:client:openEditor'")

-- A restricted command with no add_ace line is runnable by group.owner and
-- nobody else - so the grant is part of the feature, not an afterthought.
T.contains('custom.cfg grants the ACE to admins',
    T.source('custom.cfg'), 'add_ace group.admin command.palm6appearance allow')

-- ---------------------------------------------------------------------------
T.section('radial hub — no more printing its own title twice')
-- ---------------------------------------------------------------------------

local rjs = T.source(R_JS)
T.contains('the breadcrumb is the ANCESTOR path, not the whole stack',
    rjs, 'const ancestors = stack.slice(0, -1)')
T.notcontains('the old whole-stack breadcrumb is gone',
    rjs, 'stack.map((n) => n.title || "").join(" / ")')
T.contains('at the root it shows the way out instead', rjs, '"Esc to close"')

-- ---------------------------------------------------------------------------
T.section('the editor opens on the character it is editing, or not at all')
-- ---------------------------------------------------------------------------
--
-- /palm6appearance called openAppearanceScreen directly with a nil payload, so
-- it skipped the stored-appearance load that lives in the export - the editor
-- opened on a DEFAULT freemode ped (parents 0/0/0, mix 0.5) that was not the
-- admin's character. One slider nudge plus Save captured that default and
-- upserted it over the real row, and Reset restored the same blank because
-- that is what the screen opened with. There is no undo past that.

T.contains('the re-edit path is one function, shared by both entry points',
    aluaCode, 'local function openEditorForExistingCharacter(genderKey, savedAppearance, onDone)')
T.contains('...the export is that function', aluaCode, "exports('openAppearanceEditor', openEditorForExistingCharacter)")
T.contains('...and so is the admin command\'s net event',
    aluaCode, 'openEditorForExistingCharacter(genderKey == \'female\' and \'female\' or \'male\', nil, function(appearanceTable)')
T.notcontains('the net event no longer opens the screen with a nil payload of its own',
    aluaCode, "openAppearanceScreen(genderKey == 'female' and 'female' or 'male', 'edit', nil,")

-- The apply's boolean used to be discarded. A refused payload left the player
-- editing a default ped whose first Save overwrote their real look.
T.contains('a refused apply refuses the open', aluaCode, 'if not applySavedAppearance(previewPed, savedAppearance) then')
T.contains('...and cleans up the ped it had already spawned', aluaCode, 'Game.DeletePed(previewPed)')

-- D20: the model stamp is what the apply path and its §5 guard key off, so it
-- has to be what the preview body keys off too. Keying the preview off
-- `gender` - the other, independently validated field - meant a row where the
-- two disagreed spawned the wrong body and then had its own apply silently
-- refused.
T.contains('the preview body is resolved from the payload\'s model stamp',
    aluaCode, 'local keyed = genderKeyForModel(savedAppearance.model)')
T.contains('...through the same two-model allowlist', aluaCode, 'local function genderKeyForModel(modelName)')
T.contains('...and an unrecognised model refuses the open rather than guessing',
    aluaCode, 'if not keyed then')
T.notcontains('the export no longer falls back to the payload\'s gender field',
    aluaCode, "or (type(savedAppearance) == 'table' and savedAppearance.gender)")

-- The charselect admin bail-out needs to close this editor before it touches
-- NUI focus - focus and RenderScriptCams are per-client and global.
T.contains('a force-close export exists for the rescue path', aluaCode, "exports('forceCloseEditor', function()")
T.contains('...and it drops the pending callback rather than resolving it',
    aluaCode, 'pendingCallback = nil')

-- ---------------------------------------------------------------------------
T.section('a refresh is not an open')
-- ---------------------------------------------------------------------------
--
-- Randomize, Randomize All and Reset all rebuild the controls, and all three
-- did it by re-sending `open` - which the NUI could not tell from a first
-- open, so it ran setActiveSection("head-blend-panel"): back to the Face tab,
-- scroll zeroed, and a setCameraFocus post that also reset the orbit distance.
-- All three buttons live in the pinned save bar, reachable from every tab, so
-- randomizing an outfit zoomed you to your face and hid the outfit controls.

T.contains('the NUI has a distinct refresh action', ajsCode, 'case "refresh":')
T.contains('...which rebuilds controls only', ajsCode, 'function rebuildControls(payload) {')
T.contains('...and preserves the scroll position across the rebuild',
    ajsCode, 'if (panelBody) panelBody.scrollTop = scrollTop;')

-- Only handleOpen may move the player. If this ever appears inside
-- rebuildControls/handleRefresh the bug is back.
local refreshBody = T.slice(A_JS, '  function handleRefresh(payload) {', '  function handleWardrobeState(payload) {')
T.notcontains('a refresh never switches section', refreshBody, 'setActiveSection(')
local rebuildBody = T.slice(A_JS, '  function rebuildControls(payload) {', '  function handleOpen(payload) {')
T.notcontains('...nor does the shared rebuild', rebuildBody, 'setActiveSection(')

T.contains('a first open still lands on Face', ajsCode, 'setActiveSection("head-blend-panel");')

-- Lua half: exactly one `open`, three `refresh`.
local _, openCount = aluaCode:gsub("action = 'open'", '')
local _, refreshCount = aluaCode:gsub("action = 'refresh'", '')
T.eq('exactly one message opens the screen', openCount, 1)
T.eq('the three rebuild paths all refresh instead', refreshCount, 3)

-- ---------------------------------------------------------------------------
T.section('the server sanitiser bounds the two lists that were unbounded')
-- ---------------------------------------------------------------------------
--
-- Every other field is bounded by construction (faceFeatures and overlays are
-- keyed writes, the scalars are range checks). components and props were
-- appended to with no cap and no de-dup, so 50,000 valid-looking entries all
-- carrying id 4 survived and landed in appearance_json LONGTEXT via a blocking
-- json.encode. A duplicate id is meaningless anyway - the apply overwrites.

local aserverCode = codeOnly(aserver, '--')
T.contains('components are keyed by id', aserverCode, 'componentsById[id] = {')
T.contains('...then flattened over the real id range', aserverCode, 'for id = 0, 11 do')
T.contains('props are keyed by id', aserverCode, 'propsById[id] = {')
T.contains('...then flattened over theirs', aserverCode, 'for id = 0, 7 do')
T.notcontains('nothing appends to the component list any more',
    aserverCode, 'clean.components[#clean.components + 1] = {')
T.notcontains('...nor to the props list', aserverCode, 'clean.props[#clean.props + 1] = {')

-- The load callback is the ONE client-reachable entry point palm6_eventguard
-- structurally cannot cover: it keys on literal net-event names, while an
-- ox_lib callback arrives on a transport event registered by a recipe resource
-- that starts before custom.cfg.
T.contains('the load callback rate-limits per source', aserverCode, 'if not loadCallAllowed(source) then return nil end')
T.contains('...on a real window', aserverCode, 'LOAD_LIMIT_WINDOW_SECONDS')
T.contains('...and forgets a player who left', aserverCode, 'loadHits[source] = nil')

T.done()
