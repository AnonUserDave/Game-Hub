# Preppie! Atari 8-bit: selected-source reconstruction

Checkpoint: 2026-10-14. The supplied US XEX now has a bounded original-data decoder and direct static callback/control map. This is a **source foundation**, not native gameplay, an emulator, or a completed rewrite. No original was run. Ten Python tests and preparation pass on the son's M5 Pro/24 GB; that is not original-game comparison, physical-controller evidence or mandatory M1 Air/8 GB acceptance.

## Selected revision and source boundaries

`Preppie!_Atari-8-bit_ROM_EN.zip` hashes to `c9a99331845fd13d6ea3aea30127f759369a29e6b6b204a545f66500d97395be`. The exact nested US member `Game Files/Preppie! (1982)(Adventure International)(US).zip` → `Preppie! (1982)(Adventure International)(US).xex` is 23,320 bytes and hashes to `802fd22e3b866f001ab1bffae7422c62e906461e6460540761bead260ed710f5`. Alternatives/trainers were not substituted. REA inspected the actual archive first: Evidence `ev_67f7358b36654dd77d5129fa36312f052b3e405aa017439319333f6ba17fd6d6`. That records archive identity/inventory, not 6502 behavior.

The XEX records remain ordered:

| Record | Supplied load range | Bytes | Meaning from selected bytes |
| --- | --- | ---: | --- |
| 0 | `$3000–$5000` | 8,193 | Loading-screen code/data; INIT points here |
| 1 | `$02E2–$02E3` | 2 | INIT `$3000` |
| 2 | `$5500–$9000` | 15,105 | Loader, game and data before relocation |
| 3 | `$02E0–$02E1` | 2 | RUN `$5580` |

At `$5580`, the selected loader installs `$5500` in the OS callback pointer and jumps to `$E474`. The `$5500` callback clears `$0500–$3BFF`, then copies 59 pages from `$5600–$90FF` into `$0600–$40FF`. **The supplied record ends at `$9000`. The final 255 source bytes `$9001–$90FF`, and hence relocated `$4001–$40FF`, are unknown prior RAM.** They are never fabricated as zero. The actual known 14,849-byte relocated region `$0600–$4000` has SHA-256 `e01ad59aee16357addb667483917cded5a490e443e97d9e38fde37b73bcd5ac7`.

After copying, `$555A` assigns the next callback `$1B01`, sets `$0244=0`, patches `$0600=$90`, calls `$0645` for display/color setup and jumps to `$1B01`. Code at `$55B0` later jumps to the actual new-game entry `$06CF`. The source at `$0600` includes a six-byte load header; treating it as the gameplay entry is incorrect. INIT ordering is reported from the XEX and standard loader convention; no original OS loader was executed.

`KnownSource.read` rejects every read outside the supplied relocated range. A second dependency appears in the composite sprite table: ten of its eighty pointers are zero, and the selected copy routine reads ten bytes at that pointer without a null check. Their original source is `$0000–$0009` OS/RAM, **not a supplied blank sprite**. The decoder records those reads explicitly rather than generating empty rows.

## Original data prepared

Run `python3 Tools/decode_preppie.py`. It verifies archive/member/XEX identities before decoding and writes only under ignored `Library/Prepared/preppie/`. The JSON is 158,860 bytes, bounded to 256 KiB; full binaries, original arrays and static disassembly stay ignored. The [hash/count receipt](evidence/preppie-static.json) contains source ranges and identities only.

- Ten source-indexed level records. `$076D–$081A` caps the level selector at index 9, dereferences five data groups (lengths 6, 6, 4, 3 and 19) through `$2B83/$2BB5`, and loads them into runtime counters/conditions. Six additional ten-entry parameter tables at `$32FD–$3338` establish delays, flags, goal counts and event bases. These are source indexes, not ten independently accepted levels.
- Twelve original 48-byte lane rows per level: 120 records, selected through twelve level-pointer tables at `$2C17–$2D06`, then copied to the source destinations `$3350/$3450/$33A8/$34A8/…/$38A8`. The decoder retains source/destination addresses and exact bytes. The code mirrors forty columns between adjacent lane buffers after these copies.
- Three referenced 1,024-byte character banks at `$1800`, `$1C00` and `$3C00`: 384 eight-row glyphs, decoded as both one-bit and two-bit indexes. These are source bytes, not qualified final pixels. The game changes CHBASE within the display, and runtime patches modify some glyphs; unused bank bytes can also contain code. No claim is made that every raw glyph is authored visible art.
- A five-part × four-direction × four-frame player/missile pointer table at `$2100`: 80 records, 70 known reads, 41 distinct supplied ten-byte masks and ten explicit zero-page dependencies. The copy operation at `$1536–$1573` places these parts into the source missile/four-player memory pages and offsets, retaining authored composite data instead of drawing a substitute character.
- Three finite authored ANTIC descriptors: loading at `$3100` in the initial segment; menu at `$0AEB`; play at `$3400` in relocated memory. The play descriptor has 26 DLI flags and an exact 26-entry handler-address table at `$394C`. Descriptor parsing records modes, LMS references, scan lines and JVB; it does not execute ANTIC, render DMA, infer collision latches or assume a prior OS DMA-width value.

