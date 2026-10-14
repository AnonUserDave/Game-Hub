# Atari 2600 Asteroids native playing dispatcher

Checkpoint: 2026-10-13, M5 development only. `Asteroids2600Core.swift` now reconstructs the selected cartridge's playing dispatcher, packed entities, controls, collision effects, deferred asteroid splitting, waves, scores, lives and alternating players. It is a source-bound native state machine, **not a completed faithful rewrite**. Original game comparisons, native presentation/session integration, source video/audio cadence, physical input and mandatory M1 acceptance remain open.

Selected source: the existing owner-supplied `Asteroids.A26`, 8,192 bytes, SHA-256 `d1a6e808412b4535c7e54fc25414943a9418b1095b4d4969dc33290f7eaa72a4`. The preparation tool validates both archive and selected member before output. All original arrays, masks, full listings and analysis projects remain under ignored `Library/` paths. First-party code contains no copied original table arrays.

## What changed

- `Tools/prepare_asteroids2600.py` creates a bounded local package of 21 original arithmetic/coordinate/extent/color tables and 29 original masks, at `Library/Prepared/asteroids2600/asteroids2600.json`.
- The package carries source and canonical extracted-content identities. The Swift loader checks size **before** reading, validates counts/dimensions/ranges and recomputes the canonical SHA-256 using CryptoKit. A changed table retaining both claimed identities fails validation. The known canonical digest is `22d0866eecfa11c3d8d39e7638964ffa12fc44a8c32a65e8645c1708b2b11c5b`.
- A typed Foundation/CryptoKit simulation consumes the prepared data. It has no original instruction reader, CPU/TIA interpreter, emulator, Wine or Rosetta. A source frame is an explicit call; it does not use host-dependent physics or a floating-point substitute.
- Versioned snapshots retain source identity, both players, asteroid lists, ship position/fractions/velocity, RNG, all three projectile records, saucer state, delayed hit processing, source counters and input latches. Restoration validates player indexes/record counts, source variations, score/life bounds, projectile lifetime and display-state ranges before any indexed game logic.
- 25 Swift cases and seven Python cases pass on the M5. An additional 660,000 native dispatcher steps across all 66 variations preserved slot/save bounds. These are static reconstruction and native consistency checks; they do not observe a running original game.

## Static evidence

The earlier bank 0 import omitted indirect bank-switch destinations. Expanded static entry points `$D600`, `$D900` and `$D90F` recover horizontal movement and the two clipped asteroid graphics continuations. The exporter checks the selected bank hash before disassembly. Bank 0 is mapped at `$D000`, bank 1 at `$F000`; the console mirrors those addresses into its cartridge window. No bank switching is emulated at runtime.

[asteroids2600-native.json](evidence/asteroids2600-native.json) fences 50 data windows and 17 routine windows by bank, address, ROM offset, byte count and SHA-256. Full Ghidra assembly/pseudocode stays local. Source instructions take precedence over Ghidra's guessed low-page pointers and signedness.

| Source window | Native meaning |
| --- | --- |
| Bank 1 `$F000–$F9D9` | Previous-frame collision/split processing, alternating dispatcher, input, velocity, projectiles, death and saucer |
| `$FA03–$FA3A` | Game initialization; four starting ships, original center, source wave setup |
| `$FA3B–$FA9C` | Asteroid/saucer positioning-byte transitions and source speed masks |
| `$FA9D–$FAC1` | Random positioning byte; `$70` high-nibble replacement |
| `$FACE–$FAE1` | Alternating player heading/lives/score exchange |
| `$FAF0–$FBA8` | Two packed asteroid-list collision scans and clipped-pair hit propagation |
| `$FBA9–$FCC9` | Inclusive source extents, ship/UFO/projectile effects, BCD score and bonus life |
| `$FCCA–$FCDB` | Positioning byte to horizontal pixel coordinate |
| `$FCE7–$FDE0` | Deferred large-to-medium-to-small processing, capacity checks and secondary placement |
| `$FDE1–$FEA8` | Packed-list removal, wave spawn, insertion and capacity predicates |
| `$FEA9–$FEDD` | Ship re-entry obstruction lanes |
| Bank 0 `$D600–$D625` | Authored per-pixel packed horizontal movement |
| Bank 0 `$D900–$D91D` | Clipped asteroid graphics reads returning to bank 1 `$F480/$F40C` |

## Playing rules retained

One `frame(input:)` call runs the original dispatcher ordering: previous-display collision/hit work, byte-frame counter/RNG update, then odd-frame asteroid/saucer work or even-frame ship/projectile work. Input therefore samples only the even passes. Host cadence is intentionally outside the core and still needs qualification against the supplied revision.

The two asteroid lists travel upward/downward in the source's 89-row domain. Objects retain their original positioning byte and flag byte. The native code uses the ROM's transitions, not a reconstructed sine/velocity model for asteroid movement. Wrapped/clipped pairs retain source list placement; hit processing is deferred and splits use the original second-object offset of ten rows, randomized flags and opposite horizontal travel. A source capacity predicate limits secondary objects. Wave density depends on the active player's high score byte: two, three or four initial asteroids per list. It is not a generic increasing-wave difficulty formula. Variation 33/66 suppresses the secondary split and keeps the special wave path.

