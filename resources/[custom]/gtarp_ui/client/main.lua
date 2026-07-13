-- ---------------------------------------------------------------------------
-- gtarp_ui - shared panel renderer
-- ---------------------------------------------------------------------------
-- The gtarp civic/economy resources are server-only. Instead of each command
-- dumping several lines into chat (only ~5 visible, unreadable once players
-- talk), they send ONE payload here and we render it as a single ox_lib panel:
--   * a single informational line  -> a toast (lib.notify)
--   * multiple lines               -> a scrollable context menu (lib.showContext)
-- ox_lib manages the NUI focus and ESC-to-close itself, so there is no
-- focus-trap surface to babysit. Re-running a command overwrites the panel by
-- id, so repeat calls are safe.
--
-- Payload contract (frozen so gtarp_ui can later be swapped to a branded NUI
-- without touching the nine callers):
--   { tag = 'Gangs', color = { r, g, b }, lines = { 'line1', 'line2', ... } }
-- The first line may be a '=== Header ===' banner; if so it becomes the panel
-- title and is not repeated as a row. `color` is currently unused (ox_lib
-- default theme) and reserved for the Phase 2 branded renderer.
-- ---------------------------------------------------------------------------

local PANEL_ID = 'gtarp_ui_panel'

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

RegisterNetEvent('gtarp_ui:show', function(p)
    if type(p) ~= 'table' or type(p.lines) ~= 'table' then return end
    local lines = p.lines
    local tag = (type(p.tag) == 'string' and p.tag ~= '') and p.tag or 'Palm6'

    -- Count the lines that actually carry text.
    local textCount = 0
    local lastText
    for _, l in ipairs(lines) do
        if type(l) == 'string' and l:match('%S') then
            textCount = textCount + 1
            lastText = l
        end
    end
    if textCount == 0 then return end

    -- One line of content reads better as a toast than as a whole panel.
    if textCount == 1 then
        lib.notify({ title = tag, description = lastText, type = 'inform', position = 'top' })
        return
    end

    local title, bodyStart = extractTitle(lines, tag)
    local options = {}
    for i = bodyStart, #lines do
        local line = lines[i]
        if type(line) == 'string' and line:match('%S') then
            options[#options + 1] = { title = line, readOnly = true }
        end
    end
    -- If stripping the banner left only one row, fall back to a toast.
    if #options == 0 then
        lib.notify({ title = tag, description = title, type = 'inform', position = 'top' })
        return
    end

    local heading = (title == tag) and tag or (tag .. '  |  ' .. title)
    lib.registerContext({ id = PANEL_ID, title = heading, options = options })
    lib.showContext(PANEL_ID)
end)
