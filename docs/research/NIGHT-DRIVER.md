# C64 Night Driver: source rules and original presentation

This checkpoint reconstructs the supplied **Commodore/HAL Night Driver V.01**,
copyright 1982. It does not substitute the Atari arcade game or a generated
perspective racer. The original keyboard instructions are **A** to accelerate,
**L** to steer left, and **;** to steer right. The instruction screen offers
keyboard/joystick start on F1 and paddle start on F3.

The result is a Foundation-only native simulation core and a first-party static
packed-data decoder, with original display data prepared locally. It is **not
yet a playable hub module or a completed faithful rewrite**. The source's
foreground acceleration-loop cadence and crash/melody delays still need a
running-original timing comparison. Original sound synthesis, attract play,
presentation integration, physical input checks and M1 acceptance remain open.

## Selected source and static decode

The supplied `Night_Driver_C64_ROM_EN.zip` is
`f4b34b067a6fd0c954e7de5803aeb88e5b466af4364a1a9a84ca116d4ca41384`.
The selected `Night_Driver_C64_ROM_EN/Game Files/NIGHTDRI.T64` is
`0a23798b7adbe3b2269b19820ac7a78c9077cf2c774a2a90be36dac6c03ea6c6`.
Its sole 4,101-byte program is loaded at `$0801`, SHA-256
`c8be3efca0b9cb49418e3e1fd3659a40b651aa864c53743a4a4a232c33394ad8`.

The BASIC entry calls `$080B`. The loader relocates the packed-data reader from
`$172D` to `$00FB`. Its header supplies the initial bit sentinel `$D5`, source
pointer `$162D` and output pointer `$4000`. Before decoding, a 256-byte stream
tail is copied to `$071C..$081B` to replace the loader/BASIC bytes. Reads then
proceed backward through that relocated prefix and the packed stream.

`Tools/decode_night_driver.py` directly decodes literal runs, byte matches and
the match-length overflow terminator described by `$0108..$0195`. The four
offset width groups are `[4,2,2,3]`. It validates the selected source, bounds all
reads/output, rejects references to unwritten data and checks the complete
decoded identity. It does **not** interpret 6502 instructions, emulate a CPU,
run the original program, or implement VIC/SID hardware.

The 8,449-byte result spans `$1F00..$4000` inclusive, SHA-256
`df49a43b3d8b926c30f92d9434f934fd1c442907fa8e3012e1e10426f1f4a9b1`.
The first page is a MANIK trainer offering unlimited time. Selecting yes
patches `$2C0E`, later relocated to `$EC0E`, replacing the immediate decrement
operand. **The decoder retains the normal, unpatched game.** The trainer's
`$1FC0` range copy maps `$2000..$3FFF` into `$E000..$FFFF`. The extracted 8 KiB
game identity is
`2238c3c9f844d4456edc49d4af00531b34f1caeba92d0a5f6fb83c2317c89b16`.
Its vectors are reset `$E03E`, IRQ `$EBB1`, and NMI `$EC24`.

Direct Ghidra 12.1.2 static analysis used separate loader, unpacked/trainer and
relocated-game profiles with `6502:LE:16:default`, explicit base addresses and
verified input digests. These are **direct Ghidra results, not REA Evidence**.
The isolated database, full listings, pseudocode and command provenance remain
under ignored `Library/Research/night-driver` and
`Library/Research/ghidra-projects/night-driver`. Decompiler output is not
original source and no static finding is a runtime observation.

## Native rules and timing boundaries

`NightDriverCore.swift` stores byte/fixed-point state as small bounded Swift
integers. The two source schedules remain separate:

- `controlStep` corresponds to the foreground `$E120` loop and `$E48E` speed
  calculation. Accelerator and coasting run at this foreground cadence.
