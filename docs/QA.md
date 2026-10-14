# Native checkpoint validation

## Remaining-rewrite checkpoint on the son's M5

2026-10-13, M5 Pro MacBook Pro / 24 GB / macOS 26.3, native ARM64. No original game was executed or emulated. No M1 performance or physical controller acceptance was performed.

| Check | Evidence and limits |
| --- | --- |
| Build and unit checks | Final combined suite: 145 Swift XCTest, 3 expected skips (two opt-in snapshots and no audio output); 179 Python tests pass. Final Night Driver source-order regressions are included. Optimized native ARM64 build passes; final small Conflict layout edits compile but still await rebuilt UI check. |
| Breakout native UI | Launch/setup, short Space tap serving, held right-paddle input, Escape pause, save and return to library. Reopen/resume restored team 1, score 0 and four balls, paused. These are native development checks, not cartridge comparisons. |
| Conflict 2500 native UI | Scenario setup, 13×9 map and original prepared tactical symbol displayed. Keyboard F fired with power 100; E advanced to turn 1; energy 22531 became 17531. Escape disabled game commands. Save/return/reopen restored turn 1, energy 17531 and tactical view. |
| Input transitions | Synthetic tests cover focus loss/held return, controller identity changes/disconnection and action suppression during pause/setup until release. Short keyboard taps remain queued until one simulation tick. No physical Fusion Pro or simultaneous multiplayer devices tested. |
| Static source recovery | Selected DOS3.3/T64/XEX/ROM containers verify archive/member identities and ranges before decoding. Original game data/listings/art stay in ignored Library paths. Conflict's BASIC program is recoverable source, correcting the initial inventory claim. |
| Windows source data | Offline PGA2004/THPS2/THUG/THUG2 preparation and structural collision tests passed. These are asset-loader checks; no skating gameplay/rendering or PGA2004 runtime is established. |
| Runtime limits | Breakout clock uses fixed 60 Hz steps, bounded stall catch-up and no progression while unfocused/paused. Saves are size/version/source fenced. Native collision package and offline asset bounds have malformed-input tests. No sustained FPS, physical-footprint/thermal/swap or original-timing claim follows from these functional checks. |

All completion gates remain in [OTHER_REWRITES.md](OTHER_REWRITES.md). The owner's M1 remains paused; M5 observations cannot establish release acceptance.

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

Golfer branch follow-up, 2026-10-13, Apple M5 Pro MacBook Pro with 24 GB: optimized native ARM64 build passed; `PGAOriginalGolferTests` passed with locally prepared original media; 28 Python golfer decoder tests passed. The full Swift suite ran 45 tests with one failure in the existing `PGAAudioTests.testEnginePlaysSwingImpactAndAmbience` because `AVAudioEngine` could not create an output component in this test environment. The opt-in golfer tee snapshot could not render because `MTLCreateSystemDefaultDevice()` returned nil. No live visual result or M1 performance claim follows from these checks.

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

## Son's M5 checkpoint, second wave (development checks, not M1 acceptance)

2026-10-13, same M5 and build settings. Static research results were never checked against a running original game.

| Check | Evidence and outcome |
| --- | --- |
| Audio rules | Swift tests: script operators, swing sounds by club/lie/power priority (e.g. driver off the tee ≥ 90 % → "tee perfect"), collision sounds by surface id and impact strength (soft/hard green, gated below 0.1), gallery mapping, every referenced file prepared |
| Audio engine | Smoke test on the M5 starts AVAudioEngine, preloads gameplay sounds, plays a swing plus Pebble hole 7 ambience at the tee, stays under the 40 MB cache cap and frees buffers on stop |
| Tri-click meter | Swift port matches the Python reference angle and state every 16 ms frame across eight scenarios (all levels, putter, overswing, missed clicks, two-click) |
| Meter dial | Offscreen HUD render: lit art from 4:30 to the marker, white power tick at 80 %; round setup shows the four difficulty speeds |
| Research decoders | Ball flight (21), objects (16), golfer (22), cameras/meter (22) Python tests pass with and without media |
| Tests | 45 Swift (2 opt-in snapshot tests skipped) and 140 Python tests pass |

