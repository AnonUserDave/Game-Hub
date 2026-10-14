# Asteroids: three separate source-bound native reconstructions

Checkpoint: 2026-10-13. The three Asteroids editions now have separate source-bound native gameplay cores, bounded original-media decoders, source-window/content hashes and validated lifecycle snapshots. **None is a complete or registered playable rewrite.** Native session/presentation integration is still required. The tests were run on the son's M5 Pro MacBook Pro with24GB RAM, native ARM64. **M1 performance, original-game comparisons and physical controller acceptance remain unverified.**

Current lifecycle details supersede the initial primitive-only scope below:
[Atari2600](ASTEROIDS-2600.md), [Atari7800](ASTEROIDS-7800.md) and
[Atari8-bit](ASTEROIDS-8BIT.md). The new cores pass25/16/17 edition Swift tests
and7/5/4 decoder tests, respectively. All three prepared original packages have
canonical content integrity. The7800 needs explicit prior RNG RAM/timer; the
8-bit needs explicit RANDOM samples and35 prior coordinate fractions. Original
hardware state is not silently replaced by a common-edition generator.

## Scope and acceptance for this checkpoint

- Verify the supplied archive and selected payload independently for each edition; choose the plain US XEX rather than an alternate, trainer or disk conversion.
- Prepare explicit bank/load records in ignored directories without running or emulating any original code.
- Recover implementable behavior from actual selected bytes. Keep unresolved hardware state explicit instead of inventing a common Asteroids model.
- Bind each recovered routine to its file offset, mapped address, byte count and SHA-256. Test native arithmetic and malformed container handling.
- Leave complete-game claims, original visual/audio fidelity, module integration and sustained M1 acceptance open.

The source and test changes are `Sources/GameHub/AsteroidsCore.swift`, `Tests/Swift/AsteroidsCoreTests.swift` and `Tests/test_asteroids_media.py`. Extraction and research tools are `Tools/prepare_asteroids.py`, `Tools/analyze_asteroids_ghidra.py` and `Tools/ExportAsteroids.java`. Machine-readable evidence is [asteroids-static.json](evidence/asteroids-static.json).

## Selected references

| Edition | Selected payload | Bytes | Payload SHA-256 |
| --- | --- | ---: | --- |
| Atari 2600 | `Game Files/Asteroids.A26` | 8,192 | `d1a6e808412b4535c7e54fc25414943a9418b1095b4d4969dc33290f7eaa72a4` |
| Atari 7800 | `Game Files/Asteroids.A78` | 16,512 | `ec6ef6179644041a9fb77fc6b7c917387219fc388dd5a0fbf8236677f279402e` |
| Atari 8-bit | `Asteroids (1981)(Atari)(US).zip` → `Asteroids (1981)(Atari)(US).xex` | 8,717 | `1cf45090b216c2363131bac2e4db9101a3c162e31686d7fe30474eaba5b7f97f` |

`prepare_asteroids.py` fixes the complete archive member paths and both levels of byte identity. It never calls arbitrary archive-path extraction. Every reference is validated before any output is written. The archives and extracted originals stay ignored. This selection establishes a reproducible local baseline; it does not prove that the supplied revision is an original retail dump.

The A78 carries a 128-byte header, a declared 16,384-byte code payload and code SHA-256 `a1e293ed0e1af9ea6a7df257440a50e40a4ae9088d6bcf4800a5a6f51780183d`. Header fields are reported as raw declarations, including controller bytes `1/1`, flags `0`, region byte `0`. No mapper or region behavior is inferred from the filename.

The XEX contains one 8,705-byte segment `$5500–$7700` at file offset 6 and the two-byte RUN vector `$02E0–$02E1` at offset 8,715. The RUN address is `$5500`. Its loader enters `$5600`, installs `$5617` as an OS callback and jumps to `$E474`; those OS transitions were inspected statically and were not executed.

## Recovered native behavior

### Atari 2600

