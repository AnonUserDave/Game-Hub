# Dig Dug: source gameplay map for the native rewrite

Updated 2026-10-14. This is a static implementation map for the corrected supplied C64 body, **not native gameplay or a completed rewrite**. It identifies an implementable order, state and algorithms without executing the original CPU, firmware, VIC or SID. Work was done on the son's M5 Pro / 24 GB. Original-game comparison, physical input and the mandatory M1 acceptance remain unverified; the paused M1 was not contacted.

## Authoritative input and analysis boundary

Use only the 24,576-byte `$6000…$BFFF` body with SHA-256 `90d52fc5c20d64d033d135d16146f5da01e369681373f74756cf33c562de0cda`, produced by `Tools/decode_dig_dug.py`. The default trainer patches remain unapplied. Older wrong-body analyses and decompiler functions that call `$96D1` an unrelated `$A518` routine are not valid evidence for this state.

The matching-SHA listings are ignored at `Library/Research/dig-dug/graphics/all.asm.txt` and `Library/Research/dig-dug/gameplay/all.asm.txt`, with direct Ghidra provenance beside them. Clearing conflicting code/data and disassembling explicit entries without auto-analysis resolves valid routines that previous listings labeled bad instructions. Indirect entry points include the four raster callbacks, four player direction handlers, four hose directions and inflation/deflation callbacks. This is direct static analysis, not retained REA Evidence or an observation of a running game. [The source-window receipt](evidence/dig-dug-gameplay.json) contains hashes and counts, never original code bytes.

The graphics decoder now expands all thirteen bytes of each source spawn record in descending record order into slots **21,19,17,15,13,11,9,7,6,5,4,3,2**. The conditional `DEY` at `$A449…$A453` decrements by two above slot7, then by one below it. The independent regression checks that order; the earlier ten-placement interpretation was incorrect. These are eight odd monster slots and five rock slots, not thirteen monsters.

## Native state to implement

Use named byte-valued fields and bounded collections, rather than a virtual C64 address space or opcode engine. Keep byte wrap, signed tests and carry where the reconstructed algorithm depends on them. The following source locations identify meanings for that first-party state; they are not a request to ship a machine emulator.

| Source field | Meaning and native representation |
| --- | --- |
| Player `$D00E/$D010 bit7`, `$D00F` | Nine-bit hardware X and byte Y. Initial entrance ends at X162/Y142. Horizontal game movement changes X by2; vertical movement changes Y by1. Keep original coordinate units until presentation. |
| `$2B/$2D/$2C` | Requested foreground action, player facing and four-step walk animation. Player directions are 1 right, 2 left, 3 down, 4 up; 5 is fresh pump activation, 0 no requested action. |
| `$57`, `$80…$8F` | Fire-held latch; hose endpoint, sub-byte position, origin, clipping/mask pointers and active/retraction flags. Preserve these independently of the input press event. |
| `$42…$44`, `$40/$41` | Three packed-BCD score bytes and the two-byte award. Native score arithmetic must match decimal carry and byte rollover; the score is not binary fixed point. |
| `$49`, `$4A`, `$46`, `$98` | Source round byte; reserve-life count; extra-life latch; round/life transition flags. `$4A` starts at4, is checked before a retry, then decremented during retry entrance. That is four reserves plus the initial active attempt in the traced control path, not four total attempts. |
| `$3B/$45/$47` | World/intro freeze, sprite-output/death freeze and source pause latch. They gate different systems; one blanket pause flag would change behavior. |
| `$58/$59/$54/$55/$56/$6D` | Recounted surviving monsters, requested player death, active falling rock, crushed-monster count, completed-rock count and player trapped/crushed transition. |
| `$5B/$5D/$5E/$60`, `$B9/$BC` | Foreground wait, signed bonus timer/phase, idle audio timer, alternating world phase and terrain-dependent player movement slowdown. |
| `$C000+i` | Entity Y, where0 disables the slot. There are33 source list slots0…32; player sprite7 is separate. Slots2…6 are rocks, odd7…21 monsters, adjacent even slots effect/expanded sprite pieces, 23…25 fire pieces, 29/30 score/bonus pieces; 0/1/31/32 are special raster callbacks. |
| `$C040+i/$C080+i` | Entity X low/high. For a special callback these two bytes instead hold its function identity. |
| `$C0C0+i/$C100+i` | Color/type-sign and authored sprite pointer, respectively. The renderer at `$AA6B` proves this ordering. A negative color/type-sign selects a callback rather than an ordinary sprite; color0 is a valid color, not an inactive entity. |
| `$C140+i/$C180+i/$C1C0+i` | AI turn/ghost willingness, packed monster/rock phase flags and a secondary countdown. Their meanings depend on actor kind; do not merge them into one generic enemy state. |
| `$C280+i/$C2C0+i` | Monster direction and fire cooldown. Monster directions differ from the player's: 0 up, 1 right, 2 left, 3 down. |
| `$C2C1+i/$C300+i/$C340+i` | Inflation countdown on the adjacent slot, inflation height adjustment and ghost movement cadence. |
| `$C200/$C240`, `$CAFF…$CD00` | Linked-list next/previous and bounded sprite/raster event scheduling records. Preserve stable ordering and semantic callback phases; native rendering need not reproduce a VIC device. |