Not checked in this wave: live play with sound in the native UI, M1 anything.

## Son's M5 camera integration checkpoint (development checks, not M1 acceptance)

2026-10-13, M5 Pro MacBook Pro / 24 GB. `./Tools/build.sh` compiled a native arm64 app. `./Tools/test.sh -XCTest GameHubTests.PGACameraDirectorTests` passed all five tests, including loading the prepared original camera scripts on this machine. Fixtures check fixed-camera offsets, source zoom, the unusual "lacks any bit" operator, tee-impact rule matching, attachment reset and changing modes during flight. No rendered camera view or 30-minute M1 session was checked. Predicted landing, flight progress and unsupported camera commands remain approximations or missing features.

## Son's M5 physics branch checkpoint (development checks, not M1 acceptance)

2026-10-13, M5 Pro MacBook Pro / 24 GB / macOS 26.3. `python3 Tools/make_ballflight_fixtures.py --check` confirmed 125 golden scenarios. The branch passed 47 Swift XCTest (2 opt-in snapshots skipped), 99 Python tests and an optimized native arm64 build. The simulation bridge matches direct `CBallFlight` at 60 Hz; the deterministic 18-hole original-course test passed. These are checks against a static reconstruction, not against a running original game. Live UI, controller behavior, original-game comparisons and M1 sustained performance were not checked for this branch.

## Son's M5 scenery branch checkpoint (development checks, not M1 acceptance)

2026-10-13, M5 Pro MacBook Pro / 24 GB / macOS 26.3. The branch passed the optimized arm64 build, 34 ordinary Swift XCTest (2 opt-in snapshot tests skipped) and 96 Python tests. Its opt-in GPU snapshots captured all 18 Pebble tee views and Turnberry holes 1, 9 and 18 at 2560 × 1600 with 4× MSAA, asserting sky, vegetation and nonzero Metal draws. Pebble 1/9/18 and Turnberry 1 images were inspected. The scenery submitted 14–75 draws per Pebble tee view, with a maximum of 516,381 vertices on hole 4. These are draw counts, not FPS, frame-time, memory or thermal measurements. Exact original lighting and M1 acceptance remain unverified.

## Son's M5 integrated checkpoint (development checks, not M1 acceptance)

2026-10-13, M5 Pro MacBook Pro / 24 GB / macOS 26.3. After merging physics, original scenery, original golfer and the native camera director, `./Tools/build.sh` passed for native arm64. The combined `./Tools/test.sh` passed 62 Swift XCTest with 3 skips (two opt-in snapshots and one audio output check: CoreAudio reports no default output in this test environment). `python3 -m unittest discover -s Tests -p 'test_*.py'` passed 149 tests. The 125-scenario ball-flight fixture check passed. A one-command `Tools/prepare_pga2005.py --courses PBL` smoke run regenerated original terrain, 45,063 trees, 8 sky domes, 82 HUD images, 11 golfer clips and all 6 camera scripts; the camera decoder verified Engine.dll constants. Missing audio output now leaves the golf session playable without audio. No fresh combined live UI, source-game comparison, memory profile or 30-minute M1 run was performed.

An opt-in combined snapshot run for Pebble hole 1 passed the original HUD capture. The original tee-view capture skipped because this test process had no Metal device. It now reports that environment limitation explicitly; the combined GPU rendering path remains unchecked here. The scenery branch's separate GPU captures above do not establish combined rendering or M1 performance.

## Son's M5 live UI follow-up (development check, not M1 acceptance)