- `timerInterrupt` corresponds to `$EBB1`. CIA Timer A reloads `$4E20` (20,000
  source clock cycles). The specific machine clock and resulting wall-clock
  rate must be established during original-game comparison. An interrupt adds
  integer speed to an 8-bit motion fraction, moving the road only on overflow.
- `advanceCrashStage` exposes the four authored crash drawing stages. Source
  delays are CPU-loop and sound-filter dependent; the core does not invent
  their wall-clock durations.

The core preserves the verified foreground source order: speed updates first,
then collision/time flags are checked. A focused regression covers both the
expiry iteration and the collision iteration. Their wall-clock cadence remains
unverified and still needs behavioral comparison after presentation integration.

### Speed and steering

At `$E6FE`, speed zero selects band 0, speed 1..60 selects band 3, 61..150
selects band 2, and 151..250 selects band 1. The low byte of fixed-point speed
uses acceleration `[255,25,35,15]` at `$E4DA` and deceleration
`[255,30,40,45]` at `$E4DE`. The high byte is clamped to 250 on acceleration
and zero on coasting; the source keeps the wrapped low byte in both cases.

Steering occurs on a road progression, not on every display frame. Left adds
200/256 character columns to the road origin; right subtracts the same amount.
Right wins if both keys or joystick directions are held. Paddle steering adds
`2*(reading-128)/256` columns. Source input scanning is at `$E9DE..$EA83`.
Native device mappings and controller transitions still need integration and
physical checks; reading keyboard instructions is not such a check.

### Road and collisions

`$E3FC` constructs nineteen road-center columns from a signed 16-bit recurrence.
Let `s = (bendHigh >> 1) - 64`, begin `delta = -15*s`, and retain the 16-bit
road origin. For each of nineteen rows, first add `s` to `delta`, add `delta` to
the wrapped road origin, and store its high byte as the row center. The car
collision uses center 15 (`$54`): a value below 10 or at least 30 crashes.

`$E4E2` increments bend while its high byte approaches the target high byte in
the sign of the bend step. The target low byte is generated but does not enter
that comparison. On a continuing bend update, the origin changes by
`2 - (newBendHigh >> 2)` fixed-point units. On a reached target, four RNG draws
select the next target and signed step; the current bend is retained that time.

The `$EAA0` RNG is algebraically a 16-bit shift register with XNOR feedback of
old bits 15, 1 and 0, shifted eleven times per draw. Initial seed `$FFFF` yields
`[109,134,194,33,232,246,22,242]` as its first eight output bytes. An independent
byte-arithmetic derivation agrees with that sequence. The simulation seed is
saved and restored; source RNG state persists across new rounds.

`$E3C3..$E3E2` supplies the four eight-post schedules:

| Phase | Post depth rows |
| --- | --- |
| 0 | 0, 1, 2, 3, 5, 7, 9, 13 |
| 1 | 0, 1, 2, 3, 5, 7, 10, 14 |
| 2 | 0, 1, 2, 4, 6, 8, 11, 15 |
| 3 | 0, 2, 3, 4, 7, 9, 13, 17 |

Post columns are `center[depth] ± (depth+1)` with 8-bit wrapping; values outside
0..39 are suppressed. `$E36B..$E3C2` draws posts with one to four character
cells; post indices 3 and 4 use the special glyphs 15 and 16 at depth+1.
`roadCells` exposes those original tile placements for a native renderer.

### Distance, timer and extension

At `$E72A`, every eighth road progression increments the four decimal distance
digits. The decimal point in the original score is presentation. The timer
starts as BCD `$99:$99`; each interrupt subtracts one in decimal. Counting stops
when the high byte becomes zero, leaving fractional 99 after 9,900 interrupts.
The HUD displays only the high byte. It would be incorrect to describe the
integer value as confirmed elapsed seconds before the source timing check.

