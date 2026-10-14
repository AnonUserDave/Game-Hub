# Continue the Game Hub project

## Objective and non-negotiable scope

Build one native macOS game hub and faithfully rewrite all supplied games. Start with Tiger Woods PGA Tour 2005. Preserve the original visual style while rendering at this Mac's native 2560 × 1600 resolution with good performance. Support keyboard/trackpad and the user's wired Xbox-style controller, and make future native games easy to integrate. Do not use emulation or compatibility layers. The user explicitly requested sub-agents and authorized useful Ghidra/Hopper installation and pushing work to `AnonUserDave/Game-Hub`.

Executable byte identity across x86 Windows and ARM64 macOS is impossible. Track specific asset, behavior, visual, and performance equivalence instead. A prototype must never be labeled a completed port.

## Handoff state and required target

Work on the owner's laptop is paused at his request so he can use it for other tasks. His son continues on an M5 MacBook Pro with 24 GB RAM. The mandatory runtime target remains the owner's M1 Air, 8 GB, 2560 × 1600. Read [the binding hardware constraint](M1_TARGET_CONSTRAINT.md) and use [the continuation prompt](SON_HANDOFF_PROMPT.md). All original ZIPs have already been AirDropped to the son; see [media setup](MEDIA_SETUP.md). Do not start background work on the owner's laptop.

## Original development environment

