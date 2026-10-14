# PGA Tour 2005 out-of-bounds, hazard, wind, tee and pin rules

Static investigation, October 13, 2026, on the son's M5 Pro (Mac17,9, 24 GB).
The original game and its Windows code were **not run**. Findings come from
direct Ghidra 12.1.2 headless decompilation of the supplied DLLs plus Apple
`objdump` disassembly, cross-checked against the course data. Decompiler text
is not original source, and none of this is REA Evidence. Nothing here was
measured on the owner's M1 Air.

Inputs:

- `Engine.dll` SHA-256 `94aa30bb645ea089fed6e98df0dce38d75c309e4531386cbe33c07f65bd19728`,
  image base `0x10000000`.
- `Utils.dll` (geometry helpers, image base `0x10000000`), `CourseData.dll`
  (course file fix-ups) and `Language.dll` (English string table).
- All 11 course `TCR`/`INI` pairs (198 holes) from the courses disc.
- Ghidra project: ignored `Library/Research/ghidra-projects-rules/`. Outputs:
  ignored `Library/Research/ghidra-rules/{e1..e9,u1..u4}`.

Read this alongside [`PGA2005-REA.md`](PGA2005-REA.md) (lie flags, patch
layers), [`PGA2005-PHYSICS.md`](PGA2005-PHYSICS.md) (flight, conditions
scalars) and [`PGA2005-WEATHER-TIME.md`](PGA2005-WEATHER-TIME.md) (weather and
time presets, not repeated here).

Confidence: **high** means read from instructions and confirmed by data,
**medium** means the code path is clear but its intent or caller is inferred,
**low** means unresolved.

## 1. Where the OB lines live

The INI `[Hole n OB k]` sections are architect source data. **No unprotected
module reads them**: Engine.dll and CourseData.dll contain no `OB` key string.
The engine tests a compiled copy from the TCR course-information block (the
block at TCR header `+0xe0`, called `root` below):

| Location | Content |
| --- | --- |
| hole record `+0x0e` (s16) | polygon count, stored **negated**. The `CourseInfoHeader2` fix-up (CourseData `0x1000dc70`) turns `v <= 0` into `-v` and a positive value into 0 |
| hole record `+0x20` (u32) | root-relative offset of the polygon array |
| hole record `+0x1c` (u32) | second offset, equal to `+0x20` in every hole; unused by the code read. `+0x0c` (s16) is 0 in every hole |
| polygon record, 0x1e bytes | `+0` u32 (always `0xffffffff`), `+4` s32 **type**, `+8` s16 **point count**, `+0xa` u32 root-relative point offset, `+0xe/+0x12/+0x16/+0x1a` f32 bbox minX, minZ, maxX, maxZ |
| points | 12-byte `(x, 0, z)` float triples in the raw TCR inch frame used for tees and pins |
| root `+0x0c` / `+0x6a` | course-level polygon array (count negated, offset). Read by `CheckHazard` and `GetNumHazards`. Empty in all 11 courses |
| root `+0x0e` / `+0x6e` | second course-level array, fixed up but not read by the code examined. Empty everywhere |

All 430 TCR polygons match the INI sections exactly in order, type and point
count. Every TCR point equals `INI.x*12 - origin.x`, `INI.z*12 - origin.z`,
where `origin` is the TCR header `+0x318` float triple. The largest difference
is 0.0185 in (AUS). `CCourse::MakeGameWorldPosition` (`0x1017e052`) applies the
same transform at runtime: `(p - courseMin) * 12`, clamped at the minimum.
Confidence: high.

**Polygons are polylines.** The test walks edges `i -> i+1` for `i < n-1`
and adds no closing edge. 203 of the 430 are closed because the authored last
point repeats the first. The other 227 are open fence lines; an open line
splits play only where its ends meet another line or leave the course. The
architect string table calls them "segment %d of the out of bounds markers"
(`Language.dll` `0xe6bf`).

| Type | Count | Engine meaning (`CHole::CheckHazard`) | Architect / data reading |
| --- | --- | --- | --- |
| 1 | 215 (63 closed) | Beyond it: lie gets `0x20` **unplayable**, `0x200` (drop allowed) is cleared | Hazard margin: ocean, cliffs, water, jungle. The string `  (Unplayable)` (`0xe6e4`) labels these markers |
| 2 | 215 (140 closed) | Beyond it: lie gets `0x80` **out of bounds**, `0x200` cleared | OB stakes. Closed type-2 lines are in-bounds boundaries around the hole |
| 3 | 0 | Same as type 1, but tested only when the ball is inside the polygon bbox (inclusive) | Only meaningful in the course-level array |

