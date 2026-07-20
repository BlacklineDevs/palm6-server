-- ============================================================================
-- palm6_business/client/main.lua
--
-- Menu flow only. Receives server snapshots (menuData / ledgerData) and the
-- hire/charge prompts, builds ox_lib menus via Game.* (bridge/cl_game.lua), and
-- sends intent back to the server. The server re-validates everything; the
-- client is pure presentation. No world coords/blips/peds in Phase 0.
-- ============================================================================

local lastData = nil

local function money(n) return ('$%s'):format(n or 0) end

-- ---------------------------------------------------------------------------
-- Register flow (no membership)
-- ---------------------------------------------------------------------------
local function doRegister(typeKey)
    local res = Game.InputDialog('Register a business', {
        { type = 'input', label = 'Business name', required = true, min = 3, max = 48 },
    })
    if not res or not res[1] then return end
    TriggerServerEvent('palm6_business:register', res[1], typeKey)
end

local function renderRegister(data)
    local opts = {}
    for _, t in ipairs(data.types or {}) do
        opts[#opts + 1] = {
            title = t.label,
            description = t.flavor,
            arrow = true,
            onSelect = function() doRegister(t.key) end,
        }
    end
    local cost = data.cfg and data.cfg.registrationCost or 0
    Game.OpenMenu('palm6_business_register', ('Start a business  ·  fee %s'):format(money(cost)), opts)
end

-- ---------------------------------------------------------------------------
-- Account submenu (owner)
-- ---------------------------------------------------------------------------
local function renderAccount(b)
    local opts = {
        { title = ('Balance: %s'):format(money(b.balance)), disabled = true },
        {
            title = 'Deposit', description = 'Move money from your bank into the business',
            onSelect = function()
                local r = Game.InputDialog('Deposit', { { type = 'number', label = 'Amount', required = true, min = 1 } })
                if r and r[1] then TriggerServerEvent('palm6_business:deposit', math.floor(r[1])) end
            end,
        },
        {
            title = 'Withdraw', description = 'Move money from the business to your bank',
            onSelect = function()
                local r = Game.InputDialog('Withdraw', { { type = 'number', label = 'Amount', required = true, min = 1 } })
                if r and r[1] then TriggerServerEvent('palm6_business:withdraw', math.floor(r[1])) end
            end,
        },
    }
    Game.OpenMenu('palm6_business_account', 'Account', opts, 'palm6_business_root')
end

-- ---------------------------------------------------------------------------
-- Employees submenu (owner)
-- ---------------------------------------------------------------------------
local function employeeActions(b, emp)
    local opts = {
        {
            title = 'Set wage', description = ('Current: %s/run'):format(money(emp.wage)),
            onSelect = function()
                local r = Game.InputDialog('Set wage', { { type = 'number', label = 'Per-payroll wage', required = true, min = 0 } })
                if r and r[1] then TriggerServerEvent('palm6_business:setWage', emp.citizenid, math.floor(r[1])) end
            end,
        },
        {
            title = 'Fire', description = 'Remove from the roster',
            onSelect = function()
                if Game.Confirm('Fire', ('Remove %s?'):format(emp.name or emp.citizenid)) then
                    TriggerServerEvent('palm6_business:fire', emp.citizenid)
                end
            end,
        },
    }
    Game.OpenMenu('palm6_business_emp', emp.name or emp.citizenid, opts, 'palm6_business_employees')
end

local function renderEmployees(b)
    local opts = {
        { title = 'Hire someone nearby', description = 'Offer a job to the closest unaffiliated person', onSelect = function() TriggerServerEvent('palm6_business:hireNearest') end },
        { title = 'Run payroll', description = 'Pay clocked-in employees their wage from the account', onSelect = function() TriggerServerEvent('palm6_business:runPayroll') end },
    }
    for _, emp in ipairs(b.roster or {}) do
        if emp.role < 3 then
            opts[#opts + 1] = {
                title = ('%s  ·  %s'):format(emp.name or emp.citizenid, money(emp.wage)),
                description = (emp.clocked_in == 1) and 'On the clock' or 'Off the clock',
                arrow = true,
                onSelect = function() employeeActions(b, emp) end,
            }
        end
    end
    Game.OpenMenu('palm6_business_employees', 'Employees', opts, 'palm6_business_root')
end

-- ---------------------------------------------------------------------------
-- Operations submenu (any staff)
-- ---------------------------------------------------------------------------
-- Serve labels/skill resolve from the server-sent cfg (numbers) + shared Config
-- (skill spec). While PerTypeMechanics is off both reduce to the Phase-0 wording.
local function serveLabels(cfg)
    return (cfg and cfg.labels) or { verb = 'Serve a walk-in', serveNoun = 'customer', supplyNoun = 'supply' }
end
local function serveSkill(bizType)
    if Config.PerTypeMechanics then
        for _, t in ipairs(Config.Types or {}) do
            if t.key == bizType and t.service then return t.service.skill end
        end
    end
    return nil  -- Game.ServeAction falls back to the default check
