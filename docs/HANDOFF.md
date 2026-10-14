# Continue the Game Hub project

## Objective and non-negotiable scope

Build one native macOS game hub and faithfully rewrite all supplied games. Start with Tiger Woods PGA Tour 2005. Preserve the original visual style while rendering at the M1's native 2560 × 1600 resolution with good performance. Support keyboard/trackpad and the owner's wired Xbox-style controller, and make future native games easy to integrate. Do not use emulation or compatibility layers. The owner requested sub-agents and authorized useful Ghidra/Hopper installation and pushing work to `AnonUserDave/Game-Hub`.

Executable byte identity across x86 Windows and ARM64 macOS is impossible. Track specific asset, behavior, visual, and performance equivalence instead. A prototype must never be labeled a completed port.

## Handoff state and required target

Work on the owner's laptop is paused at his request. His son continues on an M5 MacBook Pro with 24 GB RAM. The mandatory runtime target remains the owner's M1 Air, 8 GB, 2560 × 1600. Read [the binding hardware constraint](M1_TARGET_CONSTRAINT.md) and [status](STATUS.md). Do not start background work on the owner's laptop.

The 2026-10-13 son's checkpoint added playable original gameplay on all 11 courses, corrected the course model (each hole is its own world; the source is left-handed), applied statically recovered patch-selection and surface rules, fixed a dark-image color-space bug and a session memory leak, and added round setup, hot-seat multiplayer, match play and skins. The second wave added native original audio, the exact original tri-click meter, and static decodes of the ball flight, trees and sky, the golfer, and the camera director. Original-course shots now use a Swift port of the statically reconstructed `CBallFlight`; generated practice keeps its provisional model. All of it was checked on the M5 only. Agreement between Swift and Python is not comparison with a running original game.

The decoded Tiger 01 mesh, textures, clubs and swing clips now load on a worker and replace the generated golfer during original-course play when local prepared media are present. One rig is reused across holes. A native build and focused scene/shot test passed on the M5 Pro; live appearance and animation alignment were not checked because offscreen Metal access was unavailable in that test environment.

## Development environments

**Son's M5 (current).** macOS 26.3, Xcode at `/Applications/Xcode.app` (Swift 6.3.1), Homebrew Python 3 with Pillow, Homebrew `unshield` 1.6.2 and OpenJDK 21/26. REA 6.4.0 is the global MCP server (`/opt/homebrew/bin/rea`), with a working Ghidra provider at `~/Desktop/Tools/ghidra_12.1.2`. REA's Ghidra session timed out during Engine.dll auto-analysis; direct `Tools/analyze_pga2005_ghidra.py` headless runs worked (88 s auto-analysis). Extracted DLLs are in the ignored `Library/SourceMedia/pga2005/engine/Executable`; the Ghidra database is in `Library/Research/ghidra-projects/pga2005-physics`. Git identity: the son's own.

**Owner's M1 (paused).** Apple M1 MacBook Air, 8 GB RAM, macOS 15.6. Xcode is installed, but `/usr/bin/swift`, `git`, `python3` and `xcrun` are blocked by an unaccepted Xcode license; do not accept agreements for the user. The build scripts call `/Applications/Xcode.app/.../XcodeDefault.xctoolchain/usr/bin/swiftc` and the SDK directly, and `DEVELOPER_DIR` overrides them. Older notes mention Codex-bundled tools under `/Users/alexrogers/.cache/codex-runtimes/`; they exist only on that laptop.

## Code map

| Area | Files |
| --- | --- |
| Hub UI, library and native launch | `Sources/GameHub/HubView.swift`, `GameModel.swift`, `DetailSheets.swift` |
| Controller discovery/navigation | `Sources/GameHub/ControllerManager.swift`, `FusionController.swift`, `Sources/FusionUSB/` |
| Built-in module registry | `Sources/GameHub/NativeGame.swift` (`pga2005-native-development`, `pga2005-original-courses`) |
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

1. **Validate the integrated original gameplay.** The native camera director, `CBallFlight` port, scenery renderer and skinned golfer are on `main`; the integrated checkpoint through `5f8af01` was pushed to `origin/main` after the owner granted access. The subsequent ball-size and camera-level fixes need a fresh live check after rebuilding/relaunching; the current active game process may still be running the earlier binary. Compare behavior and visuals against a running original game; camera flight-progress and landing values are approximations. Check golfer materials, clip alignment and scene performance. Expand the bag to the original clubs and add wind/settings UI with save tests.
2. **Weather and time of day.** The original blends two of 40 `renderN.ini` presets (`RenderCommand::renderIni1/2`); research is in progress. Then fog, global diffuse, terrain/tree contrast, sky type and the original lens flare per preset, and a setup choice.
3. **M1 acceptance**, when the owner makes the laptop available: every course at fullscreen 2560 × 1600 for 30 minutes; FPS, p95/p99 frame time, footprint, swap, thermals and load time.
5. **Rules.** INI OB polygons (`[Hole N OB k]`), lateral water-hazard drops, the original tee/pin selection.
6. **Presentation.** Replays (`Replay.stn` chances are decoded; filming is not), effects from `anim.stn` (sand, splash, divots), commentary and music.
7. **Memory and performance.** Keep the 3 GB budget. Original scenery submits 14–75 draws per Pebble tee view on the M5; these are draw counts, not frame-time evidence. Consider memoryless MSAA/depth attachments and compressed (BC1/BC2) textures instead of RGBA8 PNGs.
8. **Controller.** Validate every action, held buttons across pause and hole transitions, focus loss and unplug/replug on the Fusion Pro.
9. **Remaining titles**, individually. PGA 2004 has only disc 1. The intended Space Invaders is the Taito shooter, but the archive holds Bally pinball firmware.

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