`Asteroids2600Random` reconstructs bank 1 `$FAE2–$FAEF`. The reset routine `$F9EA–$F9EE` initializes both zero-page state bytes `$81/$82` to `$34`. The function derives feedback from bits 5 and 6 of `$81`, rotates it into `$82`, then rotates the former high bit of `$82` into `$81`; it returns the new `$82`. The reset output sequence begins `105, 210, 165, 75, 151, 46, 92, 184`. All 65,536 possible states are compared with a separate instruction-arithmetic expression in XCTest. Snapshot encode/decode preserves the generator sequence.

Bank 0's reset vectors contain `$D591`, bank 1's `$F9DA`. The static imports use `$D000` and `$F000` respectively, preserving the cartridge's mirrored addressing. The bank switch trampolines are `$DFF0` (`STA $FFF9; JMP ($F7)`) and `$FFF0` (`STA $FFF8; JMP ($F7)`). Bank 0 `$D591` builds a pointer to `$F9DA`; bank 1 `$FF97` builds a pointer to bank 0 `$D43C`. The title-display entry `$DB00` and those entry addresses seed the two separate databases. This explains why treating the 8 KiB as one flat program loses control flow. The native primitive does not interpret these instructions or simulate the console.

The playing dispatcher,66 variations, packed motion/collisions/splitting/waves,
ship controls/BCD/lives and alternating players now exist in the2600 core.
Remaining: complete TIA/selection/attract/HUD composition, audio/cadence, native
session/input/save/launch/return and all comparison/physical/M1 gates. See the
edition ledger for retained selected-ROM anomalies and unqualified fields.

### Atari 7800

`Asteroids7800Rotation` reconstructs the speed-dependent turn step in `$D32C` and heading/image updates at `$D389/$D391`. High velocity bytes are signed magnitudes. The normal step is `8 − |vxHigh| − |vyHigh|`; the original ADC/SBC carry is retained even for the `$80+$80` edge case. Heading wraps as an 8-bit value. Image codes use `(heading >> 3 & $FE) + $B5`, yielding 16 distinct directional images. The API exposes increasing/decreasing heading without guessing the native rendering orientation.

`Asteroids7800Wave` reconstructs `$F827–$F85B`. The wave number increments as a byte; asteroid count includes the carried addition of 2 and the difficulty index, then caps at the four original limits `[8, 12, 14, 16]` from `$F896`. The saucer timer starts from `[0, 167, 149, 143]` at `$F89A` and applies **three chained SBC operations**, retaining borrow. A host expression `base − 3×wave` would differ after a borrow. This native routine is called explicitly; it does not yet reproduce the surrounding wave-start eligibility checks or timer cadence.

`Asteroids7800Random` reconstructs `$F8B2–$F8D2`. It adds two bytes from the RAM page at `$2100`, writes the sum back at the first index, decrements both indexes and resets a negative index to 54. Initialization at `$D01E–$D034` copies 55 bytes from the original code at `$D000`, sets the first index to a timer sample masked by 31, and the second to `first + 31`. The second index can initially be 55–62. **The program does not initialize those extra bytes in this routine.** The preceding clear routine clears `$1800–$1FFF`, not `$2100`. The native initializer therefore requires the caller's existing 256-byte RAM page and the local ROM seed table. It does not assume zeros. The supplied first-party source contains no copied code-byte seed array.

The four-mode ordered lifecycle/controls/thrust/drag/entities/shots/collisions/
splits/score/lives/hyperspace/wave/UFO loop now exists in the7800 core. Remaining:
real startup/optional firmware, pair-order/terminal reconciliation, complete
sprites/display-list/colors/HUD/sound/cadence, native session and source/physical/
M1 gates. See the edition ledger; raw graphic indexes are not calibrated pixels.

### Atari 8-bit

`Asteroids8BitMotion` reconstructs `$6186–$61C4`: signed 16-bit fixed-point velocity is added with wrap to coordinates whose low bytes are fractional. The returned flag reports an integer-coordinate change before boundary processing. Source pages are X `$0400/$0500`, Y `$0600/$0700`, X velocity `$0800/$0900`, Y velocity `$0A00/$0B00`.