On expiry, distance at least 600 grants extended play once (`$E1C8..$E228`).
The timer high byte becomes BCD `$50`, retaining its fractional low byte. On
the following expiry the round ends, records a higher score and returns to the
attract/instruction sequence. Source high-score persistence is within the
running process; native Codable snapshots add a development save facility and
must not be described as an original disk-save feature.

## Original display and audio evidence

Run `python3 Tools/decode_night_driver.py` after
`Tools/prepare_retro_media.py` to produce ignored `native-media.json`, retaining
the original data locally. The renderer-facing package contains:

- 256 original 8×8 character patterns from `$F800` (VIC-facing `$3800`).
- Ten original 24×21 digit sprites at `$F400` (VIC-facing `$3400`), and the
  continuous eleven-glyph `0..9,0` strip at `$F980` used for score sprites.
  The source adds a 0..7 scanline offset to roll into the next numeral.
- The authored 40×22 instruction screen at `$EC4C`, HUD labels/colors, five
  eighteen-column car rows, and four crash streams of (column,row,glyph).

The car begins at character column 11, row 15 and spans rows 15..19. HUD state
and sprite placement are reconstructed in `$E7AA..$E903`; the original display
is 40×25 cells / 320×200 pixels. A native renderer can scale these original
patterns while retaining their aspect ratio. No original glyphs or images are
committed to Git.

Static SID setup at `$E692` selects triangle voice 1 and sawtooth voice 2,
gate on, and routes both through the low-pass filter. Their 16-bit frequency
words are `22*speed+1668` and `22*speed+900`. Steering at integer speed at least
170 gates the noise voice, with frequency word `2560+speed`; lower speed or
straight steering disables it. The original engine filter cutoff high byte is
35, resonance/routing `$83`, and master volume/filter mode `$1F`.

The crash initializes noise voice 1 at frequency `$0600`, resonance/routing
`$F1`, then sweeps the cutoff high byte down from 100 before four drawing
stages. `$E26D` plays the high-score melody from `$E22B`; its CPU-loop timing
and actual SID timbre are unverified. No native audio implementation is claimed
at this checkpoint; reproducing these parameters is not proof of audible
equivalence to the original analog chip/filter.

## Checks and remaining work

On the son's **ARM64 M5 Pro MacBook Pro, 24 GB** development machine, the
focused native build passed ten XCTest and the decoder passed four Python
tests. The tests cover decimal timer borrow/expiry, one-time 600 extension,
source speed-band arithmetic, interrupt carries/distance, post placements,
steering priority/paddle units, foreground ordering, RNG sequence, deterministic
snapshot restore, original-media identity, malformed HUD bounds, malformed
packed data and bounded output. They are
static/first-party checks, not comparison with the running original game.

The native session integration follow-up below covers character/HUD presentation
and controls. Next implement source sound with stated SID limitations, port
attract/high-score sequences, establish source cadence/crash delays
against a running original, then capture behavior/visual comparisons. Physical
Fusion Pro and keyboard focus/reconnect tests and sustained **M1 Air / 8 GB /
2560×1600** acceptance remain required. No work ran on the owner's laptop and
no background monitor was created.


## Native development session checkpoint

Native integration follow-up: a separate development hub entry presents original instructions,40×25 character road/car/crash/HUD data and digit sprites, with source keyboard/F1/F3 modes and native arrow/stick/paddle/drag adapters. A single320×200 nearest-sampled bitmap uses256KB temporary pixels and removes per-tile clipping seams; this is an engineering allocation bound, not an M1 benchmark. Rightward stick and drag both decrease the original paddle reading. Independent control and interrupt schedules merge in time order, and taps wait for their relevant update. Development pacing is explicitly120 controls/50 interrupts per second and0.2s per crash stage; none is qualified original timing. Saves retain mode/source state/schedule fractions and restore paused. Live M5 acceleration/save/return/restore preserved speed16/time98. Original RGB/VIC crop, audio/attract/high-score sequences, all source comparisons, physical input and M1 gates remain open. See [QA](../QA.md).
