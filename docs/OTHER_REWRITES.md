# Goal: finish the remaining native game rewrites

Owner requested this active goal on 2026-10-13. Scope is all **16 supplied titles/editions beyond PGA2005**, with the three Asteroids editions assessed separately. This goal continues the work in this checkout; it does not authorize remote or background work on the owner's paused M1.

No title below is a completed faithful rewrite. The current development host is the son's **M5 Pro MacBook Pro, 24 GB RAM**. Release acceptance requires the owner's **M1 Air, 8 GB, 2560 × 1600**, as specified in [M1_TARGET_CONSTRAINT.md](M1_TARGET_CONSTRAINT.md).

| Title / source edition | Current source-backed implementation | Required next work |
| --- | --- | --- |
| PGA2004 / Windows | Offline disc/cabinet reader; available PBL/SAW/STA course records and original engine binaries recovered with integrity checks | Missing cabinet volume 3 and complete source media; version-4 terrain decode and title-specific behaviors/content/modes |
| THPS2 / Windows | PKR2 source assets; bounded PSX/TRG/blockmap readers and native builder construct eight career/two secret original scenes; eight Swift/six Python checks | Rendered pixels/source renderer, title-specific collision/skating/tricks/scoring/scripts/goals, actors/animation, modes/multiplayer/saves/input/runtime and all comparisons/M1 gates |
| THUG / Windows | PRE3/LZSS decode; 47 unique original collision assets; bounded native GHSC loader | Original scene/material/animation/script loaders, skating/walking/driving, missions/modes/saves and native runtime |
| THUG2 / Windows | Three-disc/CAB/PRE3 decode; 94 unique collision assets and native loader | Remaining installation-name/cabinet coverage, scene/material/animation/scripts, original gameplay/modes/saves |
| Apple Panic / Apple II | Native development session with original sprites and supplied hole/slot/capture/crush/chain rules; controls/pause/Ctrl-R/saves/launch/return; 25 core/seven decoder checks plus integration tests and live M5 smoke | Original art/colors/font/audio/screens/visible drop sequences, ROM randomness/source clocks, complete controls/source comparisons and M1 acceptance |
| Asteroids / Atari2600 | Native66-variation playing dispatcher, packed entities/source movement/collisions/splits/waves/score/lives/controls/alternating players and snapshots;21 tables/29 masks;25 Swift/seven Python checks | Native session/UI, original TIA art/composition/colors/audio/cadence, source comparisons/physical input and M1 acceptance |
| Asteroids / Atari7800 | Native four-mode33-object loop with source controls/motion/shots/collisions/splits/score/lives/waves/UFO/phases/snapshots;44 tables/813 graphics;16 Swift/five Python checks | Real boot RAM/timer/optional firmware, pair-order/terminal reconciliation, complete graphics/audio/cadence and native session; original/physical/M1 gates |
| Asteroids / Atari8-bit | Native source-VBI/foreground lifecycle, selected modes/four-player rules, thrust/shots/shield/relocation/collisions/splits/waves/UFO/explosions/sound parameters/snapshots and hash-fenced original tables/masks;17 Swift/four Python checks | Explicit RANDOM/startup fractions, OS/font/menu/attract/high scores, raster order/death carry/POKEY/region/audio and native session; original/physical/M1 gates |
| Breakout / Atari2600 | Native development session;26 source-core checks cover prior-frame pixel contacts, sampling/steering/fractions, timed/no-rebuild and scored/team transitions, five rounds, selection overflow; original HUD digits prepared | Intraline graphics, rotation/attract/selection art, cadence/color/audio conversion, independent split-paddle catches, original/physical comparisons and M1 acceptance |
| Conflict2500 / AppleII | Playable native **development reconstruction** of recovered BASIC rules; scenario, map/tactical/status, commands, AI/turns and save/resume | Applesoft RNG/numeric parity, original display/animation/timing and multi-ship docking prompts; original comparison |
| Crossfire / AppleII | Native development session with15 original masks, XOR silhouettes/anchors, independent movement/fire adapters, pauses/saves/launch/return; native/static and live M5 shot/resume evidence | Selected source startup, exact HGR field/color/font/screens, audio/cadence, all original/physical comparisons and M1 acceptance |
| DigDug / C64 | Two bounded packed-format decoders recover24,576 source bytes, hash-fenced through intro/known relocation/trainer/game; six Python checks | Native game/interrupt scheduler, source terrain/entities/pump/rocks/bonuses/modes/art/audio/input/saves and session; all original/physical/M1 comparisons |
| NFLFootball / Intellivision | Selected cartridge recovered and hashed | CP1610/EXEC/GROM dependencies, original modes/rules/assets and disc/keypad/side-button controls; native session |
| NightDriver / C64 | Native development session with original instruction/character road/car/crash/HUD/digit data, independent control/timer scheduling, keyboard/paddle adapters, pause/save/launch/return | Qualified foreground/CIA/crash timing (development120/50/0.2s are provisional), RGB/VIC crop/audio/attract/high-score sequences, source comparisons/physical input and M1 acceptance |
| Preppie! / Atari8-bit | Plain US XEX selected; all ordered segments recovered and hashed | Source level/lane/actor/control/timing/art/audio reconstruction and native session |
| SpaceInvaders / intended 1978 Taito shooter | Supplied archive mismatch confirmed; contains Bally pinball firmware | Correct shooter reference/media; source reconstruction and complete native runtime. Pinball firmware cannot establish shooter fidelity |

