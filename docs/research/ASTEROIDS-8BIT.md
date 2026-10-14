# Atari 8-bit Asteroids: native gameplay lifecycle reconstruction

Checkpoint: 2026-10-13, son's M5 Pro MacBook Pro, 24 GB. The selected US XEX now has a native gameplay core that advances ships, shots, asteroids, waves, lives, player turns and the saucer. This is a **development reconstruction**, with no playable hub registration yet. It is not a completed faithful rewrite. No original game was run; no M1 or physical controller acceptance was performed.

## Identity and preparation

The supplied member remains `Asteroids (1981)(Atari)(US).xex`, payload SHA-256 `1cf45090b216c2363131bac2e4db9101a3c162e31686d7fe30474eaba5b7f97f`. Its selected `$5500–$7700` code record has SHA-256 `e24b9792d19d4a8fdeb443bb7201b64b27ab283ec308dc067affea86e12dbf5f`. `Tools/decode_asteroids8bit.py` verifies both archive/member identities before writing original data to ignored `Library/Prepared/asteroids8bit/asteroids8bit.json`.

The prepared package holds source sine values, initial coordinates, projectile origins, asteroid extents, masks, colors, wave counts, explosion scatter/erase offsets and sound sequences. It is about 2 KB, limited to 32 KiB by the runtime loader. The ordered table bytes have SHA-256 `de5c7d6d9e0933f2f6b06a9d8854de47e4e57fbb5ccdaea46d712edab9c41c7a`; the native loader computes that hash, so unchanged source labels cannot conceal altered masks or tables. These copied arrays stay outside Git. [The receipt](evidence/asteroids8bit-lifecycle.json) contains 26 byte-fenced code/table windows with source offsets, lengths and hashes.

The previously indirect `$6F2F` VBI and `$72D7` sound/display callback were disassembled in a separate direct Ghidra project, using the selected code SHA and explicit entry points. The local database/listings/log are ignored at `Library/Research/asteroids/8bit-lifecycle/`. Analysis succeeded without executing a target or firmware. This is direct static analysis, not retained REA Evidence or runtime observation.

## Reconstructed rules

`Sources/GameHub/Asteroids8BitCore.swift` implements title-specific rules. It contains no source CPU, console display engine, POKEY interpreter or generic shared Asteroids simulation.

| Source | Native behavior |
| --- | --- |
| `$6F2F`, `$6F5C`, `$6930`, `$62BF` | One caller-supplied source VBI increments the byte counter. Odd callbacks update players 1/3 and shot slots 0–9; even callbacks update 0/2, shot slots 10–19 and the saucer. The foreground asteroid pass uses five VBI increments. The first pass starts immediately after setup. No host wall-clock or CPU-speed physics is used. |
| `$74DA`, `$6548`, `$6574` | Reachable SELECT values `0,2,10…15,18…23,28…31`; one/two alternating players, two/four-player independent lives, shared-end and paired-team consequences. Every enabled player starts with four source lives and four shot credits. Four independently selected difficulty codes remain numeric source codes. |
| `$6836`, `$6813`, `$67C0` | Authored sine-table thrust, signed nibble extraction, retained carry into doubled Y acceleration, asymmetric source high-byte clamp and bytewise drag. The core preserves these arithmetic details instead of substituting trigonometry or generic inertia. |
| `$689A…$6917` | Active-low turn priority and six-byte heading steps. Down action waits ten player updates; code 0 repeatedly draws authored shield image 18 and bypasses firing/contact checks; code 1 relocates to sampled X/Y and enters a 100-update respawn wait; code 2 adds 127 to heading; code 3 has no corresponding down action. |
| `$69AA…$6A70`, `$638A`, `$6994` | Source trigger-release latch, four shot credits, first-free slot selection, fractional launch-coordinate preservation, authored muzzle offsets, 38-update player/27-update saucer shot lifetimes and source signed shifts. Negative bullet velocity uses the two chained rotates, yielding `4*n+3`, not ordinary `4*n`. |
| `$6A71…$6ACD`, `$626F`, `$6441…$647D` | Lower-exclusive/upper-inclusive projectile bounds, per-source score award, pending-hit flag, two-way large/medium splits, first free descending asteroid slot, 29-slot cap, single small-asteroid removal and 240-frame empty-field wait before the next wave. Seven wave counts cap at 16 large asteroids. |
| `$6B51`, `$6B69…$6C94` | Original broad-phase bounds and reverse asteroid scan; enemy bullet filtering, friendly-fire/team exclusions, source score and life effects, 100-update death delay and safe respawn checks. Native raster overlap gates the bitmap contact path using original masks; original display-latch timing is still unqualified. |
| `$65B3` | Alternating players retain independent asteroid fields and wave counters. Two 240-frame announcement waits bracket the active-player switch. The first activation starts with the source's initial empty respawn counter; subsequent deaths use 100. |
| `$6D05…$6E17` | Source saucer spawning, small/large selection from independent RANDOM samples, 256-even-callback initial timer, byte fire accumulator, random heading, doubled initial projectile steps and alternating vertical-motion intervals. |
| `$6E18…$6EC8` | Twenty-three original explosion slots and eight erasure steps per foreground call; authored XOR scatter/erase pixels. The source can allocate slot zero but its erase loop visits only 22…1; that selected-byte behavior is preserved. During blocking wave/player waits, erasure advances on each source callback. |
| `$71DB`, `$72D7`, `$72AC` | Original sound request priorities, two-byte channel assignment, delay/repeat/parameter sequences and beat/saucer requests. An independent native `advanceSoundCallback()` returns eight parameter bytes; it does not synthesize audio or assert a DLI/analog schedule. |