The type 1 and type 2 rows are high confidence. The type 3 row is high from
code, but no data uses it.

Data check across all 198 holes (script in the test module; no original data
is copied into Git):

- Closed type-2 polygons contain every pin (1,400 of 1,400) and every aim point
  (1,281 of 1,281). 129 of them contain the whole hole line; 11 leave out one
  or more tees (689 of 700 tees inside).
- Closed type-1 polygons exclude the hole line in 57 of 63 cases: they surround
  the hazard itself. The other 6 enclose part of the line instead, so outside
  the loop is unplayable. AUS 1 contains every aim point, JPN 17 and SHR 2
  contain the green and all 10 pins, SHR 3 has two loops around tees, and
  PBL 18's rock tee sits inside a 15-point loop. The parity test treats both
  layouts the same way.
- Under the engine test, with each hole's amateur tee, aim points and pin 0 as
  the hole line, all 1,980 pins and all aim points are in play. 5 tees are
  beyond a type-1 line and 13 beyond a type-2 line. 15 of those 18 are tee
  index 4, the unnamed fifth tee. A tee that is itself selected is always in
  play, because the test measures from the nearest hole-line point.
- PBL hole 1's single polygon (type 2, 44 points, closed) surrounds the tees,
  fairway line and green. PBL 8 and 18 have a type-1 line along the cliff or
  ocean edge just inland of the INI coastline, and a type-2 line on the
  other side. That matches the real course, which has OB right of 18.

## 2. The OB / unplayable test

`CHole::CheckHazard(Position&)` at `0x10181371` (high):

1. **Reference point.** Take the hole line `CHole+0x4c` built by
   `ReadHoleInfo` (`0x1018249b`): `[selected tee, aim points..., selected
   pin]`. Choose the point nearest the ball in XZ (`APosition::DistanceFrom` is
   2-D, `Utils 0x100109f0`). On a tie the earliest point wins.
2. **Terrain presence.** If the position is invalid, its height equals 0.0, or
   `CCourse::IsPointOnWorld` (`0x1017b014`, no terrain hit) fails, set `0x80`.
   This does not return early.
3. **Per polygon.** Intersect the segment *reference → ball* with each edge
   using `Utils.dll IntersectLine(double...)` (`0x1000cdc0`, epsilon 0.001,
   vertical-slope sentinel 1e300). Return codes:
   - 1: proper crossing; counted.
   - 2: crossing at the reference point; ignored.
   - 3: crossing at the ball, meaning the ball lies on the line. The count is
     reset to 0 and the polygon loop ends.
   - 4: crossing at the edge's first vertex; counted.
   - 5: crossing at the edge's second vertex; ignored, so a shared vertex
     counts once.
   - 0: no crossing or parallel lines.

   A polygon is *flagged* when its crossing count is odd.
4. **Course-level polygons** use the integer `IntersectLine(long...)`
   (`0x1000d1c0`) on truncated coordinates. Type 3 also needs the ball inside
   the bbox. No shipped course has any.
5. **Decision.** If the *number of flagged type 1/3 polygons* is odd, set
   `0x20` and clear `0x200`. Otherwise, if the number of flagged type 2
   polygons is odd, set `0x80` and clear `0x200`. Unplayable therefore wins
   over OB. Crossing two type-1 lines cancels out, a quirk to keep.

`Tools/decode_pga2005_holes.py` exports `intersect_line` and `check_hazard` as
a reference port. `Tests/test_pga2005_rules.py` covers the codes, precedence,
parity, open ends and vertex handling.

**When it runs** (high):

- **During flight.** `CBallFlight::BallLoop` (`0x101f795f`) stops the ball and
  sets `CBallFlight+0x60` when it leaves the terrain mesh
  (`CTerrainMesh::IsValidCameraLocation` false).
  `BallLoopTerrainHeight` (`0x101f7ccb`) does the same when no terrain is
  under it. Polygons are *not* tested in flight, so a ball may fly over an OB
  line and come back.
