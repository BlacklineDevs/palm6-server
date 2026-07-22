Config = {}

-- Prod-inert until the Stage A spike is proven in-game, per PALM6 convention.
-- Flip to true ONLY for a controlled feel-test deploy, then revert.
Config.Enabled = false

-- The component + drawable/texture index the spike garment lives at.
-- REPLACEMENT spike: we overwrite base male-torso jbib drawable 0, so these are the base
-- game's own fixed indices (guaranteed to exist -> no addon appended-index guessing).
--   component 11 = jbib (torso: vest/jacket/top),  drawable 0,  texture 0 (variant 'a').
-- Our stream/ .ytd replaces the texture that base drawable 0 loads; running /threads_spike
-- selects that drawable so OUR generated texture renders.
Config.Spike = { component = 11, drawable = 0, texture = 0 }
