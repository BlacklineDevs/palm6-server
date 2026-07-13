-- ============================================================================
-- gtarp_help/shared/config.lua, engine-agnostic tunables (Tier 1, carries to VI).
-- Mirrors the Config shape of gtarp_citystats and gtarp_blotter.
--
-- gtarp_help is a READ-ONLY, static, in-game command reference. It owns no
-- table, never writes, and never reads the database. Everything a player sees
-- is CURATED DATA defined right here, so updating the help menu is a matter of
-- editing this file only (no logic changes in server/main.lua).
--
-- Only commands that ACTUALLY exist in the Palm6 custom resources are listed.
-- Each entry was confirmed against a real RegisterCommand / Bridge.RegisterCommand
-- call in the owning resource (owner noted in a comment per category).
-- ============================================================================
Config = {}

Config.Debug = false

-- Server console and this ace may always run /help. Any online citizen may run
-- it too (no job gate): the help menu is public. The ace only gates the extra
-- "Admin" category (see Config.AdminCategories), shown only to staff.
Config.AdminAce = 'command.help'

-- Per-source command cooldown (seconds), mirroring gtarp_citystats.RateLimits.
Config.RateLimits = {
    help = 3,
}

-- How many command names to preview per category in the top-level /help list.
-- The full list per category is shown by /help <topic>.
Config.TopPerCategory = 4

-- Chat tag colour for the HELP prefix (r, g, b), matching the house style of
-- the notify/chat bridge in the sibling resources.
Config.ChatColor = { 130, 205, 140 }