- **At rest.** `CGolfBall::BallAtRest` (`0x10135d98`) sets `0x80` when that
  flag is set (except during caddie pre-calculation, global `0x1043ba50`), or
  when the rest point is off the world. It then moves the ball back to the
  shot start (`CBallFlight+0x28..0x30`). Otherwise it adds the surface flags.
  A water rest (`0x40`) also gets `0x20`, and a tournament structure
  (`0x40000`) gets `0x400`. It finishes with `CheckHazard`.
- **Turn end.** `CPlayer::EndTurn` (`0x101405c7`) calls it again on the ball
  position. It marks `0x20` when the stance is unplayable
  (`IsPlayableStance` `0x10143e29`) and records "last swing OB/unplayable"
  (`CPlayer+0x791e/+0x791f`). It also counts the stroke.
- **Stance and drop checks.** `CPlayer::IsPlayableStance` runs `CheckHazard`
  at the candidate and rejects `0x20`/`0x80`. `Caddy::MustDrop` uses it too.

## 3. Penalties and relief

`PlayerCommand::FinishTurn` (`0x1004ee35`) dispatches on the rest lie. Game
type `0x0e` (a special mode) skips this. Order (high unless noted):

1. **Out of bounds (`0x80`)**, unless the ball is within 5 in of the pin, a
   quirk. Add one penalty stroke (`CPlayer::AddStroke`, on top of the stroke
   already counted), then call `CPlayer::FindRelief` and pick the ball up.
   `CPlayer::FindReliefPosition` (`0x101411cb`) chooses the spot:
   - If the shot was played from the tee (`CPlayer+0x1330` has `0x8000`),
     re-tee at `CHole::TeePosition(selected tee)`, flagged teed (`0x8000`) with
     `0x120` cleared.
   - Otherwise replay from the spot of the last shot (`CPlayer::GetPosition`,
     `+0x1330`).

   This is **stroke and distance**: the next shot is "3 off the tee". No drop
   UI is used.
2. **Free drop (`0x400`)**: roads and cart paths (surface `0x2420`), tournament
   structures, and line-of-sight obstruction (below). Find relief if no relief
   zone exists, then require a drop (player flag 8). `PlayerCommand::DropBall`
   (`0x100515e5`) adds **no** stroke when the lie has `0x400`.
3. **Unplayable / hazard (`0x20`)**. This covers water, ocean (`0x960`),
   cliffs (`0x120`), buildings and anything beyond a type-1 line. Find relief,
   require a drop, and `DropBall` adds **one penalty stroke**. There is no
   separate lateral-hazard option: water, lateral margins and unplayable lies
   all use the procedure below.

**Relief point** for `0x20` and `0x400`: `CGolfBall::FindReliefPosition`
(`0x101372ea`, high). Walk the recorded ball path backwards from 6 samples
before the end, 5 samples per step. Snap each sample to the terrain. Accept
the first sample that meets all of these:

- the ball was not more than 1 in below the ground there;
- the lie allows a drop (`0x200` and not green or fringe);
- it is more than 108 in (9 ft) from where the ball came to rest;
- it is not a bunker;
- it is a playable stance with a flat stance of at least 0.93;
- `IsStanceOnTerrain(pos, 0x200, 30 in)` passes.

Stop with failure if a sample is on the green. On failure, use the spot of the
last shot instead. That is stroke and distance with a one-stroke penalty and
a drop. In effect, the relief point is where the ball last crossed onto
droppable ground.

**Fallback**: if any relief spot is invalid, unplayable, OB, water or hazard,
`CHole::MovePositionToFairway` (`0x10180b20`) projects it onto the hole line at
the same distance from the pin. It steps back along the line until it reaches
fairway, then rotates about the pin in 0.5° steps toward the original bearing
while the spot stays on fairway, fringe or tee (medium).

**Drop zone** (`FUN_1018a390` constructor, `FUN_1018a560` test; high): a
rectangle around the relief point P, oriented by
`a = atan2(pin.x - P.x, pin.z - P.z)`. The local +z axis points at the pin.
The rectangle spans x ±100 in (±8.3 ft) and z from -3600 in (300 ft back) to
+3 in (toward the pin). In other words, drop on the line from the pin back
through P, no nearer the hole, within about 8 ft each side.

