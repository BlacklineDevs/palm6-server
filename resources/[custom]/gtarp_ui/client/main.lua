-- ---------------------------------------------------------------------------
-- gtarp_ui - shared panel renderer (Palm6 branded NUI)
-- ---------------------------------------------------------------------------
-- The gtarp civic/economy resources are server-only. Instead of each command
-- dumping several lines into chat, they send ONE payload here and we render it:
--   * multiple lines    -> the branded NUI panel (web/), focus + ESC-to-close
--   * a single line     -> an ox_lib toast (no focus grab, never freezes the
--                          player for a one-liner)
-- Console (src 0) still prints server-side in each resource's Bridge.Reply;
-- NUI cannot target the server console, so that path is unchanged.
--
-- Payload contract (frozen - the nine callers never change):
--   { tag = 'Gangs', color = { r, g, b }, lines = { 'line1', 'line2', ... } }
-- The first line may be a '=== Header ===' banner; if so it becomes the panel
-- title and is dropped from the body rows.
-- ---------------------------------------------------------------------------

-- Pull a '=== Title ===' banner out of the first line if present.
-- Returns the title text and the row index the body should start from.
local function extractTitle(lines, fallback)
    local first = lines[1]
    if type(first) == 'string' then
        local cap = first:match('^%s*===%s*(.-)%s*===%s*$')
        if cap and cap ~= '' then
            return cap, 2
        end
    end
    return fallback, 1
end

-- {r,g,b} (0-255) -> "#RRGGBB". Defaults to Palm6 gold on bad input.
local function toHex(color)
    local r, g, b = 214, 169, 80
    if type(color) == 'table' then
        r = math.floor(tonumber(color[1]) or r)
        g = math.floor(tonumber(color[2]) or g)
        b = math.floor(tonumber(color[3]) or b)
    end
    local function clamp(v) return (v < 0 and 0) or (v > 255 and 255) or v end
    return ('#%02X%02X%02X'):format(clamp(r), clamp(g), clamp(b))
end

local panelOpen = false

local function closePanel()
    if not panelOpen then return end
    panelOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'hide' })
end

RegisterNetEvent('gtarp_ui:show', function(p)
    if type(p) ~= 'table' or type(p.lines) ~= 'table' then return end
    local lines = p.lines
    local tag = (type(p.tag) == 'string' and p.tag ~= '') and p.tag or 'Palm6'

    -- Count the lines that actually carry text, and remember the last one.
    local textCount, lastText = 0, nil
    for _, l in ipairs(lines) do
        if type(l) == 'string' and l:match('%S') then
            textCount = textCount + 1
            lastText = l
        end
    end
    if textCount == 0 then return end

    -- One line of content reads better as a non-blocking toast than a panel
    -- that would freeze the player just to show a single sentence.
    if textCount == 1 then
        lib.notify({ title = tag, description = lastText, type = 'inform', position = 'top' })
        return
    end

    -- Multi-line -> the branded NUI panel.
    local title, bodyStart = extractTitle(lines, tag)
    local rows = {}
    for i = bodyStart, #lines do
        local line = lines[i]
        if type(line) == 'string' then
            rows[#rows + 1] = line
        end
    end

    SendNUIMessage({
        action = 'show',
        tag    = tag,
        accent = toHex(p.color),
        title  = title,
        rows   = rows,
        single = false,
    })
    SetNuiFocus(true, true)
    panelOpen = true
end)

-- The NUI (close button or ESC) posts here; release focus and mark closed.
RegisterNUICallback('close', function(_, cb)
    panelOpen = false
    SetNuiFocus(false, false)
    cb('ok')
end)

-- Never leave a player stuck with a focused cursor if the resource stops
-- while a panel is open.
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and panelOpen then
        SetNuiFocus(false, false)
    end
end)
