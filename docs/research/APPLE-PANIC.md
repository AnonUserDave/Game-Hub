# Apple Panic: supplied-source reconstruction

2026-10-13 development checkpoint. A native Foundation simulation and prepared original ladder, spawn and sprite data now exist. This is an incomplete development reconstruction. It is not a verified faithful rewrite. No original or emulated game ran, and M1 acceptance remains unverified.

## Source identity and method

The selected DOS file is `Library/SourceMedia/retro/apple-panic-apple-ii/program-01.bin`: 23,168 bytes, load address `$3B80`, exclusive end `$9600`, SHA-256 `ce05dc96aa47b5da90e55d49124bdd7f2fc3ec135f43b06d7f96ad95dba53abb`. Preparation rejects any other size or digest. The original media, extracted payload, annotated assembly and prepared JSON remain ignored.

[Brent Rector's annotated Apple Panic disassembly](https://github.com/BrentRector/apple-ii-orchard/blob/main/apple-ii/apple-panic/ApplePanic.asm) helped identify routines. The external text remains in ignored `Library/Research/apple-panic/reference-disassembly.asm`. An offline, first-party re-encoder compared all 9,728 reference bytes at `$7000..$95FF` against the actual supplied payload: 9,474 matched, with 40 differing instruction/data records and no omitted records. This is a byte comparison, not a measure of behavioral fidelity. Most differences are mutable state and scratch values; a keyboard patch also changes executable instructions. The public reference's MD5 for `$6000..$A7FF` cannot prove identity because this supplied file ends at `$95FF`.

The reference has missing symbol definitions and a duplicate `ENEMY_TRAPPED` name. Operand addresses were recovered directly from supplied instructions and checked across their uses. The decoder records those explicit repairs, mismatch addresses, window digests and limitations in [the evidence manifest](evidence/apple-panic-static.json). This is direct static analysis, **not REA Evidence**. REA session inspection established no active target; no source runtime or CPU emulator was used. The native executable contains Swift gameplay rules, not a source-CPU interpreter.

## Recovered rules and native mapping

Addresses below are original load addresses; exclusive ends and SHA-256 digests are recorded in the evidence manifest. Some windows include state/table bytes as well as instructions.

| Supplied window | Recovered behavior | Native implementation |
| --- | --- | --- |
| `$7465..$74A1` | New game: three lives, level one; player `(68,160)` and right-facing action | `ApplePanicState`, `beginLife` |
| `$7552..$757B`, `$758B..$761C` | Four 48-byte ladder layouts. Layout selector increments a background counter and adds lives; spawn selector increments again and adds level. Enemy counts are 3/5/8 for `(level−1)%3`; eight type slots use `(level−1)/3` | Prepared original tables, `beginLife` |
| `$7A8C..$7BD4`, `$7CD9..$7D18` | Keyboard direction/actions, one logical X unit per player walk, two Y rows per climb, ladder top/bottom/interior classification | `movePlayer`, `climb`, `platform`; successful up/down actions set the next dig direction through source action parity |
| `$801A..$803A`, `$803E..$80C0`, `$80D3..$817E`, `$81A9..$826B` | Fourteen hole slots per floor; odd X checks seven units ahead, even X checks the current column. Raw `$05` permits falling after lower aligned holes are scanned; partial and occupied holes block. Falling advances two rows and ignores input on landing; partial/occupied cuts within six X units push the player by seven. New-hole clearance also tests empty X=0 slots | `horizontalHoleAction`, `fallPlayer`, `holeDepth`, `nearbyHole`, `movePlayer`; original first-free slot order survives save/restore |
| `$8272..$8310`, `$8402..$848D` | Dig and fill change depth on action frame two, share a ten-frame action counter, select alternate digging pose at frame eight. Full depth is five | `movePlayer`; tests cover shared counter behavior and validation |
| `$87C6..$87DE`, `$8B76..$8D62` | Entry calls the trapped handler in the **same** enemy update. Shallow capture raises Y by depth+1 then immediately climbs one row; a full hole starts at 128 and immediately counts down to 127. Filling the occupied hole starts a drop | `updateNextEnemy`; regressions distinguish capture from an extra uncounted dispatch |
| `$860E..$8701`, `$8702..$87C3`, `$890B..$8A35` | Enemy moves two X units or four Y rows. Crowd collision uses six X units and nine Y rows; enemy/player collision uses four X units, seven enemy rows and fourteen player rows. Junction direction probabilities are 24/144/240, 80/160 or 128 thresholds | `updateNextEnemy`, `chooseDirections`; the absent ROM random stream is replaced with saved seeded randomness |
| `$88BF..$890A`, `$8E61..$9108` | Occupied-hole lookahead is eight X units before movement. Drop descends one row at a time; nonaligned rows call the direction-predicted inclusive six-by-nine collision routine and immediately score each crushed victim. Aligned `$05/$85` cuts multiply six byte accumulators and are cleared. Type 0/1/2 needs one/two/three floors unless an occupied chain overrides that threshold; surviving enemies push eight X units from nearby partial/occupied cuts | `updateNextEnemy`, `dropEnemy`; six source accumulators and the supplied insertion quirk are ported, with stronger-enemy, multi-crush and repeated-chain regressions |
| `$4400..$4433`, `$8E23..$8E4A`, `$83C6..$8401` | Each dispatcher cycle has two player updates, eight round-robin enemy updates and three hourglass calls. Below 30/20/10 hourglass units it adds one/two/three enemy updates. Hourglass decrements every 32 calls from 130 | `tick`, `updateNextEnemy`, `tickHourglass`; source call ordering is preserved in two halves, but native 60 Hz wall-clock pacing is unqualified |
| `$731C..$737E`, `$763B..$7654` | Bonus decrements by 20 after **33** bonus calls (public comment says 32). Initial bonus is `(2+min(level>>2,7))×1000`. A once-per-game extra life tests whether the thousands digit exceeds three | `tickBonus`, `beginLife`, `checkExtraLife` |
| `$9300..$9331` | Bonus transfers when all enemies are gone; level increments; level 49 returns to ROM rather than providing a 49th level | `tick`; native completion at end of level 48 replaces that ROM exit |
| `$8D80..$8D9E` and patched call at `$7A8D` | Supplied version adds ESC pause/resume and Control-R restart | Window fenced independently; pause/restart belong to the native session UI |

There are five diggable platform cuts at pixel Y 16, 48, 80, 112 and 144, plus the ground at 176. Player top Y is 0/32/64/96/128/160. Enemy normal Y is 6/38/70/102/134/166. Logical X is **half an HGR pixel coordinate**: render X as `2×x` on a 280×192 canvas. Ladder collision rows are stored as player top+15.

The actual key table at `$7A12` yields **K right, J left, I up, M down, A dig, S fill**. The public file's header describing D/U and X/E aliases does not match its table or this supplied payload. Native arrow/controller bindings can map to the same semantic actions.

The additional narrow windows in the evidence manifest all match the supplied bytes when the public listing is re-encoded. That validates the instructions used in this checkpoint; no running-original comparison occurred. The first pointer at `$7A22` is the **rightward** dig pose: source action 7 selects it, and `VALIDATE_DIG` checks X+7 for that odd action. The public `SPRITE_DIG_L/R` labels are reversed relative to the actual target. The decoder now names these frames by the validated direction. Climbing up/down writes action 3/4, so their parity also determines the next right/left dig; airborne source action 5 uses the odd standing pose.

## Supplied chain-score behavior

At `$8E61`, six base bytes and six accumulated bytes are cleared, then entry zero receives `type+1`. Each crossed open/full occupied hole adds each nonzero entry's base to its accumulated value. At an occupied hole, an exact-column victim nine rows below is removed, and its `type+1` is inserted. Crucially, `$8F44` performs another `INY` **after finding the first zero base entry**. Base entry one stays zero; successive occupied victims replace entry two. The native code preserves that supplied instruction rather than summing every victim history. Byte additions and the six-entry tally wrap at 256 as in the source.

For example, a type-0 falling enemy crossing occupied holes containing type-2 then type-1 enemies ends with accumulated bytes `[3,0,2,0,0,0]`, awarding **500**. Adding one more open hole produces `[4,0,4,0,0,0]`, awarding **800**. A type-2 enemy crossing one occupied hole containing a type-0 victim awards **700**, even though the ordinary type-2 drop threshold would require a third floor: the chain flag bypasses the type check at `$8FE5`. Ordinary crush victims score immediately and do not enter these chain arrays. An occupied table entry with no exact matching victim returns at `$8EFC`; the native core also stops that descent at the current floor.

The descent remains synchronous in the native simulation, matching source state/control ordering without executing its CPU. Rendering the per-row fall, score-popup delays and four-phase survivor animation is still unfinished.

## Prepared assets and interface

```sh
python3 Tools/decode_apple_panic.py
python3 Tools/decode_apple_panic.py \
  --evidence docs/research/evidence/apple-panic-static.json \
  --reference-asm Library/Research/apple-panic/reference-disassembly.asm
```

The ignored `Library/Prepared/apple-panic/apple-panic.json` is about 11 KB. It contains four ladder layouts, four spawn layouts, sixteen type rows, counts and sixteen original sprite masks. Player frames come from the pointers at `$7A22..$7A35`, three bytes per row for sixteen rows; regenerate this JSON after the corrected dig-pose naming. Enemy frames come from relocated `$1000/$1200/$1400` pages (source `$5000/$5200/$5400`), two frames per type, three bytes per row for ten rows. Seven-bit HGR columns become 21-bit pixel masks. Artifact-color phase bits are omitted; these masks establish source shape, not faithful Apple II color rendering. No extracted arrays or raster media are committed.

`ApplePanicResources.load(url:)` bounds and validates the prepared JSON. `ApplePanicSimulation(resources:seed:)` exposes immutable resources, state, ladders, sprite name, a Codable snapshot and `tick(input:)`. Input values are semantic native commands, not the original numeric animation codes. Resource/source identity, collection limits and coordinates are validated when restoring; the pseudo-random state and dispatcher half are saved so continuation is deterministic. `ApplePanicHole.slot` records the source row's first-free entry so later removal/redig does not change push-out scan order. Older native saves omit this optional field and receive deterministic unused slots on restore; duplicate/out-of-range slots are rejected. These local resume saves extend the source game's lifecycle.

## Checks and remaining completion gates

Development checks used the son's **Mac17,9 / Apple M5 Pro / 24 GB / ARM64** (freshly read with `uname -m` and filtered `system_profiler`), targeting native ARM64 and macOS 14. An isolated native XCTest bundle built directly from the core and its tests passed **25 tests, zero failures**, without sharing the parent SwiftPM build. Seven Python tests passed. Focused Swift XCTest covered initialization, source call counts, ladder/parity movement, seven-unit hole stopping, lower-hole blocking, stacked falling, seven-unit landing pushes, fourteen-slot reuse and scan order, zero-slot dig clearance, ten-frame depth cycles, entry/countdown ordering, eight-unit enemy lookahead, crushing inclusive boundaries and predicted direction, exact occupied chains and repeated accumulator replacement, fill-triggered death, stronger-enemy thresholds, level/bonus/extra-life rules, deterministic legacy/current snapshot replay, malformed states and locally prepared original masks. Python tests covered strict identity rejection, mutation/truncation, listing patch detection, address drift, original pointer/table extraction, actual rule operands and matching narrow hole/scoring windows. The preparation command above regenerated the evidence manifest and ignored original masks. These are native/static checks, not original-runtime comparisons or M1 performance evidence.

Work still required before faithful completion:

- Compare the reconstructed hole/collision/chain outcomes with a running original; the statically recovered rules and authored regressions do not establish runtime equivalence.
- Reproduce visible per-row drop/crush sequences, score popups and the four-phase survivor animation with qualified delay and speaker behavior; the native descent currently resolves synchronously.
- Recover the exact ROM random byte stream and CPU-delay timing without embedding or executing an emulator. Current deterministic native timing and randomness are explicit substitutes; native new-game counters start at zero rather than inheriting the supplied dump's mutable timer scratch values.
- Reproduce artifact colors, backgrounds/floor/ladder/hole tiles, pre-shift variants, title/status screens, font, speaker audio and all animation phases. Current bit masks preserve source silhouette only.
- Validate running original behavior and visuals, hub launch/return, saves, focus and physical Fusion Pro input. Native session integration is tracked by the parent checkpoint.
- Run the mandatory 30-minute fullscreen 2560×1600, memory, swap, thermals and input checks on the owner's M1 Air/8 GB when newly authorized. No remote or scheduled M1 work occurred.