Terrain must remain the original bitmap state: an 8,192-byte mutable plane with the source's two-bit masks and addressing, plus authored screen/color fields. Drawing the tunnels changes later movement/contact decisions. A generic cell maze or an independent collision grid would lose the bitmap-based predicates. The graphics package already supplies original sparse sprites, transforms, nibble-expanded patterns and tunnel/spawn records; the source font copied from `$D800` remains outside the supplied body.

## Ordered clocks: foreground and raster callbacks

`$8086` resets per-life flags and enters `$80BC`. Each foreground pass has this order:

1. Select the source pause-input column and read the installed helper. A held pause latch disables special world-callback slot31 (`$C01F=0`) and repeats the input loop. On ordinary input it clears the latch and restores that slot's Y marker to59. This is not the player sprite's Y register.
2. Update score display (`$99A2`); service a requested hose cleanup (`$88` through `$8211`).
3. Test the **last raster-world callback's** `$58` count. Zero requests the next-round path `$A0AF`. Then test `$59` for death and `$6D` for a trapped/falling-rock wait. These checks precede a fresh movement read.
4. Read `$96D1`; process bonus collection/display phases; dispatch movement or pump according to `$2B`.
5. Movement calls `$8211` to retract/clean a hose, then `$98D7` dispatches the selected direction. It sets `$5B = 2 + $BC` and waits for the independent timer callback to reduce it to zero. Existing tunnel movement and digging therefore have different waits. Idle/pump paths can return to the foreground input loop without that wait.
6. Restore the sixty-callback activity timer and movement audio state, or switch idle audio once that timer reaches zero.

The main raster IRQ is `$A9FF`, installed at `$A14B`; it consumes a bounded schedule of ordinary sprite assignments and special callbacks. It acknowledges the raster source, advances the event cursor, applies the source comparison with `$D012` and can consume several late events in one IRQ. Source callbacks are initialized by `$A667`:

| Callback | Source responsibility | Native clock entry |
| --- | --- | --- |
| `$BA77` (special slot32) | Countdown-driven SID track sequencing, with a reentrancy guard | `advanceAudioCallback()`; return source sound parameters until native synthesis is qualified |
| `$AAB6` (slot1) | Wait out a particular raster compare, decrement nonzero `$5B`, decrement `$5D` only while nonnegative, decrement nonzero `$60`, complement `$B9` | `advanceTimerCallback()` |
| `$AADB` (slot31) | Rock physics, survivor recount, per-monster inflation/deflation/hose contact, falling-rock/player consequence, then gated AI work | `advanceWorldCallback()` |
| `$A881/$A886` (slot0) | Sort/update the Y list and build the next bounded sprite/callback schedule | `finishSourceFrame()` plus original ordering/visibility records |

