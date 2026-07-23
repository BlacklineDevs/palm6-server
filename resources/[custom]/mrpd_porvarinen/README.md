# mrpd_porvarinen — Mission Row PD interior enhancement

Seamless ymap edit that furnishes the **base-game** Mission Row Police Station in
place (surface level, ~`vector3(406, -975, 28)`). No custom models/textures — it
only repositions base-game props, so there is no streaming or supply-chain risk.

- **Upstream:** [Porvarinen/Police_Main-YMAP-](https://github.com/Porvarinen/Police_Main-YMAP-)
- **License:** MPL-2.0 (see `LICENSE`) — free, redistributable.
- **Modernized:** `__resource.lua` → `fxmanifest.lua`; ymap/xml filenames de-spaced.
- **Source XML:** `source/police_mains.xml` kept for future prop edits.

## Role in the cop buildout
This is MLO #1 of the Direction-B cops-first buildout. The palm6 cop scripts
(`palm6_mdt`, `palm6_evidence`, `palm6_bounty`, duty points) anchor to this
station; their placeholder coords get linked to these rooms during the in-game
placement pass (`/p6tp` + `/coords`). Ships **inert** until the single end-of-
buildout deploy + walkthrough test.

Enabled via `ensure mrpd_porvarinen` in `custom.cfg`.
