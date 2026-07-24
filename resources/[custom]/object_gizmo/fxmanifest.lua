fx_version 'cerulean'
game 'gta5'
lua54 'yes'

version '2.1.0'
-- Vendored from DemiAutomatic/object_gizmo (GPL-3.0) for palm6_mapeditor.
-- Removed client/test.lua and the version-check server script.

client_scripts {
    'client/gizmo.lua',
}

shared_scripts {
    '@ox_lib/init.lua',
}

files {
    'locales/*.json',
    'client/dataview.lua',
}

dependencies {
    'ox_lib',
}
