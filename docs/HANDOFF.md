# Continue the Game Hub project

## Objective and non-negotiable scope

Build one native macOS game hub and faithfully rewrite all supplied games. Start with Tiger Woods PGA Tour 2005. Preserve the original visual style while rendering at the M1's native 2560 × 1600 resolution with good performance. Support keyboard/trackpad and the owner's wired Xbox-style controller, and make future native games easy to integrate. Do not use emulation or compatibility layers. The owner requested sub-agents and authorized useful Ghidra/Hopper installation and pushing work to `AnonUserDave/Game-Hub`.

Executable byte identity across x86 Windows and ARM64 macOS is impossible. Track specific asset, behavior, visual, and performance equivalence instead. A prototype must never be labeled a completed port.

## Handoff state and required target

Work on the owner's laptop is paused at his request. His son continues on an M5 MacBook Pro with 24 GB RAM. The mandatory runtime target remains the owner's M1 Air, 8 GB, 2560 × 1600. Read [the binding hardware constraint](M1_TARGET_CONSTRAINT.md) and [status](STATUS.md). Do not start background work on the owner's laptop.

The 2026-10-13 son's checkpoint added playable original gameplay on all 11 courses, corrected the course model (each hole is its own world; the source is left-handed), applied statically recovered patch-selection and surface rules, fixed a dark-image color-space bug and a session memory leak, and added round setup, hot-seat multiplayer, match play and skins. The second wave added native original audio, the exact original tri-click meter, and static decodes of the ball flight, trees and sky, the golfer, and the camera director. Original-course shots now use a Swift port of the statically reconstructed `CBallFlight`; generated practice keeps its provisional model. All of it was checked on the M5 only. Agreement between Swift and Python is not comparison with a running original game.

The decoded Tiger 01 mesh, textures, clubs and swing clips now load on a worker and replace the generated golfer during original-course play when local prepared media are present. One rig is reused across holes. A native build and focused scene/shot test passed on the M5 Pro; live appearance and animation alignment were not checked because offscreen Metal access was unavailable in that test environment.

The 2026-10-13 follow-up routes the round's selected difficulty into original-course launch and condition calculations, rechecks external ARM64 builds immediately before launch, and gates PGA keyboard/controller actions on the game window's focus. Static research mapped all 40 weather/time render presets, including per-hole blending and fifth-slot clamping ([research note](research/PGA2005-WEATHER-TIME.md)); the native scene has not applied those presets. The Swift/Python suites passed on the M5 development machine, but no live Fusion Pro transition, original-game comparison, or M1 acceptance was performed for this follow-up.

The owner requested an **active goal to complete all 16 other supplied titles/editions**. Continue with [OTHER_REWRITES.md](OTHER_REWRITES.md); PGA2005 remains separate. Breakout and Conflict2500 have native development gameplay and source-specific saves. Breakout's follow-up reconstructs prior-display pixel contacts, authored ordering, split knob sampling, ascent steering history, catch/serve fractions, timed no-rebuild behavior, deferred scored-wall/team transitions, shared five-round ending, alternating scoreboard and a distinct 65,536-frame selection return. Original digit masks stay local; color/audio parameters are source-derived, while RGB conversion/audio output remain unqualified. Snapshot schema2 intentionally rejects old approximate Breakout saves. Its 26 Swift/five Python checks pass on M5; [the ledger](research/BREAKOUT.md) records the ROM/manual disagreement and full static coverage. Intraline graphics, rotation/attract display, separate split-paddle catch buttons, original cadence/comparison, physical input and M1 acceptance remain open. Earlier live Breakout/Conflict checks predate these fidelity corrections.

`prepare_retro_media.py` decodes selected DOS3.3/T64/XEX/container data without execution. It recovered the actual309-line Conflict BASIC program, correcting the previous no-source claim; original listings/symbols stay ignored. Source-backed Asteroids arithmetic/control primitives and Windows PKR/PRE/CAB/collision-data tools are separate research foundations and do not register playable titles. Apple Panic, Crossfire and Night Driver reconstruction is underway. Keep prepared original JSON as well as binaries/textures ignored (`Library/Prepared/`, `Library/Imported/`, `Library/SourceMedia/`).