The initial special Y values order audio, timer, world and sorting in the source event builder, but exact invocation scanlines, late-IRQ behavior and PAL/NTSC cadence still require qualification. Do not silently collapse all callbacks and foreground iterations into one60Hz tick. The timer/world/audio entry points can be ported and tested independently before selecting a provisional development clock.

Source pause removes the world callback through its active Y marker, while timer/audio callbacks remain eligible. Previously queued raster work can survive until the next sort/build. Thus a global freeze of every countdown is not automatically the original Space-pause behavior; the native system/focus pause must be distinguished from the source action until comparison qualifies it.

`$9AB5` is a separate CPU busy wait: increment a byte until it wraps, decrement X and repeat. It is not a VBI wait. Later complete inner cycles cost2,047 source CPU cycles before loop overhead; the first cycle depends on the incoming byte, X0 wraps to256 outer iterations, and display/interrupt interference changes wall time. Native death/intro delays need an explicit qualified duration or a disclosed development schedule, not host-speed spinning.

## Input, movement and digging

The trainer copies18 bytes from `$723B` to `$0340`. The default call at `$80C2` enters `$0347`, which reads `$DC01` and returns. Its alternate `$0340` entry checks an exact CIA byte and clears `$58` before returning through `$0347`. The optional fourth trainer patch changes the call operand to that alternate entry; native defaults must keep that cheat unapplied. This establishes the input/data behavior; physical keyboard identity and matrix timing still need original/manual confirmation.

`$96D1` first tests active-low fire bit4. The first down sample sets `$57` and returns pump action5; held fire returns action0 until release clears the latch. **Held fire still matters:** `$AC5A` reads `$57` in the world callback, so inflation can continue after the foreground's fresh-press action has finished. An event-only adapter would be wrong. Without fire, direction bits are tested in priority order3,2,1,0: right, left, down, up. Simultaneous directions follow that priority.

Direction handlers are `$8260/$8294/$8311/$82C8`. They retain source facing, animate the authored player frames and honor horizontal/vertical alignment tables at `$0E00/$0F00`. The stack-return escape at `$98D1…$98D7` retries the old direction when a requested turn is off alignment. Port that as an explicit control result, not a native stack trick.

Movement bounds are the source's nine-bit X interval30…316 and Y65…219, with rock predicates at `$836A/$8381/$83A5/$83D5`. Horizontal rock obstruction compares22-unit separation with high-X carry; vertical tests compare source Y offsets and X equality. The four movement handlers then inspect/dig the original bitmap using `$9701/$9707`, `$97E3/$97E7` and the `$9742…$9899` mask writers. `$9C6B` combines generated row and column tables; the native equivalent is a bounded bitmap address calculation, not a display-list interpreter.

Digging increments `$3F` by2 per qualifying call. At22 it clears that counter and awards packed-BCD10 through `$996F`; the same path changes animation and `$BC` so digging uses an extra callback of movement wait. Existing-hole motion has the shorter wait. Source masks, rounding and carry determine which calls qualify; preserve them before rendering work.

## Pump, monsters and Fygar fire

`$84A0` dispatches the first hose in the current facing direction to `$8530/$84C9/$874D/$8688`. These perform original bitmap writes with source masks, clipping and sub-byte positioning. `$85CF/$86FD` can terminate/retract on terrain or an already active hose; `$8211` retracts through direction-specific cleanup. The live hose's endpoint/extent is later compared against monsters by the world callback.

World update `$AADB` first updates rocks2…6, recounts surviving odd slots7…21, then visits every one of those eight monster slots with `$ABA9`. That routine handles rock-crush contact, decrements the inflation timer, checks the hose rectangle and held fire, and limits a callback to one new pump target through `$7D`.

Inflation is a source sprite/state sequence, not four generic hit points:

