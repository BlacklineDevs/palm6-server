-- ============================================================================
-- config_overrides/qbx_core/server/overrides.lua
--
-- Publishes our override values as convars so qbx_core (and downstream
-- resources) read a single source of truth. Convar names follow the
-- documented qbx_core / fivem pattern (`set/setr <key> <value>`); the
-- recipe-deployed qbx_core can be tuned by these without vendoring it.
-- ============================================================================

local function setConvarBool(key, value)
    SetConvar(key, value and 'true' or 'false')
end

local function setConvarNum(key, value)
    SetConvar(key, tostring(value))
end

local function setConvarStr(key, value)
    SetConvar(key, tostring(value))
end

local function publish()
    if not Override then
        print('[config_overrides/qbx_core] Override table missing; skipping.')
        return
    end

    -- Multichar
    setConvarNum('qbx:multichar_slots', Override.MaxCharacters or 2)

    -- Required identifiers — comma joined, qbx_core convention.
    setConvarStr('qbx:required_identifiers',
        table.concat(Override.RequiredIdentifiers or { 'license' }, ','))

    -- Name validation
    setConvarStr('qbx:character_name_regex', Override.NameRegex or '.*')
    setConvarNum('qbx:character_name_min', Override.NameMinLen or 2)
    setConvarNum('qbx:character_name_max', Override.NameMaxLen or 24)

    -- DOB bounds
    setConvarNum('qbx:character_dob_min_year', Override.DOB.minYear or 1960)
    setConvarNum('qbx:character_dob_max_year', Override.DOB.maxYear or 2006)

    -- Starting funds — also picked up by Phase 2 economy overrides.
    setConvarNum('qbx:starting_cash',   Override.StartingMoney.cash   or 500)
    setConvarNum('qbx:starting_bank',   Override.StartingMoney.bank   or 5000)
    setConvarNum('qbx:starting_crypto', Override.StartingMoney.crypto or 0)

    print(('[config_overrides/qbx_core] applied: slots=%d cash=%d bank=%d'):format(
        Override.MaxCharacters, Override.StartingMoney.cash, Override.StartingMoney.bank
    ))
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    publish()
end)
