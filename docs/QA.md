# Native checkpoint validation

2026-10-13, original development M1 MacBook Air / macOS 15.6. This is a development checkpoint, not certification of an original-game rewrite.

| Check | Evidence and outcome |
| --- | --- |
| Native build | Optimized arm64 Swift/Objective-C app compiled directly with installed Xcode SDK; no emulation or compatibility runtime |
| Hub startup | Native UI opens immediately from bundled catalog; selecting the workspace through NSOpenPanel grants library access and finishes loading |
| Catalog | 17 supplied-source entries plus a separately labeled golf development module; intended Space Invaders shooter explicitly records mismatched pinball firmware |
| Practice input/gameplay | Native UI shows clubs, swing, ball lie/stroke/distance updates, pause and return; deterministic simulation tests cover penalties, putting and progression |
| Wired Fusion Pro | User exercised A/B/X/Y, triggers and sticks and reported working controls; native diagnostics showed the exact USB path and physical RT release event |
| Fullscreen resolution | Actual Metal attachment telemetry reads 2560 × 1600, 4× MSAA, in practice and original course viewer; desktop scaling remains unchanged |
| Original course viewer | PBL/TUR original indexed meshes, UV/material/texture paths load; course switching and elevation/original palette toggle work |
| Performance snapshots | Practice and original viewer reach roughly 55–60 FPS after loading; sustained averages, frame-time percentiles and gameplay profiling remain unmeasured |
| Source conversion | All 11 original primary course meshes pass bounds/index checks; PBL/TUR one-command asset preparation succeeds |
| Texture decoding | Independent pixel comparison passes eight original TCL DDS textures across 10,754,048 RGBA channels |
| Floor geometry | 9,110 PBL and 7,128 TUR nonvertical source-triangle centroid queries: zero missing, maximum errors below 0.001 original inch; vertical walls are outside this floor-height fixture |
| Tests | 23 Swift and 18 Python tests pass, including the final scene/camera regression across all three generated holes |

The practice forest originally collapsed to the origin during SceneKit flattening. A source-scene diagnostic identified the exact geometry; the fix retains world transforms and adds regression checks for bounds and clear initial camera sightlines. Final native UI confirmation of that fix is required before the visual fix is considered manually verified.

Remaining physical-input checks include shoulders/D-pad/menu, every gameplay mapping, held buttons across transitions, focus loss and hot unplug/replug. Remaining original-game work includes playable original holes, original physics/rules, saves, characters/animation/audio/modes, shaders/water/vegetation and reference comparisons.