The three Asteroids editions have source-bound native routines in `AsteroidsCore.swift`, selected-revision preparation, separate bank/load Ghidra profiles and [a precise research ledger](research/ASTEROIDS.md). Their 12 Swift/5 Python checks pass on M5, including all 65536 Atari2600 RNG states. Next work is each edition's actual main loop and entities; the helpers intentionally do not register generic shared Asteroids gameplay.

Windows preparation remains `prepare_other_windows.py` / `neversoft_assets.py`; THUG/THUG2 collision packages retain the64MiB source/count limits. THPS2 now has bounded native PSX v4/TRG/blockmap loaders and an original SceneKit builder in `THPS2Original{Level,BlockMap,Scene}.swift`. `python3 Tools/decode_thps2.py --all-levels` prepares eight career/two secret environments, using actual startup spool/source symbol definitions for file pairing and texture IDs rather than table position. All ten original-paletted and supplied-PC-BMP scene constructions pass an isolated optimized ARM64 probe; its Metal device is nil, so no rendered pixels are claimed. Eight shared Swift tests and six Python tests pass on M5, including original scenes and bounded blockmap queries. The [THPS2 ledger](research/THPS2.md) records 263/282 qualified PSX (19 rejected with identities/reasons), all32 TRG/20,220 nodes, native limits and remaining unknown flags/opcodes. No playable skating module is registered. Continue title-specific locomotion/collision/tricks/scripts/goals, actors/animation/UI/modes/multiplayer/saves, source comparison and M1 acceptance. Missing PGA2004 cabinet volume3 and version4 terrain remain open.

Apple Panic, Crossfire and Night Driver now have separate **native development** hub entries and source/version-validated saves in `RetroReconstruction{Support,Sessions,Views}.swift`. The library preserves17 source records plus seven prototypes (24 total). The new modules require prepared original graphics, validate bounded files off the main thread and recheck them before launch; missing packages do not launch an unrelated generated game. Input queues preserve short taps until source updates, controller latches require release after focus/pause/reconnect, and source keyboard mappings have explicit adapters. Every restored game starts paused. Timers/load tasks stop on return.

Apple Panic retains the supplied hole/slot/capture/crush/chain-scoring corrections, corrected dig pointers and actual I/J/K/M/A/S controls plus Ctrl-R restart. Its original masks load from `Library/Prepared/apple-panic/apple-panic.json`; floor/ladder/hole drawing, HGR color/font/audio/screens, source ROM randomness/clock and visible fall/score sequences remain unfinished. M5 live movement/save/return/restore preserved playerX82/Y160, level1/lives3/score0 after15 source half-dispatches. See [the ledger](research/APPLE-PANIC.md).

Crossfire loads15 locally decoded masks, including the original kind0 bonus, uses source XOR composition/bonus anchors and source explosion sequence0/1/2/1/0. Left/right sticks adapt independent movement/shooting; keyboard I/J/K/L and E/S/D/F remain source semantics. Source Space stops at the next intersection; pause/focus queues a stop for controller movement without changing that rule. The provisional clock is960 source iterations/second. A live M5 shot reduced ammo35→34; save/return restored34 paused. Selected loader startup, original HGR field/artifact colors/font/screens/audio/timing and all original/physical/M1 comparisons remain open. See [the ledger](research/CROSSFIRE.md).

Night Driver renders original40×25 characters, authored instructions, road/car/crash/HUD and digit data as a single bounded320×200 bitmap, avoiding per-tile interpolation seams. Native A/L/semicolon and F1/F3 modes, arrows, stick/paddle and drag adapters, pause/save/return are present. Rightward drag/stick use decreasing source paddle readings consistently. Controls and interrupt schedules stay independent and merge in time order; taps wait for their own schedule. **120 foreground updates/50 interrupts per second and0.2s crash stages are explicit development pacing, not qualified original clocks.** Saves include source state, mode and fractional schedules. Live M5 acceleration reached speed16/source time98; paused save/return/restore worked. Source clocks, RGB/VIC crop, audio, attract/melody/visible scoring behavior, original comparisons, physical input and M1 gates remain open. See [the ledger](research/NIGHT-DRIVER.md).