`PlayerCommand::IsInDropZone` (`0x10052050`) accepts a spot when all of these
hold:

- it is inside the rectangle (the segment P → spot crosses no edge);
- the lie has `0x200` and is not green or fringe;
- it is a playable stance with a flat stance of at least 0.6;
- `IsStanceOnTerrain(spot, 0x2214, 36 in)` passes;
- the stance point 60 in to the side is not water unless the lie is a free
  drop.

The player walks the golfer to a spot ("Move the golfer with the mouse to
select a drop area and click to drop", `0x6022`). `AllowsBackDrop(d)` tests the
spot d inches straight back from the pin. `Redrop` refunds the drop stroke and
drops again.

**Obstruction relief** (medium-low): `CPlayer::EndTurn` probes from the stance
toward the pin, and from 36 in behind the ball, for terrain carrying the
`0x4000` probe flag. A hit nearer than the pin creates a `FreeReliefZone`
(`FUN_1018a69d`). This is a box of ±100 in by -100..+1 in around the relief
point, widened in 100-in steps until the line to the pin is clear, plus
`0x400`. The message is "%s receives free relief for obstruction." (`0x5ed5`).

**Lie flags used by the rules**: `0x200` drop allowed (cleared beyond any
line); `0x400` free drop (no penalty); `0x20` unplayable; `0x80` OB;
`0x40` water (becomes `0x20` at rest); `0x100` hazard; `0x800` ball
disappears.

## 4. Pivots, aim points and the hole line

INI `pivotN` keys are the architect's **shot points** ("Place the first shot
point for hole number %d", `0xe6bc`). The engine reads the TCR copy (record
`+0x08` count, `+0x14` offset). All 1,801 TCR aim points equal the INI pivots
under the tee/pin transform (largest difference 0.0152 in). The INI repeats
`pivotN` keys in a second, ignored group. Windows `GetPrivateProfileString`
returns the first occurrence, and the TCR matches the first group.

Uses (high unless noted):

- Hole line `[tee, pivots..., pin]` (`ReadHoleInfo`, `SetPin` `0x101821bf`).
- OB/unplayable reference point (section 2).
- `CHole::TotalYards` (`0x1017fc76`): INI `yardage=` if it lists exactly 5
  values (`ReadIni` requires `SplitString` to report 4 separators; medium);
  otherwise the polyline length / 36. All 198 shipped lists have 5 values.
- `OnThisHole` (`0x1017ffbc`): the ball is within 1,800 in (150 ft) of the line.
- `NextPosition`/`PreviousPosition`/`BackPosition`: distance walking along the
  line, used by AI shot finding and `MovePositionToFairway`.
- Patch classes around tees, pins and aim points in `CHole::Load` (REA doc).
- Camera use was not traced in this pass.

## 5. Coastline

`[Hole n Coastline]` `PointN = x, y, z` (feet, integer x/z, y 0) is read at
runtime by `CRTerrain::CreateVertexBuffers_Terrain` (`0x101c60ab`, string
`Hole %d Coastline` at `0x10385290`, keys `point%d`). It uses the physical hole
number and `MakeGameWorldPosition`, and feeds consecutive pairs to
`CRTerrain::AddCoastSegment` (`0x101c7f8f`). That builds the surf/wave strip,
sampling terrain heights at both ends. Error string: "Coastline too long ...
WAVE1_MAX_WAVES_PER_HOLE". It is **rendering only**: no rules, OB or audio
code reads it (high for the reader, medium for "only"). 63 holes have one
(PBL 18, TUR 18, STA 16, EDW 10, AUS 1).

## 6. Course `[Conditions]`

All 11 INIs are identical: `Skydome=1, GreenCond=3, RoughLength=2,
WindSpeed=2`. CourseData `CourseInfoC::GetDefault*` (`0x1000ae50`, `0x1000aec0`,
`0x1000af30`, `0x1000afa0`) read them with `GetPrivateProfileIntA`, with
defaults 1, 3, 2, 1. No caller exists in the unprotected modules, so the copy
into the game settings happens in the protected `TW2005.exe`.

The setting bytes match by enum name:

