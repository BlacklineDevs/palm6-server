-- ============================================================================
-- gtarp_economy/server/main.lua
--
-- Pure logic. Calls Bridge.* only (§6 gate). Read-only: aggregates each crime
-- resource's GetSummary() export into one staff-facing scoreboard. No DB, no
-- writes, no new table — just the operator's-eye view of the dirty-money
-- economy (how much each source has minted, how much the laundromat washed and
-- police forfeited, and the rough net still in circulation).
-- ============================================================================

local function n(v) return tonumber(v) or 0 end
local function money(v) return ('$%d'):format(n(v)) end

-- Build the scoreboard + the source/sink tally. Returns lines, minted, removed.
local function tally()
    local L = {}
    local minted, removed = 0, 0
    L[#L + 1] = '=== Palm6 crime economy ==='

    local la = Bridge.Summary('gtarp_laundering')
    if la then
        removed = removed + n(la.totalDirtyWashed)
        L[#L + 1] = ('laundering:  %s washed clean  (%d run(s), %d flagged)'):format(
            money(la.totalDirtyWashed), n(la.totalRuns), n(la.flaggedRuns))
    else L[#L + 1] = 'laundering:  offline' end

    local sz = Bridge.Summary('gtarp_seizure')
    if sz then
        removed = removed + n(sz.totalForfeited)
        L[#L + 1] = ('seizure:     %s forfeited by police  (%d seizure(s))'):format(
            money(sz.totalForfeited), n(sz.seizures))
    else L[#L + 1] = 'seizure:     offline' end

    local nu = Bridge.Summary('gtarp_numbers')
    if nu then
        minted = minted + n(nu.totalPaid)
        L[#L + 1] = ('numbers:     %d draw(s), %s staked (clean), %s paid (dirty)'):format(
            n(nu.draws), money(nu.totalStaked), money(nu.totalPaid))
    else L[#L + 1] = 'numbers:     offline' end

    local pr = Bridge.Summary('gtarp_protection')
    if pr then
        minted = minted + n(pr.totalCollected)
        L[#L + 1] = ('protection:  %d shakedown(s), %s collected (dirty)'):format(
            n(pr.shakedowns), money(pr.totalCollected))
    else L[#L + 1] = 'protection:  offline' end

    local lo = Bridge.Summary('gtarp_loanshark')
    if lo then
        minted = minted + n(lo.lentTotal)
        L[#L + 1] = ('loanshark:   %d open / %d defaulted, %s lent (dirty)'):format(
            n(lo.open), n(lo.defaulted), money(lo.lentTotal))
    else L[#L + 1] = 'loanshark:   offline' end

    local sm = Bridge.Summary('gtarp_smuggling')
    if sm then
        minted = minted + n(sm.dirtyPaid)
        L[#L + 1] = ('smuggling:   %d delivered, %s paid (dirty), %d active'):format(
            n(sm.delivered), money(sm.dirtyPaid), n(sm.active))
    else L[#L + 1] = 'smuggling:   offline' end

    local dr = Bridge.Summary('gtarp_drugs')
    if dr then
        minted = minted + n(dr.totalDirtyEarned)
        L[#L + 1] = ('drugs:       %d sales, %s earned (dirty), %d flagged, %d growing'):format(
            n(dr.totalSales), money(dr.totalDirtyEarned), n(dr.flaggedSales), n(dr.activePlants))
    else L[#L + 1] = 'drugs:       offline' end

    -- gtarp_gangs is not a dirty-cash source or sink (its vault holds CLEAN
    -- cash), so it doesn't feed minted/removed — it's an informational line
    -- on the player-run gang layer for the operator's-eye view.
    local ga = Bridge.Summary('gtarp_gangs')
    if ga then
        L[#L + 1] = ('gangs:       %d gang(s), %d member(s), %s in vaults, top rep %d'):format(
            n(ga.gangs), n(ga.members), money(ga.totalVault), n(ga.topRep))
    else L[#L + 1] = 'gangs:       offline' end

    L[#L + 1] = ('-- dirty minted ~%s | removed (laundered+forfeited) ~%s | net in play ~%s'):format(
        money(minted), money(removed), money(minted - removed))
    L[#L + 1] = '   (net excludes recipe bank-robbery minting + black-market spend)'
    return L, minted, removed
end

local function cmdEconomy(src)
    local lines = tally()
    Bridge.Reply(src, lines)
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    Bridge.RegisterCommand(Config.Command, function(source) cmdEconomy(source) end)
    print(('[gtarp_economy] scoreboard online — /%s aggregates the crime economy for staff'):format(Config.Command))
end)

--- Aggregate totals for devtest / a future web dashboard.
exports('GetSummary', function()
    local _, minted, removed = tally()
    return { dirtyMinted = minted, dirtyRemoved = removed, netInPlay = minted - removed }
end)

--- The formatted scoreboard lines (same as /economy prints).
exports('RunEconomy', function()
    local lines = tally()
    return lines
end)