-- ---------------------------------------------------------------------------
-- The curated menu. An ORDERED list of categories, each with a stable `key`
-- (what a player types after /help), a display `label`, a one-line `blurb`,
-- and a list of { cmd, blurb } command rows. Add or edit rows here; nothing
-- else needs to change.
--
-- Every command below was confirmed to exist:
--   Gangs      -> gtarp_gangs (Config.Command 'gang', WebCommand 'gangweb'),
--                 gtarp_ganginfo ('gangs', 'ganginfo'), gtarp_turf ('turf')
--   Crime      -> gtarp_protection ('shakedown', 'rackets'),
--                 gtarp_laundering ('launder', 'dirtymoney'),
--                 gtarp_loanshark ('borrow', 'repay', 'loaninfo'),
--                 gtarp_smuggling ('smuggle', 'deliver', 'smugglerun'),
--                 gtarp_numbers ('numbers', 'collectnumbers', 'numbersinfo'),
--                 gtarp_gunrunning ('buyweapon'),
--                 gtarp_ransom ('demandransom', 'payransom'),
--                 gtarp_chopshop ('reportstolen', 'sellstolen'),
--                 gtarp_pumpcoin ('shill', 'pumpboard'),
--                 gtarp_fightclub ('fcjoin', 'fcleave', 'fcbet', 'fcmatches'),
--                 gtarp_flashdrop ('flashdrop'),
--                 gtarp_clout ('golive', 'endstream', 'clout', 'streamers')
--   EMS        -> gtarp_ems ('medbills', 'paymedbill', 'emsbill', 'emscalls', 'treat')
--   City       -> gtarp_citystats ('citystats'), gtarp_season ('season',
--                 'seasontop'), gtarp_lottery ('lottery'), gtarp_onboarding ('rules')
--   Justice    -> gtarp_rapsheet ('rapsheet'), gtarp_wanted ('wanted', 'amiwanted'),
--                 gtarp_citations ('fines', 'payfine'),
--                 gtarp_insurance ('insure', 'fileclaim', 'policy'),
--                 gtarp_bounty ('bounties', 'postbounty', 'cancelbounty', 'capture'),
--                 gtarp_tips ('tip')
--   LEO        -> gtarp_citations ('cite'), gtarp_mdt ('mdt', 'bolo', 'bolos',
--                 'warrant', 'warrants', 'book', 'calls'), gtarp_blotter ('blotter'),
--                 gtarp_rapsheet ('priors'), gtarp_evidence ('evidence', 'casenew'),
--                 gtarp_witnesses ('witnesses'), gtarp_replay ('bodycam'),
--                 gtarp_seizure ('seizedirty'), gtarp_legal ('expunge')
--   Jobs       -> gtarp_courier ('courier', 'courierpost')
-- ---------------------------------------------------------------------------
Config.Categories = {
    {
        key = 'gangs',
        label = 'Gangs',
        blurb = 'Crews, turf and gang reputation.',
        commands = {
            { cmd = '/gang',     blurb = 'Open your gang menu (rank, vault, members).' },
            { cmd = '/gangweb',  blurb = 'Open the gang web panel in your browser.' },
            { cmd = '/gangs',    blurb = 'List the active gangs in the city.' },
            { cmd = '/ganginfo', blurb = 'Look up one gang by tag: /ganginfo [tag].' },
            { cmd = '/turf',     blurb = 'Check the current turf status and who holds what.' },
        },
    },
    {
        key = 'crime',
        label = 'Crime',
        blurb = 'The illegal ways to earn around the city.',
        commands = {
            { cmd = '/launder',      blurb = 'Launder dirty money through a front.' },
            { cmd = '/dirtymoney',   blurb = 'Check how much dirty cash you are holding.' },
            { cmd = '/shakedown',    blurb = 'Shake down a nearby business for your crew (crew only).' },
            { cmd = '/rackets',      blurb = 'List your crew active protection rackets.' },
            { cmd = '/borrow',       blurb = 'Take a loan from the loan shark: /borrow [amount].' },
            { cmd = '/repay',        blurb = 'Repay your loan shark debt: /repay [amount].' },
            { cmd = '/loaninfo',     blurb = 'See your current loan balance and terms.' },
            { cmd = '/smuggle',      blurb = 'Pick up contraband for a smuggling run.' },
            { cmd = '/deliver',      blurb = 'Drop off smuggled goods for the payout.' },
            { cmd = '/smugglerun',   blurb = 'Check your current smuggling run status.' },
            { cmd = '/numbers',      blurb = 'Play the numbers racket: /numbers [bet].' },
            { cmd = '/collectnumbers', blurb = 'Collect winnings from the numbers racket.' },
            { cmd = '/numbersinfo',  blurb = 'See the numbers racket odds and your slips.' },
            { cmd = '/buyweapon',    blurb = 'Buy from the black market gun runner: /buyweapon [item].' },
            { cmd = '/demandransom', blurb = 'Demand a ransom for a captive: /demandransom [amount].' },
            { cmd = '/payransom',    blurb = 'Pay a ransom to free a captive: /payransom [id].' },
            { cmd = '/reportstolen', blurb = 'Report a stolen vehicle to the chop shop.' },
            { cmd = '/sellstolen',   blurb = 'Sell a stolen vehicle at the chop shop.' },
            { cmd = '/shill',        blurb = 'Shill a coin to pump its price: /shill [coin].' },
            { cmd = '/pumpboard',    blurb = 'View the pump and dump leaderboard.' },
            { cmd = '/fcjoin',       blurb = 'Join the fight club queue.' },
            { cmd = '/fcleave',      blurb = 'Leave the fight club queue.' },
            { cmd = '/fcbet',        blurb = 'Bet on a fight club match: /fcbet [amount].' },
            { cmd = '/fcmatches',    blurb = 'See the upcoming fight club matches.' },
            { cmd = '/flashdrop',    blurb = 'Check the current flash drop event.' },
            { cmd = '/golive',       blurb = 'Go live and start a stream for clout.' },
            { cmd = '/endstream',    blurb = 'End your current stream.' },
            { cmd = '/clout',        blurb = 'Check your clout score.' },
            { cmd = '/streamers',    blurb = 'See who is currently streaming.' },
        },
    },
    {
        key = 'ems',
        label = 'Emergency Services',
        blurb = 'Medical bills for everyone, plus on-duty EMS tools.',
        commands = {
            { cmd = '/medbills',   blurb = 'View your outstanding medical bills.' },
            { cmd = '/paymedbill', blurb = 'Pay a medical bill: /paymedbill [id].' },
            { cmd = '/emsbill',    blurb = 'Bill a patient (on-duty medic): /emsbill [id] [amount].' },
            { cmd = '/emscalls',   blurb = 'View active EMS calls (on-duty medic).' },
            { cmd = '/treat',      blurb = 'Treat a patient (on-duty medic).' },
        },
    },
    {
        key = 'city',
        label = 'City Info',
        blurb = 'Public read-outs on the city, the season and the lottery.',
        commands = {
            { cmd = '/citystats', blurb = 'Live city stats: gangs, economy, warrants: /citystats [hours].' },
            { cmd = '/season',    blurb = 'See the current season and its theme.' },
            { cmd = '/seasontop', blurb = 'Season leaderboard: /seasontop [board].' },
            { cmd = '/lottery',   blurb = 'Buy into the city lottery: /lottery [tickets].' },
            { cmd = '/rules',     blurb = 'Re-read the server rules at any time.' },
        },
    },
    {
        key = 'justice',
        label = 'Justice and Records',
        blurb = 'Your record, warrants, fines, insurance and bounties.',
        commands = {
            { cmd = '/rapsheet',     blurb = 'Pull your own criminal record.' },
            { cmd = '/wanted',       blurb = 'Check the public wanted list.' },
            { cmd = '/amiwanted',    blurb = 'Check whether you are currently wanted.' },
            { cmd = '/fines',        blurb = 'See your unpaid citations and fines.' },
            { cmd = '/payfine',      blurb = 'Pay a citation: /payfine [id].' },
            { cmd = '/insure',       blurb = 'Insure a vehicle: /insure [plate].' },
            { cmd = '/fileclaim',    blurb = 'File an insurance claim: /fileclaim [plate].' },
            { cmd = '/policy',       blurb = 'View your active insurance policy.' },
            { cmd = '/bounties',     blurb = 'View the open bounty board.' },
            { cmd = '/postbounty',   blurb = 'Post a bounty: /postbounty [id] [amount].' },
            { cmd = '/cancelbounty', blurb = 'Cancel a bounty you posted: /cancelbounty [id].' },
            { cmd = '/capture',      blurb = 'Claim a bounty capture: /capture [id].' },
            { cmd = '/tip',          blurb = 'Call in an anonymous tip from a payphone: /tip [what you saw].' },
        },
    },
    {
        key = 'leo',
        label = 'Law Enforcement',
        blurb = 'On-duty police and lawyer tools (requires the job).',
        commands = {
            { cmd = '/cite',       blurb = 'Issue a citation (on-duty police): /cite [id] [offense].' },
            { cmd = '/mdt',        blurb = 'Open the police MDT (on-duty police).' },
            { cmd = '/bolo',       blurb = 'File a BOLO (on-duty police): /bolo [text].' },
            { cmd = '/bolos',      blurb = 'List active BOLOs (on-duty police).' },
            { cmd = '/warrant',    blurb = 'File a warrant (on-duty police): /warrant [id].' },
            { cmd = '/warrants',   blurb = 'List active warrants (on-duty police).' },
            { cmd = '/book',       blurb = 'Book a suspect (on-duty police): /book [id] [charges].' },
            { cmd = '/calls',      blurb = 'Read incoming 911 calls and tips (on-duty police).' },
            { cmd = '/blotter',    blurb = 'Weekly police blotter summary (on-duty police).' },
            { cmd = '/priors',     blurb = 'Look up a citizen record (on-duty police): /priors [id].' },
            { cmd = '/evidence',   blurb = 'Manage evidence (on-duty police): /evidence [case].' },
            { cmd = '/casenew',    blurb = 'Open a new case file (on-duty police).' },
            { cmd = '/witnesses',  blurb = 'Review witness statements (on-duty police).' },
            { cmd = '/bodycam',    blurb = 'Toggle your body cam (on-duty police).' },
            { cmd = '/seizedirty', blurb = 'Seize dirty money as contraband (on-duty police).' },
            { cmd = '/expunge',    blurb = 'Expunge a booking (on-duty lawyer): /expunge [booking].' },
        },
    },
    {
        key = 'jobs',
        label = 'Jobs',
        blurb = 'Legit work you can pick up around the map.',
        commands = {
            { cmd = '/courier',     blurb = 'Browse and accept courier deliveries: /courier list.' },
            { cmd = '/courierpost', blurb = 'Post a courier delivery job for others.' },
        },
    },
}

-- ---------------------------------------------------------------------------
-- Extra categories shown ONLY to server console and ace holders (Config.AdminAce),
-- appended to the /help list and reachable via /help admin. These are staff /
-- dev commands, kept out of the public menu on purpose.
--   Admin -> gtarp_perf ('diag', ace command.diag),
--            gtarp_economy ('economy', ace command.economy, restricted register),
--            gtarp_season ('seasonopen', 'seasonclose', IsAdmin gated)
-- ---------------------------------------------------------------------------
Config.AdminCategories = {
    {
        key = 'admin',
        label = 'Admin',
        blurb = 'Staff and dev commands (ace gated).',
        commands = {
            { cmd = '/diag',        blurb = 'Custom-layer health check (staff, ace gated).' },
            { cmd = '/economy',     blurb = 'City crime economy scoreboard (staff, ace gated).' },
            { cmd = '/seasonopen',  blurb = 'Open a new season (admin): /seasonopen [name].' },
            { cmd = '/seasonclose', blurb = 'Close the current season (admin).' },
        },
    },
}
