-- ============================================================================
-- palm6_perf/server/tables.lua
--
-- THE SINGLE AUTHORITY for "which DB tables does each palm6 resource need".
--
-- Why this lives in palm6_perf and not where it started:
--   The list used to be a local inside palm6_devtest/server/main.lua, which is
--   gated behind the `palm6:devtest` convar that custom.cfg explicitly tells
--   operators to leave unset. So the one assertion in the whole layer that
--   could catch a missing table NEVER RAN in production. palm6_perf is
--   always-on (custom.cfg ensures it) and already owns /diag, so the list
--   moved here and palm6_devtest now reads it back through the export. One
--   list, one place to update when a resource gains a table.
--
-- Why server_scripts and not shared_scripts:
--   This is server-only data - the schema check runs server-side and the only
--   consumers are server/main.lua and palm6_perf:GetRequiredTables(). In
--   shared_scripts every client would download and execute a hundred-odd lines
--   describing our database for no reason. It is a bare global rather than a
--   local because FiveM gives each server script its own file scope, so a
--   local here would be invisible to server/main.lua; outside this resource
--   the ONLY supported reader is the GetRequiredTables export.
--
-- Why a missing table is worse here than in most codebases:
--   Nearly every query in this layer is pcall-wrapped (deliberately - a DB
--   blip must never break a gameplay path). The side effect is that a missing
--   table produces SILENCE, not an error. A restored backup or a new box boots
--   clean, prints no warnings, and half the economy quietly does nothing. The
--   boot banner in server/main.lua is the thing that turns that silence into
--   one loud line.
--
-- Maintenance rule: when a resource starts querying a new table, add it here
-- in the same change. The check is read-only (one information_schema SELECT)
-- and never blocks startup, so an entry costs nothing and a missing entry
-- costs a silent outage. Only list tables THIS REPO can create, because the
-- banner's remediation line tells the operator to apply a sql/ migration.
--
-- Keyed by OWNER, not by caller. Nine resources touch MySQL but own no table
-- and are deliberately absent: palm6_blotter, palm6_citystats, palm6_ganginfo,
-- palm6_rapsheet, palm6_wanted and palm6_fc_combat are pure cross-readers of
-- tables listed below, and palm6_dbmigrate / palm6_devtest / palm6_perf are
-- infrastructure. Listing a reader would report the same missing table twice
-- and blame the wrong resource.
-- ============================================================================