| INI key | Setting byte | Values | Effect |
| --- | --- | --- | --- |
| `RoughLength` | `CGameSettings+0x0e` `ROUGHLENGTH` | 1 Light, 2 Average, 3 Heavy | rough scale 1.3 / 1.0 / 0.7 (physics doc) |
| `WindSpeed` | `+0x0f` `WINDSPEED` | 1 Still, 2 Calm, 3 Breezy, 4 Gusty, 5 Strong (`Language` `0x7437..0x743b`) | `Wind1` type `WindSpeed-1` (section 7) |
| `GreenCond` | `+0x10` `GREENCOND` | 1 Very Slow … 5 Very Fast | wet scale 0.6…1.4 |
| `Skydome` | `+0x11` `SKYTYPE` (`CGameSettings::SkyType` `0x1001abf0`) | 1..7 | sky choice; see the weather/time doc. The value mapping is unresolved |

The defaults therefore mean normal greens, average rough and **calm** wind,
**medium** confidence for the INI-to-byte link. Without them, the
`CGameSettings` constructor (`0x1022bef0`) sets rough 2, wind 3 (Breezy),
greens 3, sky 7, tee 2 and pin difficulty 0.
`CGameSettings::RandomizeTheDefaults` (`0x1022d774`, exe-called) re-randomises
conditions 20 % of the time (or always under a kernel flag): rough 1–3,
greens 1–5, wind 1–4 (never Strong), sky 1–7, all uniform.

## 7. Wind

`Wind1` (constructor `0x100dffdb`) is created once per course load by
`CCourse::SetupWind` (vtable slot `+0x5c`, called from `CCourse::PreloadData`).
`CCourse::SetupWindBoundaries` (`0x1017c1d4`) calls `SetType(WindSpeed-1)` for
WindSpeed 1..5. The parameter table at `0x10439028` (6 rows × 0x44 bytes) is
**filled with constants by the constructor**, so it is recoverable, not
runtime-only. Speeds are stored in in/s: mph × 5280 × 12 / 3600 (`0x100e21ac`).
Row 5 is a copy of row 4, used by the composite-course wind slider
`SetSliderValue` (`0x100e05ca`), which interpolates rows linearly.

| WindSpeed | Normal speed (mph) | Gust speed (mph) | P(gust) per change | Normal / gust direction swing about the base | Turn rate normal / gust (°/s) | Hold after reaching target |
| --- | --- | --- | --- | --- | --- | --- |
| 1 Still | 0.86–2.3 | 0–3.2 | 6.5 % | ±7.2° / ±14.4° | 3.6 / 10.8 | 0–0.6 s |
| 2 Calm | 2.6–6.8 | 2.0–8.0 | 41 % | ±7.2° / ±7.2° | 3.6 / 3.6 | 0–0.6 s |
| 3 Breezy | 8.2–12.8 | 6.0–15.0 | 28 % | ±14.4° / ±36° | 14.4 / 43.2 | 0–0.6 s |
| 4 Gusty | 16.7–20.0 | 12.3–23.0 | 51 % | ±14.4° / ±28.8° | 7.2 / 21.6 | none |
| 5 Strong | 20.0–28.0 | 18.0–34.0 | 27.5 % | ±14.4° / ±28.8° | 7.2 / 21.6 | 0–0.6 s |

Stored fields per row:

- `[0]` gust min, `[1]` normal min, `[2]` normal max, `[3]` gust max.
- `[9]`, `[10]` turn rate × 0.32; `[11]`, `[12]` swing × 0.64.
- `[13]`, `[14]` gust threshold bounds; P(gust) is their mean.
- `[15]`, `[16]` hold range.
- Fields `[7]`, `[8]` are not read by `NextFrame`.

The speed and table values are high confidence; the evolution below is high
for the arithmetic.

Evolution (`Wind1::NextFrame` `0x100e08ec`, frame dt in seconds, updates
skipped when dt > 0.15 s):

- **Start.** Base direction θ₀ = uniform [0, 2π) at construction; speed 0.
- **Choosing a target.** Threshold u = U(t13, t14); a second draw r < u
  means a gust. A normal change picks speed U(normal min, max) and direction
  θ₀ + U(−swing, +swing). A gust uses the gust columns. The direction always
  wanders around the **fixed base θ₀**, not the current heading. A small
  pitch angle around 0 also wanders, within [−0.16, +0.08] × swing.
- **Moving.** The heading moves at rate × U(0.68, 1.32). Speed changes
  linearly so it arrives with the heading. Then the wind holds for U(hold)
  and picks a new target.