## Completion gates for every row

- Complete native ARM64 implementation with original content, modes and logical control coverage; no emulation, Wine or Rosetta.
- Saves restore the title's actual native state with source/version validation.
- Launch, load, pause, focus loss, reconnect, transitions and return are reliable; inactive modules release their sessions.
- Recorded behavior, visual and audio comparisons against the identified original revision. Static/Python/Swift agreement alone is insufficient.
- Keyboard/trackpad and the physical BDA/PowerA Fusion Pro `24c6:591a` have passed each game action and transition. Additional simultaneous controllers need their own evidence.
- M1 sustained acceptance: 30-minute representative play, sustained60FPS target, p95/p99 frames, peak footprint within the provisional3GB budget, memory pressure/swap/thermal/loading evidence at required settings. No M5 substitution.
- Status/handoff and source-hash receipts accurately record achieved and unverified claims; first-party changes are committed and pushed, originals/assets/builds remain local.

## Current checkpoint verification

The latest per-edition source-loop checkpoint passes **262 Swift XCTest**
(five expected skips: four opt-in golf captures and no CoreAudio output),
**245 Python tests** and optimized native ARM64 compilation on M5. The new
Asteroids cores contribute58 source-core tests and16 decoder tests. Dig Dug's
two packed formats contribute six tests and recover exactly24KiB; gameplay is
absent. The three Asteroids editions remain unregistered native cores, with
their own source startup/timing/presentation gaps. These results do not close
original-game, physical-controller or M1 gates.

The final M5 integration checkpoint passes **192 Swift XCTest** (three expected skips), **193 Python tests** and optimized ARM64 compilation. Eleven native integration regressions cover focused/neutralized input, pending source taps, original key maps, both sticks, source stop at intersections, media recheck before launch, HUD bounds and character pixel continuity. Live checks cover Apple Panic original masks/movement/pause/save/return/paused restore (X82/Y160,15 source half-dispatches, level1/lives3/score0), Crossfire original masks/stop/shot/pause/save/return/paused restore (ammo35→34), and Night Driver original instruction/road/car/HUD, acceleration/pause/save/return/paused restore (speed16/source time98). These are native and M5 development receipts. Original behavior/visual/audio comparisons, physical controller transitions and every M1 gate remain open. The active all16-title goal is unfinished.

Reproduction:

```sh
python3 Tools/prepare_retro_media.py
python3 Tools/prepare_breakout2600.py
python3 Tools/prepare_asteroids.py
python3 Tools/prepare_asteroids2600.py
python3 Tools/decode_asteroids7800.py
python3 Tools/decode_asteroids8bit.py
python3 Tools/prepare_other_windows.py
python3 Tools/decode_thps2.py --all-levels
python3 Tools/decode_apple_panic.py
python3 Tools/decode_crossfire.py
python3 Tools/decode_night_driver.py
python3 Tools/decode_dig_dug.py
./Tools/build.sh
./Tools/test.sh
python3 -m unittest discover -s Tests -p 'test_*.py'
```

Apple Panic/Crossfire/Night Driver require their prepared original graphics. The other development entries retain their existing media requirements; Conflict's source tactical bit patterns need preparation. All originals and generated original packages stay ignored. Source content recovery or scene construction alone never counts as a completed rewrite. See [Apple Panic](research/APPLE-PANIC.md), [Breakout](research/BREAKOUT.md), [Conflict2500](research/CONFLICT2500.md), [Crossfire](research/CROSSFIRE.md), [Night Driver](research/NIGHT-DRIVER.md), [Asteroids](research/ASTEROIDS.md), [THPS2](research/THPS2.md) and [Windows content](research/OTHER-WINDOWS.md).
