# Game Hub

A native Apple Silicon macOS library for a family game-porting project. The first target is **Tiger Woods PGA Tour 2005**, followed by the other supplied games. Games must eventually run as native rewrites, without emulators, Wine, or Rosetta.

**Status: development, with no completed faithful ports.** The hub catalogs all supplied titles and launches native modules. PGA 2005 has generated practice holes and development gameplay across all 18 holes of each of 11 prepared original courses. The original-course module uses locally decoded terrain, textures, trees, sky, HUD, Tiger golfer assets, audio, camera scripts, a tri-click meter and a Swift reconstruction of ball flight. The Original Course Lab views original hole geometry. Gameplay rules, physics and visuals still need comparison with a running original game; several modes, collisions, weather and presentation features remain incomplete. An ARM64 rewrite cannot have the same executable bytes as an x86 Windows game, so fidelity is tracked through asset, behavior, visual, control and performance comparisons.

Breakout and Conflict2500 now also have playable native **development reconstructions** with per-title setup, controls and save/resume. Breakout uses rules/tables recovered from the supplied cartridge; Conflict uses the recovered BASIC game program. Collision/presentation/timing and several source behaviors remain approximate or unverified. The active goal for every remaining title/edition and its completion gates is recorded in [OTHER_REWRITES.md](docs/OTHER_REWRITES.md). No prototype or decoded original content is a completed faithful rewrite.

## Run on this Mac

Double-click `Game Hub.app` after building, or run:

```sh
./Tools/build.sh
./Tools/run.sh
```

Requires macOS 14+ and Xcode's installed Swift compiler/macOS SDK. The build script uses the compiler directly, so the current machine's `/usr/bin` Xcode launcher problem does not prevent this build. It does not accept an Xcode license or change system settings. No third-party Swift dependencies.

The release target is the owner's M1 MacBook Air with 8 GB RAM and a 2560 × 1600 panel. The Metal renderer targets actual 2560 × 1600 attachments in fullscreen, independently of desktop scaling. Earlier native UI checks confirmed that attachment size in practice and Original Course Lab. Current original-course development checks were on the son's M5 Pro; the required 30-minute M1 performance and input acceptance remains pending. See [M1 target constraints](docs/M1_TARGET_CONSTRAINT.md).

## What is being built

- One SwiftUI hub: a shelf library with one entry per game (original copy plus its native builds), search, systems, favorites, honest playability status, native launch/return, and full keyboard and controller navigation.
- Built-in game modules and manifest-based `.app`/ARM64 executable integration, so future ports can be added without rewriting the hub.
- Keyboard and trackpad controls, with native GameController support for devices macOS exposes.
- A native golf development course to exercise rendering, swing, ball simulation, putting, penalties, and input while the original engine is reconstructed.
- An Original Course Lab for the actual Pebble Beach and Turnberry terrain, UVs, material IDs and textures, one hole world at a time, with orbit, zoom, hole/course selection and provenance.
- An 18-hole original-course development module for all 11 prepared courses, using a statically reconstructed ball-flight model that still needs original-game comparison.
- Local source-media inspection, texture conversion, and REA/Ghidra research for the real PGA port.

The supplied collection contains 17 archives: PGA 2004/2005, THPS 2, THUG 1/2, Apple Panic, three Asteroids editions, Breakout, Conflict 2500, Crossfire, Dig Dug, NFL Football, Night Driver, Preppie!, and Space Invaders. Each platform edition needs its own fidelity assessment.

**Source issues:** PGA 2004 currently has only disc 1. The archive named `Space_Invaders_Arcade_ROM_EN.zip` contains Bally pinball firmware; the intended game is the classic 1978 Taito shooter. The hub records that mismatch rather than treating the firmware as the shooter.

## Original PGA assets

Original archives, extracted game files, imported artwork, and analysis-engine downloads stay local and are excluded from Git. New code, manifests, scripts, tests, and research notes are versioned. A fresh clone works as a hub/development build without proprietary assets; users supply their own media for original-asset research.

Prepare original Pebble Beach and Turnberry course assets with one command (Python 3.10+):

```sh
python3 Tools/prepare_pga2005.py
```

The importer prepares all 11 courses (198 holes), including original terrain, materials, tees, pins, scenery, golfer assets, HUD, audio and camera scripts. It preserves provenance and keeps prepared media outside Git. Source world units are inches. See [asset research](docs/research/PGA2005-ASSETS.md) and [REA research](docs/research/PGA2005-REA.md).

On the original development Mac, the bundled Python is:

```sh
/Users/alexrogers/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3
```

## Controller status

The plugged-in controller identifies as **BDA XB1 Fusion Pro**, USB `24c6:591a`. USB enumeration succeeded, but the initial native GameController probe returned zero controllers. The app therefore includes an original user-space USB backend for this exact device. The user exercised A/B/X/Y, both triggers and both sticks and reported working input; the live panel showed the USB path and a physical RT release event. Keyboard and trackpad remain available. Other buttons, unplug/replug and each game action still need explicit validation.

See [controller findings](docs/CONTROLLER.md). The adapter requires no kernel driver or security change; imported external applications provide their own input support.

## Contribute or continue

For the son: start with the [ready-to-paste continuation prompt](docs/SON_HANDOFF_PROMPT.md). The [M1 hardware constraint](docs/M1_TARGET_CONSTRAINT.md) is mandatory even when developing on the M5 Pro. Original ZIPs have already been AirDropped; follow [media setup](docs/MEDIA_SETUP.md). Work on the owner's laptop is paused for this handoff.

Read [HANDOFF.md](docs/HANDOFF.md), then [INTEGRATION.md](docs/INTEGRATION.md) for the game-module contract. Original-course gameplay is integrated; the next priorities are original-game comparisons, remaining rules and presentation work, and M1 acceptance when the owner makes that machine available. The generated practice course remains scaffolding.

Tests:

```sh
./Tools/test.sh
python3 -m unittest discover -s Tests -p 'test_*.py'
```

Project repository: [AnonUserDave/Game-Hub](https://github.com/AnonUserDave/Game-Hub).

Original archive source reported by the user: [OldGamesDownload](https://oldgamesdownload.com/). Archive labels are treated as claims and checked against file contents.