Ship headings are 16 source values. Rotation occurs on the source frame-bit cadence; simultaneous left/right changes cancel. Thrust adds signed authored bytes into the two 16-bit velocities. Idle drag follows the byte arithmetic, and the velocity limiter preserves the pre-limiter displacement for the current pass. Fractional positioning is retained. Positive row 84 wraps to row -5; five clipped top rows stay encoded as `$FB…$FF`, rather than being immediately normalized into the field.

Fire is edge-triggered and prefers slot 1, then slot 0. There are **two** player missiles and one separate saucer projectile. Source lifetimes decrease every fourth frame. All three inherit the source ship velocity contribution, including the saucer shot. The negative projectile horizontal path retains `SEC; EOR #$FF; ADC #1`, including its carried extra pixel. Inactive slots move their anchors two original horizontal pixels using `$D700`.

The source collision dispatcher retries inactive slots within the same frame. Native contacts preserve both CMP-fed ADC carry-ins and inclusive edges. Asteroid hit flags propagate between clipped leading/trailing instances. The source can award asteroid points on a ship collision; the native code retains that behavior.

Scores use the original internal units with a trailing display zero: large asteroid 20, medium 50, small 100, large saucer 200 and small saucer 1,000. They roll at 100,000 displayed points. Source bonus options award at 5,000, 10,000 or 20,000 point boundaries, or disable bonuses. The life nibble caps at nine. Death consumes a life after six even dispatches and leaves the source re-entry delay; alternating player exchange preserves separate scores/lives/headings.

The 66 source variation values are `$00…$3F`, `$80` and `$A0`. The first 32 are single-player options, `$80` displays 33, the corresponding alternating-player group displays 34–65, and `$A0` displays 66. Option bits select bonus intervals, source speed behavior, hyperspace/shield/flip/no special control, alternating players and the special splitting path. Down-only input activates special control; hyperspace requires two down samples and uses the current source RNG bytes, shield failure uses its 32-sample counter and flip is latched until release. No unsupported marketing difficulty names are assigned. The source difficulty switches gate saucers independently; the native input currently supplies an explicit boolean for the active player.

The selected `$D800` movement table is **not** the inverse of `$D700`. `$D700` traverses 160 unique pixels; `$D800` traverses 162 positioning codes and contains `$65 → $83`, decoded X 13 → 14. Both Python and Swift regressions retain the actual bytes. This anomaly needs a running-original comparison; it has not been silently repaired.

## Original presentation data and unresolved work

The package decodes nine ship masks with reflection, three explosion masks, a shield, small/large saucers, four asteroid masks and ten three-pixel HUD digits. HUD rows are reversed according to the score kernel's decrementing pointer. It also records original asteroid color values. These are original data extractions; they do not establish correct native rendered pixels.

Still unfinished:

- TIA intraline positioning, repeated/stretched asteroid pixels, authored scanline crop, RGB conversion and complete title/attract/console selection/reset screens. The masks alone do not resolve those kernels.
- Original sound-register sequencing and audible output. The semantic event stream is bounded, but it is not original audio.
- Frame standard/cadence and detailed graphics/collision traces from a running original revision. Static source arithmetic tests cannot certify this.
- Native session/view/registry integration, keyboard and physical controller mapping, short input pulses across the source scheduler, pause/focus/reconnect handling, disk saves and launch/return checks. The core supports snapshots; a hub session has not been delivered by this checkpoint.
- Broader original fixtures for clipped splitting and pathological boundary/counter combinations. Current tests include deterministic source edge cases and bounded native stress, rather than exhaustive original equivalence.
- Sustained M1 Air / 8 GB / 2560 × 1600 performance, memory/thermal measurements and Fusion Pro physical input. The owner's paused laptop was not touched.

## Reproduction

```sh
python3 Tools/prepare_asteroids2600.py
python3 -m unittest discover -s Tests -p 'test_asteroids2600_media.py'
./Tools/test.sh -XCTest GameHubTests.Asteroids2600CoreTests
```

Static imports use the existing `ExportAsteroids.java` with the selected bank SHA. Add `$D600/$D900/$D90F` to bank 0's explicit entry points; corresponding local expanded output is `Library/Research/asteroids/2600-bank0-expanded/`. Supplementary bank 1 reads at `$F480/$F40C` are bound directly to actual selected bytes. The original analysis command and installation paths are already recorded in each ignored bank's `provenance.json`; no target code is executed by those commands.

Tests requiring original tables explicitly skip if owner media is absent; they never substitute synthetic or generated gameplay data. Current local tests used the original prepared package and skipped none. Hardware was the son's M5 Pro MacBook Pro, 24 GB, macOS 26.3. **This is not M1 or original-game acceptance.**
