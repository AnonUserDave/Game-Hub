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
| `$7A8C..$7BD4`, `$7CD9..$7D18` | Keyboard direction/actions, one logical X unit per player walk, two Y rows per climb, ladder top/bottom/interior classification | `movePlayer`, `climb`, `platform`; horizontal hole-edge handling remains approximate |
| `$803E..$80C0`, `$80D3..$817E` | Falling advances two rows; dig requires odd X, a floor-aligned Y below 160, bounds, clearance from ladder and neighboring holes | `movePlayer`, `holeIndex`; source partial-hole push and stacked-hole traversal remain incomplete |
| `$8272..$8310`, `$8402..$848D` | Dig and fill change depth on action frame two, share a ten-frame action counter, select alternate digging pose at frame eight. Full depth is five | `movePlayer`; tests cover shared counter behavior and validation |
| `$8B76..$8D62` | Shallow-hole capture raises enemy Y by depth+1, then it climbs out. A full hole sets occupied bit and captures for 128 of that enemy's updates; filling the occupied hole starts a drop | `updateNextEnemy` |
| `$860E..$8701`, `$8702..$87C3`, `$890B..$8A35` | Enemy moves two X units or four Y rows. Crowd collision uses six X units and nine Y rows; enemy/player collision uses four X units, seven enemy rows and fourteen player rows. Junction direction probabilities are 24/144/240, 80/160 or 128 thresholds | `updateNextEnemy`, `chooseDirections`; the absent ROM random stream is replaced with saved seeded randomness |
| `$8E61..$9108` | Enemy type 0/1/2 needs one/two/three floor drops. An isolated kill contributes `100×(type+1)×floors dropped`; stacked open holes add another multiplier | `dropEnemy`; simultaneous multi-victim chain scoring is approximate and needs its six source accumulators ported |
| `$4400..$4433`, `$8E23..$8E4A`, `$83C6..$8401` | Each dispatcher cycle has two player updates, eight round-robin enemy updates and three hourglass calls. Below 30/20/10 hourglass units it adds one/two/three enemy updates. Hourglass decrements every 32 calls from 130 | `tick`, `updateNextEnemy`, `tickHourglass`; source call ordering is preserved in two halves, but native 60 Hz wall-clock pacing is unqualified |
| `$731C..$737E`, `$763B..$7654` | Bonus decrements by 20 after **33** bonus calls (public comment says 32). Initial bonus is `(2+min(level>>2,7))×1000`. A once-per-game extra life tests whether the thousands digit exceeds three | `tickBonus`, `beginLife`, `checkExtraLife` |
| `$9300..$9331` | Bonus transfers when all enemies are gone; level increments; level 49 returns to ROM rather than providing a 49th level | `tick`; native completion at end of level 48 replaces that ROM exit |
| `$8D80..$8D9E` and patched call at `$7A8D` | Supplied version adds ESC pause/resume and Control-R restart | Window fenced independently; pause/restart belong to the native session UI |

There are five diggable platform cuts at pixel Y 16, 48, 80, 112 and 144, plus the ground at 176. Player top Y is 0/32/64/96/128/160. Enemy normal Y is 6/38/70/102/134/166. Logical X is **half an HGR pixel coordinate**: render X as `2×x` on a 280×192 canvas. Ladder collision rows are stored as player top+15.

The actual key table at `$7A12` yields **K right, J left, I up, M down, A dig, S fill**. The public file's header describing D/U and X/E aliases does not match its table or this supplied payload. Native arrow/controller bindings can map to the same semantic actions.

## Prepared assets and interface

```sh
python3 Tools/decode_apple_panic.py
python3 Tools/decode_apple_panic.py \
  --evidence docs/research/evidence/apple-panic-static.json \
  --reference-asm Library/Research/apple-panic/reference-disassembly.asm
```

The ignored `Library/Prepared/apple-panic/apple-panic.json` is about 11 KB. It contains four ladder layouts, four spawn layouts, sixteen type rows, counts and sixteen original sprite masks. Player frames come from the pointers at `$7A22..$7A35`, three bytes per row for sixteen rows. Enemy frames come from relocated `$1000/$1200/$1400` pages (source `$5000/$5200/$5400`), two frames per type, three bytes per row for ten rows. Seven-bit HGR columns become 21-bit pixel masks. Artifact-color phase bits are omitted; these masks establish source shape, not faithful Apple II color rendering. No extracted arrays or raster media are committed.

`ApplePanicResources.load(url:)` bounds and validates the prepared JSON. `ApplePanicSimulation(resources:seed:)` exposes immutable resources, state, ladders, sprite name, a Codable snapshot and `tick(input:)`. Input values are semantic native commands, not the original numeric animation codes. Resource/source identity, collection limits and coordinates are validated when restoring; the pseudo-random state and dispatcher half are saved so continuation is deterministic. These local resume saves extend the source game's lifecycle.

## Checks and remaining completion gates

Development checks used the son's M5 Pro MacBook Pro with 24 GB (the current development environment), targeting native ARM64 and macOS 14. The standalone core typechecked. **13 focused Swift XCTest and 5 Python tests passed, with no failures.** Focused Swift XCTest covered initialization, source call counts, ladder movement, dig clearance and ten-frame depth cycles, player falling, occupied-hole capture, fill-triggered death, stronger-enemy drop requirements, level transitions, bonus/extra-life rules, collision/life restart, deterministic snapshot continuation, rejected malformed states and loading the locally prepared original masks. Python tests covered strict identity rejection, mutation/truncation, listing patch detection, address drift, original table extraction and evidence-window bounds. These are native/static checks, not original-runtime comparisons or M1 performance evidence.

Work still required before faithful completion:

- Port exact horizontal hole-edge stopping, partial-hole push-out and stacked-hole traversal, and compare source/native collision outcomes.
- Port the six source scoring accumulators, chain kills, crushing and visual drop/respawn sequences exactly. The current isolated stronger-enemy rule is covered; multi-victim chains remain approximate.
- Recover the exact ROM random byte stream and CPU-delay timing without embedding or executing an emulator. Current deterministic native timing and randomness are explicit substitutes; native new-game counters start at zero rather than inheriting the supplied dump's mutable timer scratch values.
- Reproduce artifact colors, backgrounds/floor/ladder/hole tiles, pre-shift variants, title/status screens, font, speaker audio and all animation phases. Current bit masks preserve source silhouette only.
- Validate running original behavior and visuals, hub launch/return, saves, focus and physical Fusion Pro input. Native session integration is tracked by the parent checkpoint.
- Run the mandatory 30-minute fullscreen 2560×1600, memory, swap, thermals and input checks on the owner's M1 Air/8 GB when newly authorized. No remote or scheduled M1 work occurred.
