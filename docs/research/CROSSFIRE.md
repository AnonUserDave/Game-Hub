# Crossfire Apple II reconstruction

2026-10-13 development checkpoint. `CrossfireCore.swift` is a native Foundation implementation of the selected disk's recovered gameplay routines. It does not execute 6502 instructions, Apple II ROMs, emulators, Wine, or Rosetta. Native session/renderer integration is being verified separately by the parent checkpoint. Original colors/audio, live physical controls, original comparison, and release gates remain unfinished. **M1 performance unverified.**

## Selected source and reproducibility

The supplied `Crossfire_Apple-II_ROM_EN.zip` has SHA-256 `cb1078384d332d7edeff8516ab47d4b4d3ded9070ed8d482417497e8a8396a2e`. The selected nested path is `Game Files/Crossfire (1981)(On-Line Systems).DO.zip` → `Crossfire (1981)(On-Line Systems).do`. That 143360-byte DOS-order disk has SHA-256 `4b83b124dd6d71407509b0cdd2829aad2d549d2e5313803b7434640579cb8d9e`.

`Tools/prepare_retro_media.py` decodes the disk catalog and file sector lists without executing the game. Its `CROSSFIRE` binary loads at `$2000`, is 27296 bytes, and has SHA-256 `d1dca8251e6b3d3114e7eeac5aaa34c1d4ed9dc338fed02a8ef6aa6d48efe6c7`. That identity fences analysis, decoding, native saves, and the committed [evidence record](evidence/crossfire.json).

```sh
python3 Tools/prepare_retro_media.py --games crossfire-apple-ii
python3 Tools/decode_crossfire.py --evidence docs/research/evidence/crossfire.json
python3 Tools/analyze_crossfire_ghidra.py \
  --ghidra /path/to/ghidra_12.1.2_PUBLIC \
  --java /path/to/native/jdk/Contents/Home
./Tools/test.sh -XCTest GameHubTests.CrossfireCoreTests
python3 -m unittest discover -s Tests -p 'test_crossfire.py' -v
```

The first-party analyzer builds an ignored address image with the loader's static byte copy: `$2300..$2FFF` → `$0300..$0FFF`. Ghidra 12.1.2 uses `6502:LE:16:default`, the Raw Binary loader, base `$0300`, and independent local project `Library/Research/ghidra-projects/crossfire`. It reuses the generic 6502 export script `Tools/ExportAsteroids.java`. Full disassembly, pseudocode, imported bytes, command provenance, and databases stay in ignored `Library/Research/crossfire`. This is direct Ghidra evidence, not retained REA Evidence; REA's advertised `open_binary` cannot request a raw 6502 processor/load profile. No analysis engine is installed by these commands.

**Startup boundary:** `$2000` calls monitor MOVE `$FE2C` and jumps to `$0800`, but the relocated bytes at `$0800` look like sprite data rather than a valid startup routine. The ordinary game initialization at `$4000` and its directly called routines are statically coherent. The final loader transition has not been established. The native core implements those recovered game routines directly; it does not claim that the original disk has booted successfully.

## Implementation scope

The Foundation core covers source coordinates and geometry, separate movement/shooting inputs, constrained turns, projectile slots, round-robin clocks, all eleven enemy spawn records, shifting/ready/roaming states, chasing, enemy collision reversal, hostile shooting, five explosion steps, four enemy kill stages, BCD-derived scoring and extra lives, three initial lives, ammunition/resupply, four moving bonus records, wave transitions, and validated source-fenced snapshots.

`press(_:)` latches the most recent original key. `move(_:)` and `shoot(_:)` supply equivalent directional events. Movement persists until another movement key or Space is consumed. A successful shot consumes its shooting key; holding a native gamepad direction requires the adapter to produce repeat events. The native core offers main-loop iterations and an explicitly provisional 960 loops/second development clock. It has no UI timer, graphics dependency, background worker, or unbounded asset allocation.