The combined checkpoint passes192 Swift XCTest (3 expected skips),193 Python tests and optimized ARM64 compilation on the M5. Eleven integration regressions cover source controls, pending taps, both analog sticks across focus/pause/reconnect, source stop behavior, changed media at launch, HUD bounds and batched pixel continuity. These are native/static and M5 UI checks, never source-game comparison or M1 acceptance. Continue every unfinished row in [OTHER_REWRITES.md](OTHER_REWRITES.md); no title is complete.

## Development environments

Asteroids8-bit now has its own source-VBI/foreground native lifecycle, selected
mode/four-player rules, source thrust/shots/special controls, collisions/splits/
waves/UFO/player transitions, explosions, sound parameters and source-bound
snapshots. Its original masks/tables are bounded and canonical-hash checked.
17 isolated Swift/four Python checks pass on M5. RANDOM bytes and35 startup
fractional-coordinate pairs are explicit; no hardware PRNG is invented. The
core retains alternating callback halves and five-VBI foreground passes,240/
480-frame waits and transactional sample exhaustion. **No playable entry yet**:
finish options/session/input, original menus/attract/high scores/OS/font,
raster/death-carry/region/sound details, then source/physical/M1 gates. See
[the8-bit ledger](research/ASTEROIDS-8BIT.md).

After all three edition cores, the combined M5 suite passes262 Swift XCTest
(five expected skips: four opt-in golf captures and no CoreAudio output),245
Python tests and optimized ARM64 build. The new Asteroids checks total58 Swift
and16 Python cases. Logs: `/tmp/gamehub-asteroids-native-{swift,python,build}.log`.
No original-game or new native UI check was performed for this source-loop
checkpoint; no M1 work occurred. The all16-title goal stays active.

Asteroids7800 now has a separate native33-object/four-mode source loop,
version/source-bound snapshots and44 tables/813 original graphics records in a
bounded267,887-byte package with canonical content hashing.16 isolated Swift/
five Python tests pass on M5, including196,608 damping states and10,000 passes
per mode. Startup requires explicit prior RNG RAM/timer/provenance. The source
schedule keeps display interrupts separate from main passes (two DLIs per
pass); original region/cadence is unqualified. There is **no playable hub entry
yet**. Resolve pair-order/terminal details, real startup/optional high-score
firmware, complete presentation/audio and native session integration before
original/physical/M1 acceptance. See [the7800 ledger](research/ASTEROIDS-7800.md).

Asteroids2600 now has its own native playing dispatcher and bounded, canonical
hash-checked21-table/29-mask package. It covers all66 selected variation values,
packed source movement, ship/two player missiles/saucer, deferred collisions and
splitting, wave density, thrust/special actions, BCD scores/bonus lives/death and
alternating players; version/source-bound snapshots validate indexed state.
25 isolated Swift/seven Python tests and660,000 native frame steps pass on M5.
The selected movement-table anomaly is retained. There is **no playable hub
entry yet**; finish original presentation/audio/clocks and session/input/save/
launch/return integration, then every original/physical/M1 gate. See
[the2600 ledger](research/ASTEROIDS-2600.md). Original data stays ignored.

Dig Dug's supplied C64 `DIG DUG+` program now has a bounded first-party two-layer
decoder, `Tools/decode_dig_dug.py`. It recovers a23,044-byte crack intro,19,333
known relocated packed bytes and the24,576-byte body containing the trainer
at `$7090` and game entry `$8000`. Every stage is size/hash fenced. Unknown
intro RAM is excluded and the four optional trainer patches remain unapplied.
Six Python tests and selected-media preparation pass on the M5. This is static
content recovery with **no native Dig Dug gameplay entry**. Direct Ghidra has
mapped the foreground/interrupt dependencies; next reconstruct source game,
terrain/entity/pump/rock/bonus rules, modes/controls/assets/audio/saves/session
and close all comparison/physical/M1 gates. See [the Dig Dug ledger](research/DIG-DUG.md)
and [the hash/count receipt](research/evidence/dig-dug-unpack.json).