2026-10-13, M5 Pro MacBook Pro / 24 GB / macOS 26.3. The integrated native app rendered Pebble Beach hole 1 at a reported 2720 × 1782 Metal target with 4× MSAA. The live view showed original terrain, sky, vegetation, HUD and skinned Tiger; the reported FPS snapshots varied (32 at the tee, 60 in a later view), so they are not a sustained performance result. The user and live view identified an oversized ball and occasionally inverted or tilted camera. Code inspection found a 0.13 m render radius versus the simulation's 0.02135 m radius, plus SceneKit's one-argument look-at producing negative world-up after steep camera moves. The follow-up uses physical ball size/height on original courses and explicit world-up camera orientation. Renderer regression tests cover both; the full Swift suite passed 64 tests with 3 expected skips. No M1 run was performed.

After a clean quit and reopen of the rebuilt app, resuming the saved Pebble round at hole 1 / light rough / 45 yd showed a small resting ball and an upright Auto camera at the reported 2720 × 1782, 4× MSAA target. This checks one live situation on the M5; other scripted cuts, sustained frame rate and M1 behavior remain unverified.

## Son's M5 hole overview and short-chip camera follow-up (development check, not M1 acceptance)

2026-10-13, M5 Pro MacBook Pro / 24 GB / macOS 26.3. The hole overview grew from 175 × 210 to 210 × 252 points; ball, aim and pin have separate markers, and out-of-frame marker positions are kept inside the map. The map and 3D aim marker now share one aim point. In a reopened saved Pebble Beach hole 1 round, the enlarged original-geometry map and all three markers were visible at a reported 2720 × 1782 Metal target with 4× MSAA. The saved shot was not played during this UI check.

Auto short-wedge shots now use chip/pitch flags and a power-scaled landing estimate, with a behind-ball follow view through flight and a brief touchdown hold. The synthetic partial sand-wedge regression checks the ball stays ahead of the camera through landing and a full swing retains its scripted cut. `./Tools/build.sh` produced a native arm64 executable; `./Tools/test.sh` passed 66 XCTest with 3 expected skips. A live short chip, other camera cuts, original-game comparison, and sustained M1 performance remain unverified.

## Son's M5 integration, difficulty and input-focus follow-up

2026-10-13, M5 Pro MacBook Pro / 24 GB / macOS 26.3. The hub now rechecks an external build's executable ARM64 slice before launch; two synthetic tests cover a build changed after catalog load and an app bundle without executable permissions. Original-course shot launch and condition calculations now use the chosen round difficulty; a synthetic bridge compares all four levels to direct reconstructed `CBallFlight` initialization. PGA held-key aiming and controller actions are gated on its key window, with button history updated while focus is elsewhere. These input transitions were inspected in code but not exercised with the physical Fusion Pro.

`./Tools/test.sh` passed 69 Swift XCTest with three skips (two opt-in snapshots and no CoreAudio output), and `python3 -m unittest discover -s Tests -p 'test_*.py'` passed 149 tests. `./Tools/build.sh` produced `Game Hub.app/Contents/MacOS/GameHub`, identified by `file` as a Mach-O 64-bit arm64 executable. Weather/time preset research checked the local `Engine.dll` disassembly and all 40 installed INIs; it is static evidence, not rendered output. No live original-game, Fusion Pro, or M1 test was performed at this checkpoint.


## Remaining-rewrite source and native-session checkpoint

2026-10-13, freshly identified **Mac17,9 / Apple M5 Pro / 24 GB / ARM64**, macOS26.3 development only. The mandatory M1 Air /8GB /2560×1600 target is unchanged and paused. No original executable or emulated game ran.

`./Tools/test.sh` passed **192 XCTest, three expected skips** (two opt-in golf snapshots, unavailable CoreAudio output). `python3 -m unittest discover -s Tests -p 'test_*.py'` passed **193 tests**. Final optimized `./Tools/build.sh` passed; `file` identifies the app binary as Mach-O64-bit ARM64. Logs remain local under `/tmp/gamehub-retro-integration-{swift,python,build}.log`. Eleven new integration regressions cover both sticks across pause/focus/reconnect, short taps until the proper source schedule, original key maps, ordered Crossfire input/stop at intersections, changed media before launch, malformed schedule fractions, HUD bounds and contiguous character pixels.

