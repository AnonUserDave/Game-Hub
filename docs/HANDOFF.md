# Continue the Game Hub project

## Objective and non-negotiable scope

Build one native macOS game hub and faithfully rewrite all supplied games. Start with Tiger Woods PGA Tour 2005. Preserve the original visual style while rendering at this Mac's native 2560 × 1600 resolution with good performance. Support keyboard/trackpad and the user's wired Xbox-style controller, and make future native games easy to integrate. Do not use emulation or compatibility layers. The user explicitly requested sub-agents and authorized useful Ghidra/Hopper installation and pushing work to `AnonUserDave/Game-Hub`.

Executable byte identity across x86 Windows and ARM64 macOS is impossible. Track specific asset, behavior, visual, and performance equivalence instead. A prototype must never be labeled a completed port.

## Development machine

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

Archives are in the workspace root and intentionally untracked. Extracted images are in `Library/SourceMedia/pga2005`. Local inventory `Library/Research/pga2005-assets.json` records source/archive/disc hashes, file offsets, and headers. `Library/Imported/pga2005/import-report.json` records 11 courses, 198 holes, 236 image conversions, hashes, and limitations.

The original Windows main executable is on the courses disc. The actual engine is split into DLLs stored in InstallShield cabinets on the install/media discs. `Library/SourceMedia/pga2005/engine/Executable` contains the extracted DLLs. `Engine.dll` has thousands of named exports, including `CBallFlight::Flying`, `RollingAndSlipping`, `PureRolling`, `Impact`, and `BallLoop`. `CourseData.dll` has named terrain vertex decompression and course/header loading routines. These are concrete reconstruction entry points; filenames alone are not implementation evidence.

Ghidra/JDK/unshield are task-local under `.tools` and untracked. REA's global MCP server may not inherit task-local environment values; the companion client script launches a scoped server with explicit provider paths. Reuse saved reports and Evidence IDs instead of repeating broad analyses. Keep pseudocode distinct from original source and static evidence distinct from runtime observation.

## Next work, in order

1. Finish TCR/TCL format recovery from `CourseData.dll`: header offsets, patch descriptors, compressed vertex layout, indices, material IDs, UVs, tree/object placement, and surface coefficients. Validate bounds and counts against multiple courses. Do not infer terrain from INI tee/pin metadata.
2. Build a native renderer for an original course with the original textures. Add mipmapping/filtering, correct fog/lighting, shadows and native-size UI. Preserve style before upgrading fidelity.
3. Reconstruct ball flight/impact/rolling/cup logic from the original named engine functions, using reproducible numeric fixtures. The current practice physics is new code, not parity evidence.
4. Recover golfer/ball meshes, animation, input behavior, audio, UI flow, rules, save data, and PGA game modes. Record unsupported subsystems explicitly.
5. Compare captures and gameplay outputs from a lawful original reference environment. Reference capture may run the original on its intended platform; the delivered Mac app must remain native. The Mac alone cannot execute the Windows reference without the compatibility/emulation approach the user excluded for the product.
6. Profile a real course at a measured 2560 × 1600 drawable on the M1. Record average/p95 frame time, CPU/GPU use and memory over a sustained session; choose quality settings from measured results.
7. Resolve the user's BDA Fusion Pro controller input. It is seen as USB but currently not GameController/HID. Validate every mapped action, hot unplug, focus, and held-button transitions. Never claim support from a product name.
8. Port the remaining games individually, with platform-specific behavior references and shared game-input/launch contracts. PGA 2004 is missing discs 2/3. Space Invaders needs the intended shooter reference, since the supplied file is pinball firmware.

## Completion gates

A title can be marked `verified` only after a complete native ARM64 game is present, original content/modes and controls are covered, saves work, launch/return is reliable, meaningful behavior/visual comparisons are recorded, and performance/input testing has passed on this Mac. A development demo or imported assets alone is not a completed rewrite.

## Git workflow

The remote was initially empty. The project uses `main`, with local commit author `Game Hub Contributors <game-hub@users.noreply.github.com>` until contributors configure their own identity. Use normal small commits, preserve user changes, and push checkpoints. Never commit original media, extracted DLLs, generated original textures, credentials, portable engine installs, or built `.app` bundles. Before each push, inspect the staged file list and sizes.

Update this document and `docs/STATUS.md` whenever a milestone is verified or a blocker changes. Keep the long-term goal active until all requested rewrites are genuinely complete.
