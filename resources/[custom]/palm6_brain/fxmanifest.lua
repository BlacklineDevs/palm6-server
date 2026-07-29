fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'palm6'
-- LIVE IN PRODUCTION. This line used to say "Phase 0 ... no AI yet. Ships DARK",
-- which has been false since 2026-07-22: shared/config.lua has Config.Enabled,
-- NamedEnabled, Director.Enabled (DryRun off), Director.CrimeEnabled, NetPed and
-- Social all true. Only Director.MoneyEnabled is still held dark. Treat every
-- change in this resource as a change to a running production system.
description 'palm6_brain - AI-NPC living world: ambient NPC life, GLM-voiced named NPCs, AI Director (LIVE, goals committing), and the INTEL+ social layer (personas/reputation/witness/gossip/snitch/alibi). LIVE in production; only Director.MoneyEnabled ships dark. See docs/AI-NPC-ROADMAP.md.'
version '0.1.0'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

client_scripts {
    'client/main.lua',
    -- Gate states below are the AS-SHIPPED values, re-read from shared/config.lua
    -- (and each file's own local CFG) at edit time. They were stale for months.
    'client/chatter.lua',    -- Phase 5: ambient NPC-to-NPC chatter (LIVE, local CFG.Enabled = true)
    'client/netped.lua',     -- Networked server-owned peds: owner-applies-task (ARMED, nothing spawns until /netpedtest)
    'client/talk.lua',       -- INTEL+ talk-to-ANY-ped: target any ped -> GLM dialogue (LIVE)
    'client/crimewatch.lua', -- INTEL+ detect player crimes vs peds -> Social event bus (LIVE)
}

server_scripts {
    'bridge/sv_framework.lua',  -- qbx_core adapter (police alert bus) — before director
    'server/main.lua',       -- named-NPC GLM dialogue + the `BrainMeter` LLM call meter (defined here, used by director/talk)
    'server/director.lua',   -- Phase 2b: AI Director spine (LIVE, DryRun off, Crime on, Money held dark)
    'server/memory.lua',     -- Phase 3: NPC memory (attaches to Director seam — after director)
    'server/factions.lua',   -- Phase 4: factions/retaliation (LIVE, local CFG.Enabled = true; attaches to Director seam - after director)
    'server/netped.lua',     -- Networked server-owned peds: spawn + state-bag goals (ARMED, inert until /netpedtest)
    'server/social.lua',     -- INTEL+ social layer FOUNDATION: the `Social` global (LIVE)
    -- INTEL+ feature modules (attach to the Social seam — MUST load after social.lua):
    'server/witness.lua',    -- peds witness player crimes
    'server/gossip.lua',     -- witnessed info spreads NPC-to-NPC with fidelity decay
    'server/snitch.lua',     -- witnesses report crimes to police dispatch
    'server/alibi.lua',      -- static NPCs vouch for a player's whereabouts
    'server/talk.lua',       -- talk-to-ANY-ped: GLM dialogue through the Social persona/context
    'server/crimewatch.lua', -- player-crime -> Social event bus (auto-triggers witness/gossip/snitch)
}

dependencies {
    'ox_lib',
}