The [original Atari hardware manual](https://www.atarimania.com/documents/atari-400-800-hardware-manual.pdf) documents the character and player/missile formats. Only bit unpacking and descriptor structure are used here. NTSC/PAL, inherited OS state, screen crop, palette/priority and scan-line behavior still need qualification.

## Source lifecycle, controls and schedule

Direct Ghidra imports use `6502:LE:16:default`: loader bytes at `$5500`, then the exact known relocated bytes at `$0600`. Explicit corrected entry seeds include `$0606`, `$0645`, `$06CF`, `$1012`, `$1187`, `$1261`, `$12AF`, `$13E6`, `$3200` and `$1B01`. Both imports exit 0. Their listings/pseudocode remain in `Library/Research/preppie/{loader,game}/`. These are **direct static exports, not REA Evidence**, and indirect/self-modifying targets, OS calls and hardware semantics remain incomplete. `Tools/ExportAsteroids.java` is the existing identity-checked general 6502 exporter used for these local profiles; the full commands are retained in each ignored provenance file.

| Source entry | Recovered responsibility | Native implication |
| --- | --- | --- |
| `$1B01/$1B56` | Installs/saves callbacks; menu; player/control options; start-level selection | Separate menu/new-game state; preserve source option combinations |
| `$06CF/$0702` | Initializes per-player scores/lives/levels, resolves level data, prepares scene and starts round | Typed two-player/round/level state with immutable source package |
| `$099C` | Ordered foreground gameplay dispatcher | Preserve wait/flag ordering rather than update by host CPU speed |
| `$1012` | Timer 1: time-bar decrement/rearm and source color warnings | Countdown callback at its source-selected period |
| `$1187` | Timer 2: authored music command stream and rearm | Future bounded native music state machine, not a CPU interpreter |
| `$1261` | Immediate VBI: selected audio updates and saved OS-vector chain | Separate VBI callback and explicit OS dependencies |
| `$12AF` | Gameplay deferred VBI: counters, six lane phases, screen references and player carry | Native lane scheduler must retain phase and move/carry order |
| `$13E6` | Menu deferred VBI exits through `$E462` | Keep menu/display callback distinct from gameplay |
| `$3200` | DLI dispatcher patches its jump from the `$394C` table | Reconstruct authored scene/palette bands; no general DLI executor |

`$1434` reads OS joystick shadows `$0278+index`, XORs the active-low nibble and uses the selected source direction table. `$0284+index` is the trigger; only source-allowed vertical positions/directions enter the jump sequence. One/two players are selected through `$2019`; `$201B` chooses shared joystick 0 versus current player's joystick. Console values 6/5/3 are tested for start/select/option. Menu digits are translated through the **unsupplied OS lookup at `$FEFE`**, accepting ASCII 1–9 as start indexes 0–8. Pause/reset checks use raw CH values `$BE` and `$EC`; their physical key names are not guessed here.

The foreground waits on changes to RTCLOK low byte `$14`, sometimes processing a pending flag during the wait. It tests OS timer flags `$022A/$022C` before actor/player work. `$3164` writes the appropriate countdown timer at `$0216+2×timerIndex`; source periods and callback rearming remain separate. The [Atari OS Technical Reference](https://bitsavers.trailing-edge.com/pdf/atari/400_800/CO16555_Atari_Home_Computer_Technical_Reference_Notes_1982.pdf) distinguishes immediate/deferred VBI, software timers and RTCLOK. Those facilities, POKEY RANDOM reads at `$D20A` and GTIA collision reads are dependencies, not observations of source cadence or measured NTSC/PAL timings.

## Next native-core plan and acceptance gaps

1. Port `$1B01/$06CF/$099C` into explicit menu, round, player-turn, life/death and level transitions. Preserve both lives/score/level arrays and all player/joystick/start-level options. Do not replace source goal counts or cap behavior with a genre template.
2. Supply an explicit clock/input contract: VBI step, source OS timers/flags, raw keyboard/console/joystick state and independently consumed random samples. Keep missing OS/RAM values required or clearly labelled synthetic development inputs; never label a synthetic page an original startup. Snapshot all source counters, phases, mutable masks/lanes and random-sample cursor with selected source/version identity.
3. Port six-lane scrolling/carry in `$12AF`, player animation/jump at `$1434`, and the foreground's collision/ball pickup/return/goal/bonus/death/turn rules (`$0C06–$0F78`, `$3067…`). Derive native contact predicates from the original masks, characters, control flow and latch-clear points. Original raster contact order remains a fidelity gate; a generic rectangle/circle Frogger model is insufficient.
4. Construct original character bands and five-part PM masks with source placement/palette/priority data; apply runtime glyph changes and authored DLI bands. Add the actual sound/music stream reconstruction. Decode the initial bitmap only after its inherited OS width/crop assumptions are explicit.
5. Integrate async bounded assets, release-safe keyboard/controller input, working source-bound saves, launch/return and visible unresolved source dependencies. Then record meaningful original behavior/visual/audio comparisons and perform physical Fusion Pro plus sustained M1 Air/8 GB/2560×1600 acceptance when the owner makes that machine available.

Ten Python tests cover identities, ordered loads/overlaps, unknown-memory rejection, every level/lane/composite record, font bit unpacking, finite display descriptors and bounded local preparation. No Swift runtime, native module, original playback, original screenshot equivalence or M1 acceptance is claimed by this checkpoint.