- **Vector.** `RotY(yaw)·RotX(pitch)·(0,0,1)` × speed. It is the air's
  velocity, so +Z is a tailwind for aim 0 (physics doc).

The ball uses a snapshot. `CCourse::ForecastWind` (`0x1017c23f`, via the
exe-called `CGameCommand::UpdateWind`) stores the truncated integer mph
(`_ftol`) and the normalised XZ direction. Flight uses that × 0.293333 in per
60 Hz tick (physics doc). `CCourse::SetWind` / `GetWindXZ` (network play) blend
from the previous wind to the new one over `+0xba4` ms.
`CGameCommand::AlterWind` changes the WindSpeed byte and re-types the wind.

**Unresolved (low).** `NextFrame` returns at once when byte `Wind1+0xee` is
set, and it sets that byte after its first update. Only the constructor clears
it in Engine.dll. As read, the wind would stop evolving after one update, from
an initial speed of 0. The shipped game shows non-zero wind, so something
outside Engine.dll (likely inline code in `TW2005.exe`) probably clears the
byte between shots or frames. Whether the wind drifts continuously or only
between shots is not settled statically. The spec below re-rolls a target
between shots, which matches both readings at shot time.

## 8. Tee and pin selection

**Tees** (high): the hole line and the default tee come from
`CGameSettings+0x15a` (`Tee`), default **2**. In remote games each player can
have their own tee (`CPlayer+0x10`). `CHole::TeeDescription` (`0x1017febc`)
names the indices:

| Index | Name |
| --- | --- |
| 0 | forward |
| 1 | ladies |
| 2 | amateur (default) |
| 3 | tournament (matches the championship card, REA doc) |
| 4 | "-" (unnamed; often beyond the OB lines) |

`TeePosition` (`0x1017fd5c`) uses tee−1 when the index is not below the tee
count.

**Pins** (high for arithmetic, medium for naming): the architect asks for
pins "in order of easiest to most difficult. The game depends upon this"
(`0xe6be`). The selection works like this:

- `CGameSettings` holds one byte per hole at `+0x14..+0x25`, plus one shared
  byte for practice holes 19–21.
- `RandomizePinPlacements` (`0x1022d848`) fills each byte with
  `(Generate() & 0x7fffffff) % 255` from Utils `Random`. The seed is the CRC
  of the course GUID bytes, conditions, weather, time and pin difficulty,
  combined with the tick count (0 for internet games, so all clients agree).
- `CHole::PinPlacement` (`0x10182234`) on a standard course picks
  `pin = (byte % 5) * 2 + (PinType == 0 ? 1 : 0)`, clamped to the pin count − 1.
  `PinType` (`CGameSettings+0x12f`, default 0) picks the odd member of each
  pair when 0 and the even member when 1. Because the list runs easiest to
  hardest, PinType 0 is the slightly harder member of each pair.
- Composite courses can force an index (PinType 2) or use
  `(5 − level) * 2` pairs.
- `GetDifficultyFromType` (`0x1022da63`) maps event pin choices to PinType.
- The byte is fixed when the hole loads (`CCourse::PinPlacement` calls every
  hole). The constructor zeroes the bytes after randomising, so in a fresh
  settings object every hole uses pair 0 until the front end re-randomises.
  `CGameCommand::FinishHole` re-randomises only for practice holes.

How often the exe re-randomises during a normal or multi-round event is not
visible statically (medium-low).

## 9. Rules spec for the native game

Coordinates are the raw TCR inch frame of `holes.json`; all tests are in XZ.

1. **Hole line** = `[tees[selectedTee], aim_points..., pins[selectedPin]]`.
   Default `selectedTee = 2`. Never offer tee 4 as a normal set, and treat
   index ≥ tee count as count − 1.
2. **Pin** for hole n = `(pinByte[n] % 5) * 2 + (pinType == 0 ? 1 : 0)`,
   clamped. Draw `pinByte[n]` uniformly 0..254 per hole when a round starts,
   with a deterministic seed for network or replay. Snap the pin height to the
   green.
