-- Fixture for the harness self-check ONLY. Deliberately not valid Lua, so the
-- self-check can prove T.loadFile fails at COMPILE time rather than running a
-- partially parsed file.
local x = = 1
