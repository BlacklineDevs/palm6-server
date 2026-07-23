fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'palm6'
description 'palm6_brain — Phase 0 of the AI-NPC living world: curated ambient NPC life (no AI yet). Ships DARK. See docs/AI-NPC-ROADMAP.md.'
version '0.1.0'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

client_scripts {
    'client/main.lua',
    'client/chatter.lua',    -- Phase 5: ambient NPC-to-NPC chatter (dark)
    'client/netped.lua',     -- Networked server-owned peds: owner-applies-task (dark)
    'client/talk.lua',       -- INTEL+ talk-to-ANY-ped: target any ped -> GLM dialogue (dark)
    'client/crimewatch.lua', -- INTEL+ detect player crimes vs peds -> Social event bus
}

server_scripts {
    'bridge/sv_framework.lua',  -- qbx_core adapter (police alert bus) — before director
    'server/main.lua',
    'server/director.lua',   -- Phase 2b: AI Director spine (dry-run, gates dark)
    'server/memory.lua',     -- Phase 3: NPC memory (attaches to Director seam — after director)
    'server/factions.lua',   -- Phase 4: factions/retaliation (attaches to Director seam — after director)
    'server/netped.lua',     -- Networked server-owned peds: spawn + state-bag goals (dark)
    'server/social.lua',     -- INTEL+ social layer FOUNDATION: the `Social` global (dark)
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