The parent integration owns presentation, hub registration, physical input mapping, saves on disk, status/handoff, and Git checkpoints. A Codable state and deterministic restore do not establish the parent UI's save flow. Native pause may be implemented by that adapter; original Ctrl-S toggles the sound sequencer and does not suspend gameplay.

## Findings ledger

Game-code addresses above `$2000` map to binary offsets by subtracting `$2000`. Copied `$0400` corresponds to source `$2400`. Observations below are static, not original runtime observations.

| Behavior | Byte evidence | Native interpretation and limits |
| --- | --- | --- |
| Game loop | `$4000..$4171`; jump table `$4C40..$4C94` | One projectile slot each main iteration, one enemy every 8, player every 32, resupply blink every 128. Each enemy/projectile pool is round-robin. Death changes the player divider to 128. |
| Keyboard | `$5000..$509F`; copied `$0400..$042A`; `$45D3..$45DA` | I/J/K/L = up/left/down/right; Space stops. E/S/D/F = shoot up/left/down/right. The movement direction is retained separately from the last shooting key. Ctrl-S `$93` toggles audio. |
| Movement and field | `$4420..$44A7`; `$5999..$59EC` | Player moves 2 units per update, X32–192 and Y32–160 inclusive. Turns occur only where both coordinates are multiples of32; a direction requested between intersections retains the current axis until the intersection. Seven columns × six rows of16×16 obstacles lie at `(8+32c,8+32r)` in logical coordinates. The source drawing adds display offsets `(8,7)`. |
| Enemy spawns | `$5974..$5987`, `$5AE6..$5B47`, table `$5BB5..$5BC9` | Three left actors `(0,48/112/176)`; two right `(224,80/144)`; six top `(48/80/112/144/176/208,0)`. Original position and velocity records are retained for respawn. |
| Enemy state machine | `$5200..$5655`; tables `$5662..$5689` | Waiting0, shifting1, ready2, roaming3, eliminated4, dying5, explosion6–10. At most five admitted moving actors; a shared divider and recovered probability tables govern admission, pursuit and firing. Roaming picks a cardinal axis at grid intersections, reverses on another roaming actor, and explodes if a second collision or boundary case prevents movement. Actor collision with the player is lethal. |
| Projectiles | `$4200..$438F`, `$5100..$513D`, `$55BC..$5628`; `$4BE0=6` | Six free-list slots. Hostile allocation reserves the final free slot for the player. Player shots move every selected-slot update; hostile shots every fourth. Both move 2 units, with different source spawn offsets. Friendly hits use strict `abs(dx)<8 && abs(dy)<8`; actor contact uses `<13`, actor collisions `<14`. Projectiles expire beyond X224 or Y188, with source byte wrapping. |
| Kill stages and score | `$4399..$439C`; `$5255..$526B`; `$4900..$49C3` | Successive enemy hits award 10/20/40/80, with respawn until the fourth explosion finishes. Score is decimal/BCD in the original; native stores an integer with six-digit wrap. An extra life is awarded at each5000 boundary: middle-byte carry covers multiples of10000 and the 4→5 thousands transition covers the alternating5000 boundaries. |
| Lives and transition | `$5A63..$5A6E`; `$4780..$47A1`; `$410F..$416B` | Three initial lives. A collision sets the death state once, then a low/high loop counter waits3327 iterations before reset or game-over. A cleared wave uses that wait and resets all stages. Surviving projectiles are retained through position reset, matching the source reset routine's omission of a projectile-pool clear. |
| Ammunition | `$453B..$45C8`, `$5AC9..$5ACE`, `$5D5F..$5D6C`, `$4500..$451D` | Initial35; capacity decreases by5 per wave to15. Fire cooldown is12 player updates. Reaching10 shots places resupply at `(224−x,192−y)`; exact player contact refills to current capacity. |
| Bonuses | `$44AA..$44E9`, `$5C00..$5CBF`, `$5D77..$5D96`, `$45DB..$45E3` | Four records alternate between their authored position and a corridor on a shot divider. The original counter predicate is preserved: an update is admitted while remaining bonus count ≤ remaining enemy count. Successive contacts award100/200/400/800. A255-loop timer removes collected art. The native timer retains an explicit bonus index, replacing dependence on mutable zero-page pointer `$FE/FF`. |
| RNG | `$4D00..$4D1B`; `$401B..$4032`; `$500C..$5014` | Six-byte add/shift recurrence, including carry from both additions. The original seeds from a ROM-maintained keyboard counter; native initialization accepts a fixed byte seed. A newly consumed key resets the first two bytes to `$4E/$4F` as the source does. This is deterministic for a native event sequence, without claiming original boot-time entropy. |
| Sprites | Renderer `$6E0B..$6ECE`; pointers `$4631`, `$473C`, `$51B9`, `$57D5` | The two-byte header gives width in HGR bytes and height. Each row contains seven horizontal phase planes. `decode_crossfire.py` decodes15 selected source sprites into ignored `Library/Imported/crossfire`, with coordinates/digests in `crossfire.json`. Phase0 bits become white masks with transparent background; artifact colors, phase-dependent edge effects and the original display are unresolved. |
| Bonus collectible versus collected score art | Draw `$5780..$57D4`, pointer table `$57D5..$57E0`, sprite `$6300`; display offsets `$4C14/$4C15` | Kind0 uses the original **21×9** collectible at `$6300` (`bonus-idle`), drawn at logical **X+4,Y+3**. Kinds1–4 select `$8100/$8200/$8300/$8400` score art (`bonus-0`..`bonus-3`), drawn at **X+1,Y+4**. Kind5 has a zero pointer and disappears. These are separate source states; hiding kind0 makes collectible bonuses invisible. The decoder checks the actual pointer table and instruction operands before recording the anchors. |

