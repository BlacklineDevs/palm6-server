-- ============================================================================
-- palm6_legal/shared/config.lua — engine-agnostic tunables (Tier 1,
-- carries to VI). The civilian counterweight to the police paperwork
-- stack: /record shows what the city has on you, /expunge petitions to
-- seal an old booking. Gives the recipe's defined-but-inert `lawyer`
-- job its first real mechanic — lawyers can pull a client's record and
-- file on their behalf (the recipe's /paylawyer finally has work to
-- pay for).
-- ============================================================================
Config = {}

Config.Debug = false

-- The job the recipe defines with no mechanics behind it.
Config.LawyerJob = 'lawyer'

-- The OTHER job the recipe defines with no mechanics behind it. UNVERIFIED
-- FROM THIS REPO: qbx_core is not in this tree (it lives on the game box), so
-- the exact job name cannot be checked here. This README asserted it in an
-- earlier round and that is the only evidence. If the name is wrong the judge
-- branch in Config.Sentencing simply never passes — the gate gets narrower,
-- nothing errors — and the fix is this one string.
Config.JudgeJob = 'judge'

-- Where petitions are filed (server-checked against the filer's real
-- coords): the Rockford Hills courthouse.
Config.Courthouse = {
    coords = { x = -544.67, y = -204.44, z = 38.65 },
    radius = 25.0,
    label = 'the courthouse',
}

Config.Expunge = {
    Fee            = 2500,   -- charged to the FILER at filing; court costs, kept on denial
    MinBookingAgeH = 168,    -- booking must be at least this old (7 days)
    ProcessingSec  = 600,    -- petition resolves this long after filing
    SweepSec       = 60,     -- how often the resolver sweep runs
}

-- ---------------------------------------------------------------------------
-- Sentence review (/sentence). SHIPS OFF (Enabled=false).
--
-- The review step between "an officer filed a booking" and "somebody decides
-- what happens to this person". It reads a booking, asks palm6_mdt for the
-- recommendation, and PRINTS THE ARITHMETIC so a human can see why. It changes
-- nothing: no money moves, no record is altered, and nobody is jailed by it —
-- this repo cannot jail anybody (see the qbx_police handoff note in README.md).
--
-- The subject is NEVER notified. Output goes to the caller only. That is a
-- deliberate anti-grief property: without it, /sentence on a stranger's
-- booking would be a way to spam somebody with fabricated court notices.
--
-- YOU MUST ALREADY KNOW WHO YOU ARE LOOKING UP. The command takes the
-- subject's citizenid as well as the booking number, and refuses (with the
-- same message it gives for a booking that does not exist) when the two do not
-- match. Booking ids are small consecutive integers; without that check the
-- command was a walk-the-integers oracle that turned "any player can take the
-- lawyer job" into "any player can dump every name, citizenid and charge sheet
-- on the box". Every other read surface in this stack already demands a
-- citizenid up front (/record via resolveSubject, palm6_rapsheet's /priors,
-- palm6_mdt's /warrant and /book); this one now matches them.
-- ---------------------------------------------------------------------------
Config.Sentencing = {
    -- Master flag. false = the command is not registered at all.
    Enabled = false,

    Command = 'sentence',

    -- ACE the command checks. THIS GRANT DOES NOT EXIST YET and cannot be
    -- created from this repo: aces live in custom.cfg on the game box, which
    -- is not in this tree. Until an operator adds something like
    --     add_ace group.admin palm6.judge allow
    -- the ace branch below simply never passes, and access falls to the lawyer
    -- and police branches. Nothing errors; the gate is just narrower.
    --
    -- This ace is ALSO the only thing that can read a SEALED (expunged)
    -- booking, and the only thing that may pass `*` instead of a citizenid.
    -- Grant it narrowly: handing it to a wide group hands that group the
    -- expunged records the players paid to bury.
    Ace = 'palm6.judge',

    -- Who else may run it. Each reads a record they can already read by other
    -- means (a lawyer via /record for a client, police via /priors in
    -- palm6_rapsheet), so none of these widens what anybody can see — they
    -- only add the recommendation on top.
    --
    -- AllowJudge is the branch that makes this work WITHOUT an ace grant, which
    -- matters because nobody can add one from this repo. It depends on
    -- Config.JudgeJob being right, which is unverifiable here (see above).
    AllowJudge  = true,
    AllowLawyer = true,
    AllowPolice = true,

    -- Write each lookup to the house staff audit sink (palm6_staff:Log). Soft:
    -- a missing or broken sink never fails the command.
    --
    -- palm6_staff:Log does a MySQL insert AND a Discord webhook POST per call,
    -- and every other caller in the repo logs a WRITE (a booking, a warrant, a
    -- kick). This logs a READ, so it is the one caller that could be pulled in
    -- a loop. Two things bound it: the budget below, and per-window de-dup
    -- (the same source re-pulling the same booking inside one window logs once).
    -- Worst case per source is therefore MaxPerWindow posts per WindowSec, i.e.
    -- 8 per 5 minutes = 1.6/min, against Discord's ~30/min per-webhook ceiling.
    -- Only lookups that actually returned a recommendation are logged; denied,
    -- mismatched and not-found attempts are not, so a prober cannot use the
    -- audit channel itself as the flood.
    Audit = true,

    -- Rolling per-source budget on the command. Spent on every well-formed
    -- request for a record, whether or not it finds one, so probing at ids that
    -- miss costs exactly as much as a real lookup; usage mistakes and hard
    -- denials are free. The 5s cooldown in Config.RateLimits only spaces
    -- requests out, it does not stop a patient loop, and the thing being
    -- protected here is other people's identities. The server console (src 0)
    -- is exempt; ace holders are NOT, deliberately, because an ace can be
    -- granted to a whole group.
    MaxPerWindow = 8,
    WindowSec    = 300,
}

-- Per-source command cooldowns (seconds).
Config.RateLimits = {
    record   = 3,
    expunge  = 10,
    sentence = 5,
}