RequiredTables = {
    -- --- applied from sql/ by hand (deploy/README.md) -----------------------
    palm6_allowlist   = { 'allowlist' },
    palm6_bounty      = { 'palm6_bounty_contracts' },
    palm6_citations   = { 'palm6_citations' },
    palm6_clout       = { 'palm6_clout_streamers', 'palm6_clout_deals', 'palm6_clout_vod' },
    palm6_counterfeit = { 'palm6_counterfeit_printers', 'palm6_counterfeit_batches',
                          'palm6_counterfeit_wads', 'palm6_counterfeit_hops',
                          'palm6_counterfeit_leads', 'palm6_counterfeit_heat',
                          'palm6_counterfeit_fence_quota' },
    palm6_courier     = { 'courier_postings' },
    palm6_eventguard  = { 'event_violations' },
    palm6_evidence    = { 'palm6_evidence', 'palm6_evidence_cases', 'palm6_evidence_suspects' },
    palm6_fightclub   = { 'palm6_fightclub_matches', 'palm6_fightclub_bets' },
    palm6_flashdrop   = { 'palm6_flashdrop_drops', 'palm6_flashdrop_serials',
                          'palm6_flashdrop_provenance', 'palm6_flashdrop_listings' },
    palm6_gangs       = { 'palm6_gangs', 'palm6_gang_members', 'palm6_gang_vault_log',
                          'palm6_gang_web_tokens' },
    palm6_grind       = { 'grind_skill' },
    palm6_gunrunning  = { 'palm6_gunrunning_sales' },
    palm6_chopshop    = { 'palm6_chopshop_stolen', 'palm6_chopshop_sales' },
    palm6_laundering  = { 'palm6_laundering_runs' },
    palm6_numbers     = { 'palm6_numbers_bets', 'palm6_numbers_draws' },
    palm6_protection  = { 'palm6_protection_collections' },
    palm6_loanshark   = { 'palm6_loanshark_loans' },
    palm6_seizure     = { 'palm6_seizure_forfeitures' },
    palm6_smuggling   = { 'palm6_smuggling_runs' },
    palm6_drugs       = { 'palm6_drugs_plants', 'palm6_drugs_recipes', 'palm6_drugs_progression',
                          'palm6_drugs_sales', 'palm6_drugs_processes', 'palm6_drugs_dealers' },
    palm6_insurance   = { 'palm6_insurance_policies', 'palm6_insurance_claims' },
    palm6_legal       = { 'palm6_legal_petitions' },
    palm6_mdt         = { 'palm6_mdt_bolos', 'palm6_mdt_reports',
                          'palm6_mdt_warrants', 'palm6_mdt_bookings',
                          'palm6_mdt_calls' },
    palm6_onboarding  = { 'palm6_onboarding' },
    palm6_pumpcoin    = { 'palm6_pumpcoin_coins', 'palm6_pumpcoin_holdings',
                          'palm6_pumpcoin_trades', 'palm6_pumpcoin_billboards' },
    palm6_ransom      = { 'palm6_ransom_cases' },
    palm6_replay      = { 'palm6_replay_scenes', 'palm6_replay_participants' },
    palm6_staff       = { 'audit_log' },
    palm6_turf        = { 'palm6_turf' },
    palm6_witnesses   = { 'palm6_witnesses_incidents', 'palm6_witnesses' },

    -- --- drifted owners: real tables that were never on the old list --------
    -- Each of these queries a table nothing asserted the existence of, so a
    -- fresh box lost the whole feature with no console line to show for it.
    palm6_business       = { 'palm6_businesses', 'palm6_business_members',
                             'palm6_business_ledger', 'palm6_business_shells' },
    palm6_market         = { 'palm6_market_state', 'palm6_market_trades' },
    palm6_yard           = { 'palm6_yard_sentence', 'palm6_yard_labor',
                             'palm6_yard_commissary_log', 'palm6_yard_bail' },
    palm6_pulse          = { 'palm6_pulse_windows', 'palm6_pulse_checkins',
                             'palm6_pulse_streaks' },
    palm6_racing         = { 'palm6_racing_progression', 'palm6_racing_results' },
    -- palm6_fc_pve_cooldowns is deliberately NOT listed: palm6_dbmigrate creates
    -- it but no resource queries it yet, so asserting it would be asserting an
    -- unused table.
    palm6_fc_progression = { 'palm6_fc_progression', 'palm6_fc_unlocks', 'palm6_fc_daily' },

    -- palm6_founding_grants is deliberately NOT listed. palm6_founder reads it
    -- (server/main.lua:47) but it is WEBSITE-owned: no sql/ file and no repo
    -- artifact creates it, the palm6 website's own migrations do
    -- (palm6_founder/README.md:74). Listing it would print a red MISSING banner
    -- on every restart of every box the website has not provisioned yet, under
    -- a remediation line that says "apply the matching sql/ migration" - advice
    -- no operator can act on, because there is no migration to apply. A
    -- permanent false alarm with the wrong instructions trains people to ignore
    -- the banner, which is the one thing this check cannot afford.

    -- --- self-creating resources (listed anyway, on purpose) ---------------
    -- These five build their own tables at boot, so this is a check that their
    -- self-create actually RAN, not that a human applied a migration. A MISSING
    -- line for one of them means its ensureSchema errored, which is otherwise
    -- only visible as a single line far earlier in the console.
    palm6_ems         = { 'palm6_ems_bills', 'palm6_ems_treatments' },
    palm6_heat        = { 'palm6_heat_state' },
    palm6_lottery     = { 'palm6_lottery_draws', 'palm6_lottery_tickets' },
    palm6_season      = { 'palm6_seasons', 'palm6_season_rewards', 'palm6_season_archive' },
    palm6_mapeditor   = { 'palm6_mapeditor_props', 'palm6_mapeditor_entities',
                          'palm6_mapeditor_lights', 'palm6_mapeditor_hides',
                          'palm6_mapeditor_prefabs', 'palm6_mapeditor_revisions' },
}