## Verification and remaining gates

The test host was checked with `uname -m` and filtered `system_profiler`: **ARM64, MacBook Pro, Apple M5 Pro, 24 GB, Mac17,9**. Native `CrossfireCoreTests` passed **12 tests, zero failures**. They exercise the exact source spawn/obstacle layout, delayed turns and stop, independent fire latch, blocked cross-corridor fire, hostile pool reservation, four-stage enemy respawn/elimination and scoring, BCD extra-life transitions, mirror resupply, source RNG carry/shift, death wait, wave reset, deterministic save replay, and corrupted snapshot rejection. The collectible-art follow-up passed **five Python tests**, adding the actual kind0 sprite pointer, 21×9 shape, kind-specific anchors and rejected pointer mutation to the existing seven-plane row stride, malformed sprites, revision fence, and selected local loader/actor checks. It regenerated all15 ignored original masks and the committed evidence record without running shared SwiftPM. An earlier isolated Swift typecheck also passed. These are native and static checks; no original game was run.

Before faithful completion: resolve the selected loader, obtain original recordings/behavior references without introducing an emulator, compare enemy timing/selection, firing, bonus behavior, every scoring/life transition, original HGR colors, sound and presentation; complete authored attract/start/game-over visuals, source audio and field/color/font rendering; compare native controls/timing against source and verify physical focus/reconnect; and run the required sustained M1 Air/8 GB/2560×1600 acceptance when the owner makes that laptop available. The current M5 evidence does not substitute for any M1 release gate. No work is scheduled or run remotely on the owner's paused laptop.


## Native development session checkpoint

Native integration follow-up: a separate development hub entry now loads15 original masks including kind0 collectibles and uses the source XOR operation at$6EAC. Idle bonuses anchorX+4/Y+3; score artX+1/Y+4. Enemy explosion states6..10 select0/1/2/1/0. Source keyboard controls and two-stick/button adapters, short taps, held-fire rearming after source cooldown, source stop at intersections, focus/pause neutrality, source-validated saves and native return are implemented. A live M5 shot reduced ammo35→34; save/return restored34 paused. The provisional clock is960 source iterations/second. Original field/artifact color/font/screens/audio/startup/timing and all original/physical/M1 gates remain open. See [QA](../QA.md).
