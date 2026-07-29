-- ============================================================
--  prop_spawn  —  dev-only test helper
--  FiveM has no native /object command, so this gives you one.
--
--  NOT PRODUCTION SAFE, AND NOT REMOVED. This resource is still present in
--  the repo and its three commands (/prop, /crate, /clearprops) are
--  registered client-side with NO ace gate and NO server check, and
--  client.lua spawns NETWORKED colliding objects (CreateObject isNetwork
--  = true). The only thing keeping it off the box is the `stop prop_spawn`
--  line in custom.cfg, which works because custom.cfg execs after the panel
--  server.cfg's ensure. Do not remove that stop line while the panel still
--  ensures this resource. Any comment claiming prop_spawn "was removed" is
--  wrong: the files are right here.
-- ============================================================
fx_version 'cerulean'
game 'gta5'

author 'YourName'
version '1.0.0'
description 'Dev command to spawn/clear custom props for testing'

client_script 'client.lua'