**Son's M5 (current).** macOS 26.3, Xcode at `/Applications/Xcode.app` (Swift 6.3.1), Homebrew Python 3 with Pillow, Homebrew `unshield` 1.6.2 and OpenJDK 21/26. REA 6.4.0 is the global MCP server (`/opt/homebrew/bin/rea`), with a working Ghidra provider at `~/Desktop/Tools/ghidra_12.1.2`. REA's Ghidra session timed out during Engine.dll auto-analysis; direct `Tools/analyze_pga2005_ghidra.py` headless runs worked (88 s auto-analysis). Extracted DLLs are in the ignored `Library/SourceMedia/pga2005/engine/Executable`; the Ghidra database is in `Library/Research/ghidra-projects/pga2005-physics`. Git identity: the son's own.

**Owner's M1 (paused).** Apple M1 MacBook Air, 8 GB RAM, macOS 15.6. Xcode is installed, but `/usr/bin/swift`, `git`, `python3` and `xcrun` are blocked by an unaccepted Xcode license; do not accept agreements for the user. The build scripts call `/Applications/Xcode.app/.../XcodeDefault.xctoolchain/usr/bin/swiftc` and the SDK directly, and `DEVELOPER_DIR` overrides them. Older notes mention Codex-bundled tools under `/Users/alexrogers/.cache/codex-runtimes/`; they exist only on that laptop.

## Code map

| Area | Files |
| --- | --- |
| Hub UI, library and native launch | `Sources/GameHub/HubView.swift`, `GameModel.swift`, `DetailSheets.swift` |
| Controller discovery/navigation | `Sources/GameHub/ControllerManager.swift`, `FusionController.swift`, `Sources/FusionUSB/` |
| Built-in module registry | `Sources/GameHub/NativeGame.swift` (seven development modules, including `apple-panic-native-development`, `crossfire-native-development`, `night-driver-native-development`) |
| Retro native development | `BreakoutCore.swift`, `ConflictCore.swift`, `ApplePanicCore.swift`, `CrossfireCore.swift`, `NightDriverCore.swift`, `RetroGameViews.swift`, `RetroReconstruction{Support,Sessions,Views}.swift`; per-title limits in `docs/research/` |
| Golf simulation (Foundation only) | `PGACore.swift` (simulation, rules, multiplayer turns, game types, snapshots, event queue), `PGABallFlight.swift` (reconstructed original flight and terrain/frame adapter), `PGATerrain.swift` (terrain protocol, original surface properties and sound ids), `PGASwingMeter.swift` (original tri-click meter) |
| Original course model | `PGAOriginalPlayable.swift` (GHPC v3 data, condition selector, transform, per-hole terrain, 18-hole assembly, round setup and store, course catalog), `PGAOriginalCollision.swift` (CSR floor index) |
| Golf rendering, HUD and session | `PGAGame.swift` (session, renderer), `PGAOriginalHoleScene.swift` (per-hole buffers, textures, minimap), `PGAOriginalHUD.swift` (original HUD art, meter dial, scorecard, loading screen, round setup), `PGAView.swift`, `PGAMetalView.swift` |
| Original scene additions | `PGAOriginalScenery.swift`, `PGAOriginalSky.swift`, `PGAOriginalVegetation.swift` (decoded sky, trees, billboards and panoramas); `PGAOriginalGolfer.swift` (skinned Tiger mesh, clubs and animation); `PGACameraDirector.swift` (four decoded camera scripts, partial native playback) |
| Audio | `PGAAudio.swift` (rules from `audio.json`, AVAudioEngine playback, ambience) |
| Original Course Lab | `PGAOriginalCourse.swift` |
| Game metadata | `Library/Manifests/*.json` |
| Media and decoders | `Tools/prepare_pga2005.py` (one command), `installshield_cab.py`, `inspect_pga2005.py`, `import_pga2005{,_hud,_audio}.py`, `decode_pga2005_{terrain,library,holes,objects,golfer,cameras}.py`, `pga2005_xfile.py` |
| Research references | `Tools/pga2005_ballflight_reference.py` (ball flight), `Tools/decode_pga2005_cameras.py` (director and meter reference), `Tools/make_pga2005_meter_fixture.py`, `Tools/analyze_pga2005_{rea,ghidra}.py`, `docs/research/*.md`, `docs/research/evidence/` |