- `$AE92/$AE9A` classifies current authored frames against the local frame table, including the mirrored variant offset. Its early exit removes a call frame and jumps to a native-equivalent continuation; represent that as a returned state transition.
- `$AD97` starts swelling; `$ADC6` creates/positions the adjacent sprite piece; `$AE38` grows height by2 and raises both pieces by2; `$AE6C` requests the final burst phase and a16-count timer/foreground cleanup. The common `$AF75` resets ordinary inflation/deflation delay to64 world callbacks.
- `$AEBB` decrements a nonzero timer on every world visit. At zero, its source table sends the actor through recovery stages `$AEF7/$AF21/$AF4E`, or final score/removal through `$AD04/$ACB3`. It is not a free-running host-time animation.
- `$AD04` awards depth-based hundreds, using a four-entry original table. Slot15+ doubles the award when the player faces horizontally. It creates score sprites, applies original color/frame/position effects, adds BCD score and schedules removal; the score threshold/extra-life check is not called by every award path.

AI movement is separately gated at `$AB58`. With `$3B` clear, a small counter produces two AI updates followed by one skipped world callback. Updates alternate slots7/9/11/13 and15/17/19/21; each group retains its own modulo-eight animation phase. This is distinct from the per-frame pump/deflation visits.

`$B22E…$B3E1` builds source direction preferences from signed/borrow-preserving player distances, current direction and opposite direction. The last surviving monster instead targets the left/top escape point. `$B3E2/$B438/$B483/$B410` perform up/right/left/down movement, alignment and bitmap predicates. A last monster leaving the left edge at the surface clears itself and the survivor count. Do not replace this with pathfinding on a generic maze.

Ghost conversion uses `$C180 bit7`, `$C1C0`, willingness counter `$C140` and the alternate `$B9` phase. `$B375` can enter a64-count ghost wait; `$B4FA…$B598` probes the actual bitmap for a return to tunnel movement and retains source per-axis cadence. This path and ordinary movement share direction functions but bypass different terrain guards.

Fygar fire is the slot15+ branch of `$AFAB`. Eligibility depends on current authored frame, horizontal direction, cooldown, other active fire owner and bitmap obstruction. `$B0BB/$B180` build left/right fire in slots23…25 with the original frames and24-unit extensions; `$B11F/$B1DD` check player death against byte/high-X bounds. `$B010` tears the pieces down and samples the `$0A00` table for the next cooldown. That table's initialization must be traced through the complete selected startup path before naming it random. The trainer's known `$BD` fill is evidence about that path, not permission to invent a PRNG or assert pristine-release startup state.

## Rocks, bonus, score and transitions

`$B599…$B7C8` is the rock state machine. The `$C180` flags distinguish resting, shaking, falling and landed/breaking states. It probes the original bitmap below a rock, checks player/other-rock obstruction, enters a64-count shake and then moves downward by1 per world callback. A falling rock can carry the player's Y while `$6D` stalls foreground movement. Landing and breaking use48-count phases, authored sprite transitions and source sign/bit tests; the skip over a particular frame is deliberate selected-byte behavior.

Crushed monsters are recorded in a bounded index list. `$B70B…$B7C8` creates source score sprites, awards the original multi-crush value through BCD addition and clears the correct recorded victims. Its high-X add/subtract branches need the same carry as the selected bytes. Each completed rock increments `$56`; the second exposes the bonus entity at source Y142 and starts its signed lifetime phase. Bonus kind, color and points come from the source round-threshold tables used by `$8BDC`; collection at `$8128…$817F` compares exact player/bonus positions, awards score, shows the point marker and changes the display phase.

`$9955` adds the two-byte award to the three BCD score bytes. Overflow sets the display-clear flag. `$996F` additionally checks the score's high BCD byte against the17-entry extra-life table, with a latch so remaining inside the same matching band does not repeatedly award reserves. Some pop/rock paths call only `$9955`; a native global automatic threshold hook would change their behavior.

The level index helper `$A6D8` retains the byte and repeatedly subtracts4 while it is at least16. Tunnel index1 draws layouts0+1; indices2…15 use their own layout. Enemy/rock spawn records consume all thirteen source bytes. `$95DC` advances the source round when a new field is constructed; `$A0AF` is the level-complete transition, distinct from retrying a lost life.

