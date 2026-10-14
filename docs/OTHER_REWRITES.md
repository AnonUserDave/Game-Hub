# Goal: finish the remaining native game rewrites

Owner requested this active goal on 2026-10-13. Scope is all **16 supplied titles/editions beyond PGA2005**, with the three Asteroids editions assessed separately. This goal continues the work in this checkout; it does not authorize remote or background work on the owner's paused M1.

No title below is a completed faithful rewrite. The current development host is the son's **M5 Pro MacBook Pro, 24 GB RAM**. Release acceptance requires the owner's **M1 Air, 8 GB, 2560 × 1600**, as specified in [M1_TARGET_CONSTRAINT.md](M1_TARGET_CONSTRAINT.md).

| Title / source edition | Current source-backed implementation | Required next work |
| --- | --- | --- |
| PGA2004 / Windows | Offline disc/cabinet reader; available PBL/SAW/STA course records and original engine binaries recovered with integrity checks | Missing cabinet volume 3 and complete source media; version-4 terrain decode and title-specific behaviors/content/modes |
| THPS2 / Windows | PKR2 decoder recovers 3,771 assets | PSX mesh/material/texture/placement, TRG goals, skating/tricks/scoring, content/modes/saves and native runtime |
| THUG / Windows | PRE3/LZSS decode; 47 unique original collision assets; bounded native GHSC loader | Original scene/material/animation/script loaders, skating/walking/driving, missions/modes/saves and native runtime |
| THUG2 / Windows | Three-disc/CAB/PRE3 decode; 94 unique collision assets and native loader | Remaining installation-name/cabinet coverage, scene/material/animation/scripts, original gameplay/modes/saves |
| Apple Panic / Apple II | Source-byte Foundation state/update core; original layout/spawn/type/sprite-mask loader; 13 Swift and five Python checks | Native UI/audio/screens; exact hole-edge/chain-score rules, source randomness/timing, original comparisons, controls/saves and integration |
| Asteroids / Atari2600 | Selected banked cartridge; exact reset/RNG primitive and static instruction records | Main state/variants, motion/collision/splitting, controls/score/lives, art/audio and native session |
| Asteroids / Atari7800 | Selected cartridge; exact rotation, wave arithmetic and explicit-state RNG primitives | Complete lifecycle/options, thrust/motion, collision/splitting/score/lives, sprites/audio and native session |
| Asteroids / Atari8-bit | Selected US XEX; source motion/wrap/reflection/spawn/control/collision/score primitives | Complete scheduler and entities, thrust/hyperspace, waves/UFOs/hit effects, sprites/audio and session |
| Breakout / Atari2600 | Playable native **development reconstruction**, 12 variations / 1–4 player configurations, ROM-derived velocity/score/state tables, save/resume | Reconcile timed second-wall/terminal paths, source raster collision, exact color/audio/control behavior; original comparison |
| Conflict2500 / AppleII | Playable native **development reconstruction** of recovered BASIC rules; scenario, map/tactical/status, commands, AI/turns and save/resume | Applesoft RNG/numeric parity, original display/animation/timing and multi-ship docking prompts; original comparison |
| Crossfire / AppleII | Source-derived native actor/projectile/control/score/ammunition/bonus/wave loop and snapshots; 14 source masks prepared; 12 Swift/four Python checks | Native presentation/audio/input/saves, source timing and startup, integration and original comparison |
| DigDug / C64 | T64 program recovered with load/range/hash metadata | Static loader/game/asset reconstruction, complete original gameplay and native session |
| NFLFootball / Intellivision | Selected cartridge recovered and hashed | CP1610/EXEC/GROM dependencies, original modes/rules/assets and disc/keypad/side-button controls; native session |
| NightDriver / C64 | T64 program recovered; source reconstruction underway | Static unpacking/road/steering/collision/time/score/art/audio, native loop/session and comparison |
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

Initial integration on the M5 passed **110 Swift XCTest** (3 skipped: two opt-in golf snapshots and no audio output). The final Conflict/input corrections passed **12 focused tests** and a native ARM64 build; **166 Python tests** passed after the collision allocation regression. Native UI checks confirmed Breakout launch, short-tap serve, held paddle input, pause/save/return and restored four-ball state. Conflict checks confirmed scenario/map/tactical display, fire/turn progression (energy 22531 to 17531), pause/save/return and restoration at turn 1/energy 17531/tactical view. A final empty-log layout correction and protected tactical crosshair rendering still need their rebuilt UI check. These are functional M5 development receipts, not original comparison or M1 acceptance.

Reproduction:

```sh
python3 Tools/prepare_retro_media.py
python3 Tools/prepare_breakout2600.py
python3 Tools/prepare_asteroids.py
python3 Tools/prepare_other_windows.py
./Tools/build.sh
./Tools/test.sh
python3 -m unittest discover -s Tests -p 'test_*.py'
```

Native development games work without source media; Conflict's original tactical bit patterns require local preparation. Recovery output is reference content, not playable original gameplay. Detailed reconstruction and limits are in [Breakout](research/BREAKOUT.md), [Conflict2500](research/CONFLICT2500.md), [Asteroids](research/ASTEROIDS.md) and [Windows content](research/OTHER-WINDOWS.md).