## Original data and evidence

Archives are in the workspace root and intentionally untracked. `python3 Tools/prepare_pga2005.py` extracts the install cabinets in pure Python and regenerates `Library/Imported/pga2005/` (all 11 courses, HUD art, audio, original scenery, Tiger golfer assets and decoded camera scripts). The objects, golfer and camera decoders are part of preparation.

- **GHPC v3** (`terrain.ghpc`) keeps v2's vertex and triangle records, adds a 48-byte header with a patch count, and ends with one 20-byte record per source patch: layer field, first vertex, vertex count, first triangle, triangle count.
- **Patch layers.** The layer field is `tagPatch::PatchLayerInfoS`. Its low five bits are the owning hole; the higher bits are course-condition variants. Holes are separate overlapping worlds, so play and the Lab show one hole at a time. The standard selector is `0x420` (CHole::Load). See the ledger.
- **Transform.** Source units are inches in a left-handed world. The native transform is `((x − ox)·0.0254, (y − oy)·0.0254, −(z − oz)·0.0254)`, with the origin at the bounds' horizontal center and lowest point. It is tested for round trip and handedness.
- **`materials.json`** now records the 20-byte label, the signed sound id (`+0x2c`), the lie graphic (byte `+0x42`) and `section_flags` (`+0xa`) per material.
- **`holes.json`.** Tee and pin XZ come from TCR. Heights are not authoritative (hole 8 tees lie below the course), so play snaps them to the hole's floor. Tee index 3 matches the championship card.

The static analysis for patch selection, flag bits, lie-record rules and coefficient uses is in the ledger section "Per-hole patch layers, course-condition masks and surface coefficients", with curated evidence in `docs/research/evidence/pga2005-patch-layers-surfaces.json`. Those results come from direct Ghidra and LLVM runs, **not REA Evidence**. Keep pseudocode distinct from original source and static evidence distinct from runtime observation.

## Next work, in order

1. **Validate the integrated original gameplay.** The native camera director, `CBallFlight` port, scenery renderer and skinned golfer are on `main`. A clean relaunch showed the corrected ball size and upright Auto camera in one saved Pebble rough view. The next M5 follow-up enlarged the hole overview and made ball/aim/pin markers distinct; the live Pebble saved round showed the new layout. Auto now keeps partial wedge chips behind the actual ball through touchdown to avoid a reverse cut based on a full-club landing estimate. A synthetic chip test passes, but a live sand-wedge chip still needs checking. Check other scripted cuts and compare behavior and visuals against a running original game; camera flight-progress and landing values remain approximations. Check golfer materials, clip alignment and scene performance. The bag now has the original 14 clubs and setup has wind/greens/rough with save tests.
2. **Weather and time of day.** Implemented: setup chooses weather and starting time; each hole blends two presets (`PGARenderPresets.swift`) and applies sky, fog, global diffuse and terrain contrast. Lens flare, rain and the rain/wind sound beds are in. Remaining: Pan/HPan fog on panoramas, GPU tree occlusion of the flare, tree contrast once baked tree lighting is exported, and comparison against running original-game frames.
3. **M1 acceptance**, when the owner makes the laptop available: every course at fullscreen 2560 × 1600 for 30 minutes; FPS, p95/p99 frame time, footprint, swap, thermals and load time.
5. **Rules.** Implemented from [PGA2005-RULES.md](research/PGA2005-RULES.md): compiled OB/unplayable lines tested at rest, stroke-and-distance OB, path-walk relief drops, free relief, original tee sets and pin rotation, `Wind1` wind. Remaining: the drop-zone choice UI, whether wind drifts mid-shot, pin re-randomisation in multi-round events.
6. **Presentation.** `anim.stn` effects are in (original sprites/meshes, approximate motion). Remaining: replays (`Replay.stn` chances are decoded; filming is not), commentary (decode and import in progress on the `commentary` branch) and music.
7. **Memory and performance.** Keep the 3 GB budget. Original scenery submits 14–75 draws per Pebble tee view on the M5; these are draw counts, not frame-time evidence. Consider memoryless MSAA/depth attachments and compressed (BC1/BC2) textures instead of RGBA8 PNGs.
8. **Controller.** Validate every action, held buttons across pause and hole transitions, focus loss and unplug/replug on the Fusion Pro.
9. **Remaining titles**, individually, are now the owner's active goal: see [OTHER_REWRITES.md](OTHER_REWRITES.md). Finish source-derived runtime loops before marking titles playable, then close per-title source/content/input/comparison and M1 gates. PGA2004 has only disc1 (missing cabinet volume3); the intended Space Invaders is the Taito shooter, but the archive holds Bally pinball firmware. A text request for the locations of the missing media/reference has been sent while independent implementation continues.