Scoring delegates to the independently checked source BCD reconstruction: small/medium/large awards, difficulty repetition, trailing display zero, million-unit rollover and middle-byte-nibble bonus lives with saturation. Native `Asteroids8BitSnapshot` includes the whole reconstructed game state, mode, source identity, both saved player fields, shot timers/credits, explosions, saucer, fractional positions, waits and sound channels. Restore rejects invalid source/schema, counts, object types, saved-field types, score ranges and transition states. Sample exhaustion is transactional and leaves both game and sample stream unchanged.

## Inputs, clocks and original graphics

The core requires four original active-low joystick nibbles plus fire booleans. Keyboard/gamepad adapters and launch/return UI are not implemented here. `Asteroids8BitResources.shipMask(image:)` exposes nineteen original five-row masks: sixteen headings, two saucers and shield. `asteroidMask(kind:)` exposes the authored small four-row, medium seven-row and large twelve-row images; `explosionPixels` exposes the source XOR result. Logical bitmap geometry is 160 × 96 with the recovered 159/88 movement limits. Color values remain source bytes; no RGB or monitor-color fidelity is asserted.

`verticalBlank(inputs:random:)` means one source callback, not a claim of 50 or 60 Hz. Atari OS callbacks, video region, raster service budget and its exact within-frame interleaving still need qualification. Native foreground processing and contacts are bounded deterministic scheduling/composition, not an Atari hardware model. Object redraw delays and collision latches can change the selected object/contact frame; source-game comparison is required before calling that behavior faithful.

The core consumes explicit `Asteroids8BitRandomStream` bytes, retaining read count and cursor. No 2600/7800 generator or new PRNG is substituted for POKEY RANDOM. Callers must provide 35 startup fractional coordinate pairs: the recovered reset writes integer positions but does not qualify the preceding `$0400/$0600` values. Tests explicitly use zero fractions and fixed random samples; those choices are test fixtures, not claims about the original machine.

## Verification and remaining scope

Reproduction:

```sh
python3 Tools/decode_asteroids8bit.py \
  --receipt docs/research/evidence/asteroids8bit-lifecycle.json
python3 -m unittest discover -s Tests -p 'test_asteroids8bit_decoder.py'
./Tools/test.sh -XCTest GameHubTests.Asteroids8BitCoreTests
```

All 17 edition Swift tests pass in an isolated temporary package containing only the two Asteroids source files and the edition tests, avoiding concurrent changes to the shared SwiftPM build. The suite checks selected modes and lives, alternating update schedules, source clamp/drag, shot capacity/release, shield/relocation, scoring/splits, 240-frame wave waits, shared/team consequences, two-player field persistence, UFO shots, signed table/rotate behavior, independent sound parameters, transactional sample exhaustion, full-state deterministic save restore and malformed state/resource rejection. Four Python checks pass; they fence every table/code window and reject changed source bytes before output. Logs are `/tmp/gamehub-asteroids8bit-isolated.log`; no shared SwiftPM build was run by this worker. These tests establish native/static behavior and structural safety on the M5 only.

Still unfinished: original menu and attract presentation/behavior, source inactivity transition, high-score ordering/name entry/persistence, OS/startup/font dependency, display-list/P/M alignment and lag, full raster collision-latch comparison, exact carry into opponent-fire death relocation, pixel/color/monitor comparisons, qualified POKEY randomness and region/DLI schedule, analog sound output, selected option UI and all original controls, native launch/save/return integration, physical controller transitions and sustained M1 acceptance. The original code can retain shot credits and RAM across resets; cold native setup is implemented, while arbitrary warm-restart/attract state equivalence remains unqualified. The M1 laptop remains paused and was not contacted.
