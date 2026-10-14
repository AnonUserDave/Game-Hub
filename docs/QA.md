# Native checkpoint validation

## Owner's M1 checkpoint

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

## Son's M5 checkpoint (development checks, not M1 acceptance)

2026-10-13, M5 MacBook Pro / 24 GB / macOS 26.3, optimized arm64 build, windowed (2720 × 1782 backing pixels). None of this substitutes for the M1 acceptance run.

| Check | Evidence and outcome |
| --- | --- |
| Reproduction | `build.sh`, 23 Swift and 18 Python tests and `prepare_pga2005.py` reproduced the previous checkpoint before changes; PGA 2005 ZIP SHA-256 matched |
| Practice forest/camera fix | Visually confirmed in the native UI: trees line the course at their positions; tee sightline clear |
| Color space | Live views were far darker than offscreen SceneKit snapshots; switching the MTKView attachment to `bgra8Unorm_srgb` matched them (practice, Pebble Beach, Lab) |
| Pebble Beach load | Hub entry loads all 18 hole indexes and hole 1 buffers off the main thread in a few seconds; loading overlay hides placeholder HUD |
| Pebble Beach visuals | Offscreen 2560 × 1600 4× MSAA tee views of all 18 holes; hole 18 seawall/ocean on the left, hole 7 point green, Lodge buildings; minimaps oriented tee-up |
| Lies and rules | Tees start on Tee Box; diagnostic shots report original labels (Md Rough, Lt. Sand); full PW from the 18th tee enters Carmel Bay and replays with a penalty |
| Save/restore | Round file named by course identity; relaunch showed "Round restored" |
| Lab | One mirrored hole world at a time; hole switching works; 59–60 FPS after load |
| Frame rate | 59–60 FPS windowed in Pebble Beach and the Lab (HUD telemetry snapshots, not sustained) |
| Memory | Hub idle 54 MB; Pebble loaded 563 MB (peak 632 MB); Lab over golf 776 MB; back at the hub 208 MB; `leaks` 0 after fixing a session retain cycle |
| Floor index | CSR index: PBL 9,110 / TUR 7,128 centroids, zero missing, max error 0.0006 in; build 0.03 s |
| Tests | 32 Swift (snapshot test opt-in) and 19 Python tests pass |

Not checked here: fullscreen 2560 × 1600 on the M1, sustained 30-minute statistics, thermals, controller input in the Pebble module (gameplay input pauses while the app is inactive, so background automation cannot exercise it), and Turnberry gameplay.