end
local function cap1(s) return (type(s) == 'string' and #s > 0) and (s:sub(1, 1):upper() .. s:sub(2)) or (s or '') end

local function doServe(b, cfg)
    if Game.ServeAction(serveSkill(b.biz_type)) then
        TriggerServerEvent('palm6_business:serve')
    else
        Game.Notify({ title = 'Business', description = 'Fumbled it — try again.', type = 'error' })
    end
end

local function doCharge()
    local r = Game.InputDialog('Charge a customer', {
        { type = 'number', label = 'Amount', required = true, min = 1 },
        { type = 'input', label = 'For (memo)', max = 64 },
    })
    if r and r[1] then TriggerServerEvent('palm6_business:chargeNearest', math.floor(r[1]), r[2]) end
end

local function renderOperations(b, cfg)
    local lbl = serveLabels(cfg)
    local opts = {
        { title = ('%s  (+%s)'):format(lbl.verb, money(cfg.servePayout)),
          description = ('%s: %d  ·  today %s / %s'):format(cap1(lbl.supplyNoun), b.supply or 0, money(b.dayIncome), money(b.dailyCap)),
          onSelect = function() doServe(b, cfg) end },
        { title = 'Charge a nearby customer', description = 'Ring up the closest player', onSelect = doCharge },
    }
    if b.role >= 3 then
        opts[#opts + 1] = {
            title = ('Buy %s  (%s each)'):format(lbl.supplyNoun, money(cfg.stockUnitCost)),
            description = ('Storage: %d / %d'):format(b.supply or 0, cfg.maxSupply),
            onSelect = function()
                local r = Game.InputDialog(('Buy %s'):format(lbl.supplyNoun), { { type = 'number', label = 'Units', required = true, min = 1 } })
                if r and r[1] then TriggerServerEvent('palm6_business:buyStock', math.floor(r[1])) end
            end,
        }
    end
    Game.OpenMenu('palm6_business_ops', 'Operations', opts, 'palm6_business_root')
end

-- ---------------------------------------------------------------------------
-- Storefront (Phase 1, owner) — place/move/restyle/remove the shop on the map
-- ---------------------------------------------------------------------------
local function renderBlipPicker(b, cfg)
    local sc = cfg.storefront or {}
    local sOpts, cOpts = {}, {}
    for _, s in ipairs(sc.sprites or {}) do sOpts[#sOpts + 1] = { value = s.sprite, label = s.label } end
    for _, c in ipairs(sc.colors or {}) do cOpts[#cOpts + 1] = { value = c.color, label = c.label } end
    if #sOpts == 0 or #cOpts == 0 then return end
    local cur = b.storefront or {}
    local r = Game.InputDialog('Customize map blip', {
        { type = 'select', label = 'Icon', options = sOpts, default = cur.sprite, required = true },
        { type = 'select', label = 'Colour', options = cOpts, default = cur.color, required = true },
    })
    if r and r[1] and r[2] then TriggerServerEvent('palm6_business:setBlip', r[1], r[2]) end
end

local function renderStorefront(b, cfg)
    local sf = b.storefront or {}
    local opts = {}
    if sf.set then
        opts[#opts + 1] = { title = 'Move storefront here', description = 'Re-place it at your current spot', icon = 'fa-solid fa-location-crosshairs',
            onSelect = function() TriggerServerEvent('palm6_business:setStorefront') end }
        opts[#opts + 1] = { title = 'Customize map blip', description = 'Icon and colour', icon = 'fa-solid fa-palette',
            onSelect = function() renderBlipPicker(b, cfg) end }
        opts[#opts + 1] = { title = 'Remove storefront', description = 'Take it off the map', icon = 'fa-solid fa-trash',
            onSelect = function()
                if Game.Confirm('Remove storefront', 'Remove this storefront from the map?') then
                    TriggerServerEvent('palm6_business:clearStorefront')
                end
            end }
    else
        opts[#opts + 1] = { title = 'Place storefront here', description = 'Mark this spot as your shop — puts it on the map', icon = 'fa-solid fa-map-pin',
            onSelect = function() TriggerServerEvent('palm6_business:setStorefront') end }
    end
    Game.OpenMenu('palm6_business_storefront', 'Storefront', opts, 'palm6_business_root')
end

-- ---------------------------------------------------------------------------
-- Root
-- ---------------------------------------------------------------------------
local function renderRoot(data)
    if not data.enabled then
        return Game.Notify({ title = 'Business', description = 'Businesses are not open yet.', type = 'error' })
    end
    if not data.business then return renderRegister(data) end
    local b = data.business
    local cfg = data.cfg or {}
    local sf = b.storefront                              -- nil when Phase 1 is off
    local isOwner = b.role >= 3
    -- Placed a storefront but standing away from it -> hide day-to-day management
    -- (you manage the shop AT the shop). Setting/moving/removing the storefront and
    -- registering stay reachable regardless, so an owner can never lock themselves out.
    local gated = sf and sf.set and not sf.atStorefront

    local opts = {}
    opts[#opts + 1] = { title = b.name, description = ('%s  ·  you are %s'):format(b.biz_type or '', b.roleName or ''), disabled = true }

    if gated then
        opts[#opts + 1] = { title = 'Head to your storefront to manage', description = "It's marked on your map.", icon = 'fa-solid fa-location-dot', disabled = true }
    else
        if isOwner then
            opts[#opts + 1] = { title = ('Account  ·  %s'):format(money(b.balance)), arrow = true, onSelect = function() renderAccount(b) end }
            opts[#opts + 1] = { title = 'Employees', description = ('%d on the roster'):format(#(b.roster or {})), arrow = true, onSelect = function() renderEmployees(b) end }
        end
        opts[#opts + 1] = { title = 'Operations', description = 'Serve, charge, supply', arrow = true, onSelect = function() renderOperations(b, cfg) end }
        opts[#opts + 1] = {
            title = b.clockedIn and 'Clock out' or 'Clock in',
            description = b.clockedIn and 'You are on the clock' or 'Clock in to serve customers',
            onSelect = function() TriggerServerEvent('palm6_business:clock', not b.clockedIn) end,
        }
        opts[#opts + 1] = { title = 'View ledger', description = 'Recent money movements', onSelect = function() TriggerServerEvent('palm6_business:viewLedger') end }
    end

    -- Storefront controls (owner + Phase 1) — ALWAYS shown, even when gated, so a
    -- badly-placed storefront can be moved/removed from anywhere.
    if isOwner and sf and sf.enabled then
        opts[#opts + 1] = {
            title = sf.set and 'Storefront' or 'Place a storefront',
            description = sf.set and 'Move · restyle · remove' or 'Put your shop on the map',
            icon = 'fa-solid fa-store', arrow = true,
            onSelect = function() renderStorefront(b, cfg) end,
        }
    end

    -- Rename (owner) — management, hidden while gated.
    if not gated and isOwner then
        opts[#opts + 1] = {
            title = 'Rename business',
            onSelect = function()
                local r = Game.InputDialog('Rename', { { type = 'input', label = 'New name', required = true, min = 3, max = 48 } })
                if r and r[1] then TriggerServerEvent('palm6_business:rename', r[1]) end
            end,
        }
    end
    -- Resign (staff) — ALWAYS available: quitting a job shouldn't require standing
    -- in the shop, so it stays reachable even when the storefront gate is active.
    if not isOwner then
        opts[#opts + 1] = { title = 'Resign', description = 'Leave this business', onSelect = function()
            if Game.Confirm('Resign', 'Leave this business?') then TriggerServerEvent('palm6_business:resign') end
        end }
    end
    Game.OpenMenu('palm6_business_root', b.name, opts)
end

RegisterNetEvent('palm6_business:menuData', function(data)
    lastData = data
    renderRoot(data)
end)

RegisterNetEvent('palm6_business:ledgerData', function(d)
    local lines = {}
    for _, r in ipairs(d.rows or {}) do
        local sign = (r.amount and r.amount < 0) and '-' or '+'
        lines[#lines + 1] = ('**%s**  %s%s  →  %s  \n%s'):format(r.action or '?', sign, money(math.abs(r.amount or 0)), money(r.balance_after), r.memo or '')
    end
    local body = (#lines > 0) and table.concat(lines, '  \n') or 'No activity yet.'
    Game.ShowReport(('%s · ledger'):format(d.name or 'Business'), body)
end)

RegisterNetEvent('palm6_business:hirePrompt', function(d)
    if Game.Confirm('Job offer', ('**%s** is offering you a job. Accept?'):format(d.businessName or 'A business')) then
        TriggerServerEvent('palm6_business:acceptHire')
    end
end)

RegisterNetEvent('palm6_business:chargePrompt', function(d)
    local ok = Game.Confirm('Payment', ('**%s** is charging you %s for "%s". Pay?'):format(d.businessName or 'A business', money(d.amount), d.memo or 'a sale'))
    if ok then TriggerServerEvent('palm6_business:acceptCharge') end
end)

-- ---------------------------------------------------------------------------
-- Phase 1 — storefront blips/targets + walk-up info card
-- ---------------------------------------------------------------------------

-- Server pushed the full storefront set (on change, on boot, or on our request).
RegisterNetEvent('palm6_business:storefronts', function(list)
    if type(list) ~= 'table' then return end
    Game.RenderStorefronts(list, Config.Storefront, function(id)
        TriggerServerEvent('palm6_business:openHere', id)
    end)
end)

-- A passerby walked up to a storefront (not their business) -> read-only card.
RegisterNetEvent('palm6_business:infoCard', function(d)
    if type(d) ~= 'table' then return end
    local body = ('# %s\n%s\n\nOwner: **%s**'):format(d.name or 'Business', d.biz_type or '', d.owner or 'Unknown')
    Game.ShowReport('Storefront', body)
end)

-- Pull the storefront set once on load (covers fresh joins). Config is shared, so
-- the client knows whether Phase 1 is live without a round-trip; the server
-- re-checks phase1() before replying regardless.
CreateThread(function()
    Wait(2500)
    if Config.Enabled and Config.Phase1Enabled then
        TriggerServerEvent('palm6_business:requestStorefronts')
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    Game.ClearStorefronts()
end)
