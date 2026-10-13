# Game Hub

A native Apple Silicon macOS library for a family game-porting project. The first target is **Tiger Woods PGA Tour 2005**, followed by the other supplied games. Games must eventually run as native rewrites, without emulators, Wine, or Rosetta.

**Status: development, not a collection of completed ports.** The hub launches native games and catalogs the original media. The golf development module is an original practice prototype, not a faithful PGA 2005 replacement. Original terrain, characters, animation, audio, career modes, and behavior remain unfinished. An ARM64 rewrite cannot have the same executable bytes as an x86 Windows game; fidelity will be evaluated against specific behavior and visual references.

## Run on this Mac

Double-click `Game Hub.app` after building, or run:

```sh
./Tools/build.sh
./Tools/run.sh
```

Requires macOS 14+ and Xcode's installed Swift compiler/macOS SDK. The build script uses the compiler directly, so the current machine's `/usr/bin` Xcode launcher problem does not prevent this build. It does not accept an Xcode license or change system settings. No third-party Swift dependencies.

The target Mac is an M1 MacBook Air with 8 GB RAM and a 2560 × 1600 panel. The game renderer uses the actual window backing size; enter fullscreen for the whole display. Rendering size, frame rate, and actual controller input need runtime verification, not just a display-setting claim.

## What is being built

- One SwiftUI hub: library, search, favorites, port status, and native launch/return.
- Built-in game modules and manifest-based `.app`/ARM64 executable integration, so future ports can be added without rewriting the hub.
- Keyboard and trackpad controls, with native GameController support for devices macOS exposes.
- A native golf development course to exercise rendering, swing, ball simulation, putting, penalties, and input while the original engine is reconstructed.
- Local source-media inspection, texture conversion, and REA/Ghidra research for the real PGA port.

The supplied collection contains 17 archives: PGA 2004/2005, THPS 2, THUG 1/2, Apple Panic, three Asteroids editions, Breakout, Conflict 2500, Crossfire, Dig Dug, NFL Football, Night Driver, Preppie!, and Space Invaders. Each platform edition needs its own fidelity assessment.

**Source issues:** PGA 2004 currently has only disc 1. The archive named `Space_Invaders_Arcade_ROM_EN.zip` contains Bally pinball firmware; the intended game is the classic 1978 Taito shooter. The hub records that mismatch rather than treating the firmware as the shooter.

## Original PGA assets

Original archives, extracted game files, imported artwork, and analysis-engine downloads stay local and are excluded from Git. New code, manifests, scripts, tests, and research notes are versioned. A fresh clone works as a hub/development build without proprietary assets; users supply their own media for original-asset research.

Inspect the supplied archive and extract disc images:

```sh
python3 Tools/inspect_pga2005.py
python3 Tools/import_pga2005.py
```

The importer currently recovers 11 courses' INI metadata (198 holes) and converts 236 original TGA/DDS images to PNG. It preserves raw coordinates, duplicate keys, provenance hashes, and malformed source fields. It does **not** decode the TCR terrain or TCL compiled libraries. See [asset research](docs/research/PGA2005-ASSETS.md) and [REA research](docs/research/PGA2005-REA.md).

On the original development Mac, the bundled Python is:

```sh
/Users/alexrogers/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3
```

## Controller status

The plugged-in controller identifies as **BDA XB1 Fusion Pro**, USB `24c6:591a`. USB enumeration succeeded, but the initial native GameController probe returned zero controllers. Physical buttons/sticks are therefore **not yet verified working**. The app's Controls & devices panel reports USB presence separately from a usable controller profile. Keyboard and trackpad remain available.

See [controller findings](docs/CONTROLLERS.md). Do not install old kernel drivers or mark all games controller-compatible from USB presence alone.

## Contribute or continue

Read [HANDOFF.md](docs/HANDOFF.md) first, then [INTEGRATION.md](docs/INTEGRATION.md) for the game-module contract. The immediate priority is decoding and rendering original PGA 2005 terrain, then reconstructing the exported physics routines and validating them against original behavior. The generated practice course is scaffolding for that work.

Tests:

```sh
./Tools/test.sh
python3 -m unittest discover -s Tests -p 'test_*.py'
```

Project repository: [AnonUserDave/Game-Hub](https://github.com/AnonUserDave/Game-Hub).

Original archive source reported by the user: [OldGamesDownload](https://oldgamesdownload.com/). Archive labels are treated as claims and checked against file contents.