The bounds at `$61E9–$626E` are `$9F` horizontally and `$58` vertically. Detection includes the object extent using byte addition. Wrap/reflect replacement chooses integer byte `1` for positive motion or `limit − extent − 1` for negative motion; the fractional byte is preserved. Reflection uses **one's complement on both velocity bytes**, rather than mathematical negation. The surrounding `$63A7` path selects reflection when `$A7` is nonzero and wrap otherwise.

Spawn velocity at `$63C3–$63FF` consumes four independent reads from `$D20A`. Magnitudes OR `$10` (also `$80` when flag `$A8` is nonzero); sign samples select a positive or one's-complement negative component. `$6400–$6424` independently chooses X integer edge `2/$8F` and Y `2/$48`, preserving existing fractional bytes. The native helpers take explicit random samples. `$D20A` is identified as POKEY RANDOM by the [MADS library's POKEY register documentation](https://mads.atari8.info/library/doc/pokey.html); no hardware random generator is emulated or replaced by either cartridge edition's RNG.

`Asteroids8BitCollision` reconstructs the predicate at `$6A71–$6AD4`. Objects whose high type nibble is nonzero and projectiles with bit 7 set are excluded. The projectile must be strictly beyond both lower coordinate edges and at or within both upper edges, with byte wrapping in the addition. The native predicate accepts the original extent explicitly. The surrounding source loop scans projectile slots `$85–$99`; slot allocation and hit effects have not been ported.

`Asteroids8BitControl` reconstructs the active-low input rules at `$689A–$68B9`: cleared bit 3 increases heading by 6, otherwise cleared bit 2 decreases it by 6. Simultaneous left/right bits therefore take the increasing branch. Cleared bit 0 requests thrust in `$6836`. The native adapter must still supply the correct original nibble; keyboard/gamepad mapping is not implemented by these helpers.

`Asteroids8BitScore` reconstructs `$6C9A–$6CB5` and `$7004–$702B`. Awards `[1, 2, 5, 10, 25, 50]` are the decimal values of the original BCD table at `$6CB6`. Each is repeated `floor(difficultyCode/2)+1` times. The three BCD score bytes roll over at one million internal units; the display appends a trailing zero. A change to the middle byte's high nibble requests a bonus life and sound `$95`; the life byte saturates at 255. This preserves individual repeated-award checks. Native score state validates its input range. It does not assign semantic difficulty names or initialize player lives.

The selected-mode/multiplayer/VBI/foreground lifecycle, source controls/thrust/
shots/shield/relocation, hit/split/wave/UFO/player consequences, authored masks,
explosions, sound parameters and snapshots now exist in the8-bit core. Remaining:
menu/attract/high scores/OS/font, qualified RANDOM/startup/region/DLI/raster/death
carry/audio, native options/session/input and all source/physical/M1 gates.

## Reproduction and verification

```sh
python3 Tools/prepare_asteroids.py
python3 Tools/analyze_asteroids_ghidra.py \
  --ghidra /path/to/ghidra_12.1.2_PUBLIC \
  --java /path/to/java/Contents/Home
python3 -m unittest discover -s Tests -p 'test_asteroids_media.py'
./Tools/test.sh -XCTest GameHubTests.AsteroidsCoreTests
```

The analysis pipeline's four sequential raw-import profiles use `6502:LE:16:default`, an explicit load base, a 768 MiB analysis heap and two GC/compiler threads. These are offline analysis limits, not game runtime settings. It verifies imported-program identity in the Java exporter. Projects, full assembly, pseudocode and logs remain under ignored `Library/Research/` and `.tools/`; original bytes remain under ignored `Library/SourceMedia/asteroids/`.

Verified on the M5: all three archives and selected payloads match the existing inventory; all four direct Ghidra profiles exit 0 without analysis timeout; 5 Python media tests pass, including malformed-container checks, hash rejection before output and source-window hash validation. The focused Swift suite passes 12 tests, including the exhaustive 2600 RNG check. These checks compare static reconstruction and independently expressed arithmetic. They are not observations of any running original or M1 acceptance.

Do not mark these editions completed until complete native games, all original content/modes/controls, saves, reliable launch/return, original behavior/visual comparisons and the mandatory sustained M1 benchmark have passed.