| Native M5 UI check | Observed result |
| --- | --- |
| Catalog |24 entries:17 original source records and seven development prototypes; no verified games. New original-media packages validate before launch. |
| Apple Panic | Original player/creature masks and reconstructed ladders/floors displayed. Start, heldK for250ms, Escape, save, library return, reopen/resume passed. Save state retained X82/Y160,15 half-dispatches, level1/lives3/score0; resume was paused. Floor/ladder/hole art/color/font/timing remain provisional. |
| Crossfire | Original masks displayed. Space stop plusF held750ms produced one directional shot (ammo35→34). Pause/save/return/reopen restored34 paused. Final renderer showed all four source kind0 collectibles after XOR composition, with source anchors/explosion order. HGR field/color/font/audio/cadence/startup remain unqualified. |
| Night Driver | Original instructions/road/car/HUD/digits displayed. Keyboard start andA held2.5s reached source speed16/time98. Pause/save/return/reopen restored16/98 paused. Final single-bitmap renderer visibly removed per-character seams and retained crisp car/road/HUD pixels. Real clocks, RGB/VIC crop, audio and attract/high-score sequences remain open. |
| Revised Breakout | Setup displayed monochrome switch; old approximate save was unavailable after schema2 migration. Start, short Space serve, Escape, source digit HUD, save/return/reopen restored the playing round paused with five shared rounds and score0. Source logical geometry/colors/HUD were visible; source scanline layout/rotation and calibrated output remain unqualified. |

Static source checkpoints separately passed25 Apple Panic core/seven decoder checks;26 Breakout core/five media checks, including full2048-byte classification; and eight THPS2/six Python checks, with ten original scene constructions. THPS2's isolated probe had no Metal device, so no rendered pixels are claimed. Its original content/trigger/blockmap loading is not skating gameplay.

No physical Fusion Pro, multi-controller, original behavior/visual/audio comparison, sustained performance/memory/thermal run or M1 acceptance was performed. Source-dependent titles remain development reconstructions; the all16-title goal is active and unfinished. Originals/prepared assets/builds stay out of Git.

## Son's M5 conditions, rules and presets follow-up (development checks, not M1 acceptance)

2026-10-13, M5 Pro MacBook Pro / 24 GB / macOS 26.3. Static research results were never checked against a running original game.

| Check | Evidence and outcome |
| --- | --- |
| Club bag | All 14 clubs map onto original club indices; saved rounds from the 8-club bag keep their club (raw values 0–7 unchanged) |
| Conditions | Setup conditions decode from saves made before they existed; tail and head wind of 25 mph change a Pebble 7-iron carry by more than 4 % each way; the original `Wind1` rows, integer mph and swing about a fixed base direction are checked across 18 holes, and a restored round reproduces the wind |
| Rules | `IntersectLine` codes; every Pebble pin, aim point and selected tee is in play under the compiled lines; points 400 m off hole 1 are out of bounds; a 7-iron pulled into Carmel Bay on 18 costs one stroke and drops back along the line onto a playable lie |
| Weather and time | Selector cases from the weather note (row boundaries, late-hole slot clamp); terrain light formula; offscreen 2560 × 1600 hole 18 renders under clear afternoon/sunset, clear sunrise, foggy noon and heavy-rain afternoon show the expected sky domes and fog |
| Setup layout | Offscreen 1280 × 800 render with 11 courses, four players, weather/time/wind/greens/rough rows fits without scrolling |
| Effects | Offscreen renders of sand blast, grass clippings, divot and water splash bursts from the original sprites |
| Tests | 201 Swift XCTest (4 opt-in or environment skips) and the Python suite pass |

Not checked: live play of these features in the native UI, M1 anything.