One/two-player selection is stored by the original menu. The alternate player is a saved world, not a fresh random board. `$A15C/$A1F5` copy or swap five source ranges: bitmap8 KiB, screen1 KiB, colors1 KiB, entity/state1 KiB and256 bytes of round/player state. A native snapshot should encode those semantic fields for both players with source identity, current phase, pending waits and held-input latches. It should not serialize hardware registers or a CPU context.

Death at `$B894` first retracts active hose effects, waits for any rock phase, freezes ordinary sprite output, installs the source death bank, runs the authored animation and chooses same/other-player retry or game over. Reserve lives are tested before the next entrance decrements them; an initial active attempt is therefore separate from the four initial reserves. Two-player transitions inspect the other saved reserve field. Game-over presentation returns through the original menu/initialization path; high-score/menu/attract equivalence remains unimplemented.

## Specific unresolved states to preserve

- All claims here are static. No original behavior/visual/audio comparison or M1 result is implied.
- Source callback order, raster lateness, PAL/NTSC rate and busy-wait wall times remain unqualified. Preserve separate native callback/foreground entry points while reconstructing them.
- A carry inherited through `$B7D3`'s high-X rotation and several score/rock coordinate branches must remain an explicit input until its callers establish it. `$B33F` contains an unusual immediate add in its negative-distance path; do not silently replace selected bytes with a tidier signed-distance formula.
- The inflater's classification helpers and off-alignment movement use nonlocal return-stack exits. Native code needs explicit transition enums and tests for both continuations, not a direct pseudocode transliteration.
- Complete `$0A00` cooldown-table provenance, ROM font/banking dependencies, all sound bytecode commands, high-score/name-entry state and the original keyboard matrix mappings still need work. No guessed firmware, noise source or glyph is acceptable.
- Several first-use zero-page values, including the AI gate and busy-wait scratch byte, are not initialized by the bounded game-entry writes traced here. Establish their complete incoming/trainer/KERNAL provenance or require explicit startup fixtures; do not infer that unrelated RAM is zero.
- Source sprite multiplexing can limit/alter visibility and contact timing. A native batch renderer should retain source ordering and recorded visibility effects until original comparison establishes which limitations can be reproduced or deliberately changed.

## Concrete next native implementation

1. Build a bounded `DigDugResources` package from the existing decoder plus the source mask/frame/score tables used here. Hash actual content, retain external dependencies explicitly and validate dimensions/ranges before any session launches. Implement native bitmap addressing and mask writers first; prove authored tunnel initialization and direction-specific dirt changes with independently expressed fixtures.
2. Add a Foundation-only `DigDugState` containing the player, both source player-field snapshots, five rocks, eight monster parents plus bounded child effects, BCD score/reserves, level byte, hose geometry, flags and countdowns. Preserve active/type distinctions and enum mappings. No CPU, virtual memory map or device interpreter is needed.
3. Port one exact foreground pass, timer callback and world callback as separate functions. Return explicit `wait`, `oldDirection`, `retract`, `lifeLost` and `nextRound` results for nonlocal source exits. Test original input priority, held-pump versus fresh press, rock obstruction, byte wrap and2/3-callback AI gating before adding a wall clock.
4. Complete pump classification, inflation/deflation, original monster preferences/ghost/fire and rock/crush/bonus phases using those same native state records. Add source-window arithmetic vectors and deterministic scenario fixtures covering simultaneous rock/pump/death/level-clear ordering, rather than isolated primitive checks alone.
5. Implement source-validated save/restore and both-player field swaps, including halfway through inflation, falling rocks and a pending foreground wait. Decode high-score/name-entry and menu transitions before treating modes/content as covered.
6. Integrate original sprite/bitmap composition and a source-controlled native audio path. Keep clock/color/font gaps visible in the development classification. Verify launch/return and focused/reconnected input, record original comparisons, then seek the owner's newly authorized M1/physical-controller acceptance. The current paused laptop cannot supply those checks.

No code or research result in this map marks Dig Dug playable, faithful, optimized or release ready.