3. **OB/unplayable test at rest** (`check_hazard`):
   - If there is no terrain under the ball, or it is off the course, it is OB.
   - Otherwise, from the nearest hole-line point to the ball, count crossings
     of each line's `n − 1` edges.
   - A crossing exactly at the ball does not count; a shared vertex counts
     once.
   - An odd number of type-1 lines with odd crossings means unplayable.
   - Otherwise an odd number of type-2 lines with odd crossings means OB.
4. **In flight**: if the ball leaves the terrain mesh or has no terrain
   beneath it, stop it at once and rule it OB. Do not test lines in flight.
5. **OB** (unless within 5 in of the pin): +1 penalty stroke on top of the
   stroke played. If the shot was from the tee, re-tee at the selected tee.
   Otherwise replay from where the shot was played. No drop.
6. **Water, ocean, cliffs, buildings, beyond a type-1 line (`0x20`)**: +1
   penalty stroke when the ball is dropped.
   - Relief point: walk the recorded flight and roll path backwards to the
     first point that is droppable (`0x200`, not green, fringe or bunker),
     more than 9 ft from where the ball stopped, has a playable stance and is
     flat enough (0.93).
   - If the walk reaches the green or finds nothing, use the spot of the last
     shot.
   - Drop zone: 16.7 ft wide (±100 in), from 3 in toward the pin to 300 ft
     back, on the pin–relief-point line.
   - The drop spot must be droppable, not green or fringe, flat (0.6), and
     have its stance spot out of water.
7. **Cart paths, roads, tournament structures, line-of-sight obstruction
   (`0x400`)**: same relief procedure, no penalty.
8. **Invalid relief**: fall back to the nearest fairway on the hole line at
   the same distance from the pin.
9. **Conditions** default to the course INI. Every shipped course uses
   Normal greens, Average rough and Calm wind; the sky value is 1.
10. **Wind**: per round, draw a base direction U[0, 360°). Per WindSpeed, use
    the table in section 7 for speed ranges, gust probability and direction
    swing about the base. Before each shot, show and use the integer mph
    (truncated) and the XZ unit vector of the current wind.
11. **Yardage**: use the INI `yardage` list when it has 5 entries; otherwise
    use the tee → pivots → pin polyline length / 36.
12. **Coastline**: rendering only (surf strip along `coastline_raw`).

## 10. `holes.json` additions

`Tools/decode_pga2005_holes.py` adds the following. Existing fields are
unchanged; regenerated for all 11 courses in the ignored `Library/Imported`.

Top level:

- `conditions`: `{skydome, green_cond, rough_length, wind_speed}`. Keys absent
  from the INI are omitted.
- `conditions_provenance`.
- `ob_polygon_semantics`: a short form of section 2.
- `course_ob_polygons`: empty in every shipped course.
- `ini_ob_comparison`: polygons matched, largest errors, mismatches and pivot
  checks.

Per hole:

- `ob_polygons`: TCR order, each with
  - `type`, `kind` (`out_of_bounds` or `unplayable`), `closed`;
  - `points_raw` `[[x, z], …]` (TCR, authoritative) and `points_feet`
    `[[x, z], …]` (INI);
  - `bbox_raw`, `ini_section`, `source_offset`, `source_array`, `header_word`.
- `pivots_raw` `[[x, y, z], …]` and `pivots_feet`: first-occurrence INI keys,
  equal to `aim_points`.
- `pivot_ini_duplicate_keys`.
- `coastline_raw` `[[x, z], …]`, clamped like `MakeGameWorldPosition`, and
  `coastline_feet`.

Checks: `python3 -m unittest discover -s Tests -p 'test_*.py'` passed on the
M5 Pro (208 tests, 1 skipped). `Tests/test_pga2005_rules.py` runs synthetic
TCR/INI fixtures always, and the original-course checks only when the media is
present. Those checks cover all 11 courses: INI match, pivots against aim
points, and every pin and aim point in play.

## 11. Open questions

- What clears `Wind1+0xee`, and so whether the wind drifts during a shot
  (section 7).
- How the protected `TW2005.exe` copies the `[Conditions]` defaults, the tee
  choice and the pin bytes into `CGameSettings`, and when it re-randomises
  pins in multi-round events.
- The `SKYTYPE` 1..7 meanings and their link to the weather/time presets.
- The exact flag tested by the obstruction probe (`FindTerrain` with
  `0x4000`), and the `FreeReliefZone` growth limits.
- Validating relief spots and drop zones against footage of the original game.
