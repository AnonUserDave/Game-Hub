# Game Hub

A native Apple Silicon macOS library for a family game-porting project. The first target is **Tiger Woods PGA Tour 2005**, followed by the other supplied games. Games must eventually run as native rewrites, without emulators, Wine, or Rosetta.

**Status: development, not a collection of completed ports.** The hub launches native games and catalogs the original media. The golf development module is an original practice prototype, not a faithful PGA 2005 replacement. An Original Course Lab now renders decoded original terrain and textures. Original-course gameplay, characters, animation, audio, career modes, and behavior remain unfinished. An ARM64 rewrite cannot have the same executable bytes as an x86 Windows game; fidelity will be evaluated against specific behavior and visual references.

## Run on this Mac

Double-click `Game Hub.app` after building, or run:

```sh
./Tools/build.sh
./Tools/run.sh
```

Requires macOS 14+ and Xcode's installed Swift compiler/macOS SDK. The build script uses the compiler directly, so the current machine's `/usr/bin` Xcode launcher problem does not prevent this build. It does not accept an Xcode license or change system settings. No third-party Swift dependencies.

The target Mac is an M1 MacBook Air with 8 GB RAM and a 2560 × 1600 panel. The Metal renderer explicitly targets 2560 × 1600 in fullscreen, independently of desktop scaling. Native UI testing confirmed that actual attachment size in both practice and Original Course Lab. Snapshot frame rates reached 55–60 FPS; sustained profiling remains pending.

## What is being built

- One SwiftUI hub: library, search, favorites, port status, and native launch/return.
- Built-in game modules and manifest-based `.app`/ARM64 executable integration, so future ports can be added without rewriting the hub.
- Keyboard and trackpad controls, with native GameController support for devices macOS exposes.
- A native golf development course to exercise rendering, swing, ball simulation, putting, penalties, and input while the original engine is reconstructed.
- An Original Course Lab for the actual Pebble Beach and Turnberry terrain, UVs, material IDs and textures, with orbit, zoom, course selection and provenance.
- Local source-media inspection, texture conversion, and REA/Ghidra research for the real PGA port.

The supplied collection contains 17 archives: PGA 2004/2005, THPS 2, THUG 1/2, Apple Panic, three Asteroids editions, Breakout, Conflict 2500, Crossfire, Dig Dug, NFL Football, Night Driver, Preppie!, and Space Invaders. Each platform edition needs its own fidelity assessment.

**Source issues:** PGA 2004 currently has only disc 1. The archive named `Space_Invaders_Arcade_ROM_EN.zip` contains Bally pinball firmware; the intended game is the classic 1978 Taito shooter. The hub records that mismatch rather than treating the firmware as the shooter.

## Original PGA assets

Original archives, extracted game files, imported artwork, and analysis-engine downloads stay local and are excluded from Git. New code, manifests, scripts, tests, and research notes are versioned. A fresh clone works as a hub/development build without proprietary assets; users supply their own media for original-asset research.

Prepare original Pebble Beach and Turnberry course assets with one command (Python 3.10+):

```sh
python3 Tools/prepare_pga2005.py
```

The importer currently recovers 11 courses' INI metadata (198 holes) and converts 236 original TGA/DDS images to PNG. It preserves raw coordinates, duplicate keys, provenance hashes, and malformed source fields. Separate readers now decode version-7 TCR primary geometry, original TCL texture/material links and surface properties, and authoritative TCR tee/pin arrays. Geometry validation passes all 11 supplied courses. Pebble Beach contains 925,930 vertices, 843,279 triangles and 181 used materials. Original world units are corroborated as inches. See [asset research](docs/research/PGA2005-ASSETS.md) and [REA research](docs/research/PGA2005-REA.md).

On the original development Mac, the bundled Python is:

```sh
/Users/alexrogers/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3
```

## Controller status

The plugged-in controller identifies as **BDA XB1 Fusion Pro**, USB `24c6:591a`. USB enumeration succeeded, but the initial native GameController probe returned zero controllers. The app therefore includes an original user-space USB backend for this exact device. The user exercised A/B/X/Y, both triggers and both sticks and reported working input; the live panel showed the USB path and a physical RT release event. Keyboard and trackpad remain available. Other buttons, unplug/replug and each game action still need explicit validation.

See [controller findings](docs/CONTROLLER.md). The adapter requires no kernel driver or security change; imported external applications provide their own input support.

## Contribute or continue

For the son: start with the [ready-to-paste continuation prompt](docs/SON_HANDOFF_PROMPT.md). The [M1 hardware constraint](docs/M1_TARGET_CONSTRAINT.md) is mandatory even when developing on the M5 Pro. Original ZIPs have already been AirDropped; follow [media setup](docs/MEDIA_SETUP.md). Work on the owner's laptop is paused for this handoff.

Read [HANDOFF.md](docs/HANDOFF.md), then [INTEGRATION.md](docs/INTEGRATION.md) for the game-module contract. The immediate priority is integrating original 18-hole course gameplay using recovered geometry, material surfaces and authoritative tees/pins, then reconstructing original physics and full game content. The generated practice course is scaffolding for that work.

Tests:

```sh
./Tools/test.sh
python3 -m unittest discover -s Tests -p 'test_*.py'
```

Project repository: [AnonUserDave/Game-Hub](https://github.com/AnonUserDave/Game-Hub).

Original archive source reported by the user: [OldGamesDownload](https://oldgamesdownload.com/). Archive labels are treated as claims and checked against file contents.
