fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'EvThatGuy'
version '0.1.0'
description 'gtarp economy — staff scoreboard aggregating the crime economy (read-only)'

server_scripts {
    'shared/config.lua',
    'bridge/sv_game.lua',  -- native/export adapter — before server logic
    'server/main.lua',
}

-- No hard deps: every crime resource it reads is a SOFT sibling GetSummary()
-- export (offline ones just show "offline"). No DB — this resource writes
-- nothing.