- Apple M1 MacBook Air, 8 GB RAM, macOS 15.6.
- Xcode is installed at `/Applications/Xcode.app`. `/usr/bin/swift`, `/usr/bin/git`, `/usr/bin/python3`, and `xcrun` are blocked by an unaccepted Xcode license. Do not accept agreements for the user.
- Direct Swift: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc`.
- SDK: `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`.
- Codex bundled Git: `/Users/alexrogers/.cache/codex-runtimes/codex-primary-runtime/dependencies/bin/fallback/git`.
- Codex bundled Python: `/Users/alexrogers/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3`.
- Codex bundled Node: `/Users/alexrogers/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node`.

Scripts select direct toolchain paths to make this project buildable without globally changing Xcode configuration.

## Code map

| Area | Files |
| --- | --- |
| Hub UI, library and native launch | `Sources/GameHub/HubView.swift`, `GameModel.swift`, `DetailSheets.swift` |
| Controller discovery/navigation | `Sources/GameHub/ControllerManager.swift` |
| Built-in module registry | `Sources/GameHub/NativeGame.swift` |
| Native golf simulation and renderer | `Sources/GameHub/PGA*.swift` |
| Game metadata | `Library/Manifests/*.json` |
| Media inventory/extraction | `Tools/inspect_pga2005.py` |
| Course metadata and image conversion | `Tools/import_pga2005.py` |
| REA provider analysis | `Tools/analyze_pga2005_rea.py`, `docs/research/PGA2005-REA.md` |

## Original data and evidence

Archives are in the workspace root and intentionally untracked. Extracted images are in `Library/SourceMedia/pga2005`. Versioned inventory `docs/research/evidence/pga2005-assets.json` (also generated locally as `Library/Research/pga2005-assets.json`) records source/archive/disc hashes, file offsets, and headers. `Library/Imported/pga2005/import-report.json` records 11 courses, 198 holes, 236 image conversions, hashes, and limitations.

The original Windows main executable is on the courses disc. The actual engine is split into DLLs stored in InstallShield cabinets on the install/media discs. `Library/SourceMedia/pga2005/engine/Executable` contains the extracted DLLs. `Engine.dll` has thousands of named exports, including `CBallFlight::Flying`, `RollingAndSlipping`, `PureRolling`, `Impact`, and `BallLoop`. `CourseData.dll` has named terrain vertex decompression and course/header loading routines. These are concrete reconstruction entry points; filenames alone are not implementation evidence.

Ghidra/JDK/unshield are task-local under `.tools` and untracked. REA's global MCP server may not inherit task-local environment values; the companion client script launches a scoped server with explicit provider paths. Reuse saved reports and Evidence IDs instead of repeating broad analyses. Keep pseudocode distinct from original source and static evidence distinct from runtime observation.

## Next work, in order

1. Reproduce the checkpoint on the son's Mac and visually confirm the final camera fix. The forest transform bug is fixed in source and covered by scene/camera regression tests across all three generated holes; the final GUI check remains pending. Original Course Lab and practice now render at a measured 2560 × 1600 fullscreen target. The user reported Fusion Pro buttons/triggers/sticks working; remaining game mappings and hot plug need checking.
2. Integrate original PBL 18-hole gameplay using original TCR tees/pins/par, decoded geometry and exact triangle floor queries. Native world units are inches, corroborated by original TotalYards distance/36 assembly. Use native TCR arrays directly; INI coordinates have a different origin. Keep ball physics and generated golfer explicitly provisional.
3. Reconstruct original flight/impact/rolling/cup rules from the named functions with numeric fixtures and reference observations. Existing practice physics is new code. Exact floor heights do not implement wall/object collision or original rules.
4. Recover original shader behavior, material-specific UV adjustments, alpha/water, lighting/fog, sky, alternate LODs and vegetation/object placement. Primary terrain decoding already validates all 11 courses; PBL/TUR material links and textures are ready. Some textures contain several terrain surface records; do not assume the first surface record applies everywhere.
5. Recover golfer/ball meshes, animation, audio, UI flow, rules, saves, career and other game modes. Record unsupported systems explicitly.
6. Compare original gameplay/captures in a reference environment. The delivered Mac application must remain native. Static decompilation alone does not establish runtime behavior or whole-game equivalence.
7. Profile real-course gameplay at 2560 × 1600 on the M1 over a sustained session, recording average/p95 frame time and memory. Current 55–60 FPS snapshots are not a sustained benchmark.
8. Validate every controller action, focus loss, held-button transitions and unplug/replug. The backend supports only this exact 24c6:591a model; external native applications supply their own support.
9. Rewrite remaining titles individually. PGA 2004 has only disc 1. The user wants the classic Space Invaders shooter, while the supplied archive contains Bally pinball firmware. User-reported archive source is OldGamesDownload; labels require content verification.

## New assets and code to reuse

`Tools/prepare_pga2005.py` prepares local PBL/TUR meshes, materials and holes in one command. Individual readers are `decode_pga2005_terrain.py`, `decode_pga2005_library.py` and `decode_pga2005_holes.py`. GHPC v2 records contain original positions/RGBA/UVs and globally indexed triangles with original material IDs. Source/converted data remain ignored.

`PGAOriginalCourse.swift` implements the source course viewer. `PGAMetalView.swift` controls the actual render target. `PGAOriginalCollision.swift` supplies immutable spatially indexed barycentric floor queries over original triangles. `Tools/verify_original_course.swift` checks original triangle centroids and query timing. `Sources/FusionUSB/` and `FusionController.swift` contain the shared native USB input backend.

Current validation: 23 Swift tests and 18 Python tests. All11 original course meshes pass decoder bounds/index checks. PBL/TUR floor queries pass 9,110/7,128 nonvertical original triangle centroids with zero missing intersections; vertical wall triangles are excluded from this floor-height fixture. Eight original TCL DDS textures match an independent Pillow decoder across 10,754,048 RGBA values.

## Completion gates

A title can be marked `verified` only after a complete native ARM64 game is present, original content/modes and controls are covered, saves work, launch/return is reliable, meaningful behavior/visual comparisons are recorded, and performance/input testing has passed on this Mac. A development demo or imported assets alone is not a completed rewrite.

## Git workflow

The remote was initially empty. The project uses `main`, with local commit author `Game Hub Contributors <game-hub@users.noreply.github.com>` until contributors configure their own identity. Use normal small commits, preserve user changes, and push checkpoints. Never commit original media, extracted DLLs, generated original textures, credentials, portable engine installs, or built `.app` bundles. Before each push, inspect the staged file list and sizes.

Update this document and `docs/STATUS.md` whenever a milestone is verified or a blocker changes. The long-term objective is unfinished; work on the owner's laptop is paused for this handoff. Continue in the son's clone. Do not mark the project complete until all requested rewrites are genuinely complete.

## Original-course gameplay adapter plan

1. Introduce a Foundation-only terrain sampling protocol injected into `PGASimulation`; retain a procedural provider for the existing practice course and tests. Keep course metadata value-based and serializable.
2. Assemble an immutable original playable-course package containing decoded terrain, collider, materials and all 18 TCR holes. Use one explicit transform: original inches × 0.0254 to meters, with an origin derived from course bounds and a tested reverse transform for queries. Validate tee/pin floor intersections before enabling the option.
3. Reuse the original mesh builder from the lab, preserving UVs/material batches and the same origin transform. Keep one course mesh/index in memory across holes instead of reloading hundreds of thousands of vertices for each hole. Bound resources for the 8 GB M1.
4. Load asynchronously and expose a distinct original Pebble Beach development option. Use actual course geometry for views/minimap. Keep the ball/golfer and physics limitations visible; preserve source material IDs rather than pretending approximate categories are original rules.
5. Add meaningful unit/round-trip, all-hole tee/pin, deterministic simulation and save/restore checks. Save course/source identity and reattach assets after restore. The floor collider excludes vertical walls and is not swept-ball collision. Multiple surface records per material need original selection rules before faithful physics claims.