## Verification commands

```sh
./Tools/build.sh
./Tools/test.sh
python3 -m unittest discover -s Tests -p 'test_*.py'
python3 Tools/prepare_pga2005.py
GAMEHUB_SNAPSHOT_DIR=/tmp/pga-snaps ./Tools/test.sh -XCTest GameHubTests.PGASnapshotTests
```

The snapshot test writes original-course images; keep its output outside Git. `Tools/verify_original_course.swift` also requires `PGABallFlight.swift` when compiled with `PGACore.swift`. `python3 Tools/make_ballflight_fixtures.py --check` verifies the committed Python-reference golden fixture.

## Original-course gameplay adapter plan (implemented 2026-10-13)

1. **Done.** `PGATerrainSampling` is injected into `PGASimulation`. `PGAProceduralTerrain` keeps the practice course and its tests unchanged.
2. **Done.** `PGAOriginalPlayableCourse` assembles one immutable package: mapped GHPC v3, per-hole CSR floor indexes, materials and 18 TCR holes. It uses one tested transform, and tee/pin floor validation is part of loading and tests.
3. **Done, differently than planned.** The mapped course file is shared across holes. Each hole gets compact render buffers of only its own vertices (about 40–65k), built on a worker, with the next hole prefetched. The 18 hole worlds overlap, so a single combined mesh could not be drawn anyway. Textures are cached per session (all 181 PBL images are about 60 MB as RGBA8 with mipmaps).
4. **Done.** Loading is asynchronous with a distinct hub entry. The minimap is rasterized from the hole's triangles. Original material IDs and flags are preserved. Original-course shots now use a static reconstruction of `CBallFlight`; its fidelity to a running original game remains unverified.
5. **Done.** Tests cover the predicate, transform, flags and records, all-hole tees and pins, coast handedness, deterministic play through 18 holes and snapshot restore by course identity.

## Completion gates

A title can be marked `verified` only after all of the following hold:

- A complete native ARM64 game is present.
- Original content, modes and controls are covered, and saves work.
- Launch and return are reliable.
- Meaningful behavior and visual comparisons are recorded.
- Performance and input testing has passed on the M1.

A development demo or imported assets alone is not a completed rewrite.

## Git workflow

Use `main`, small commits, preserve user changes, and push checkpoints when access allows. Never commit original media, extracted DLLs, generated original textures or snapshots, credentials, portable engine installs, Ghidra databases, or built `.app` bundles. Before each push, inspect the staged file list and sizes. Update this document and `STATUS.md` whenever a milestone is verified or a blocker changes. Do not mark the project complete until all requested rewrites are genuinely complete.
