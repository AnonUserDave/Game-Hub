# PGA Tour 2005 presentation: cameras, swing meter and HUD

Updated October 13, 2026. This is a static reverse-engineering record. The
original game was **not executed**; there are no runtime observations in this
document. Every claim is static evidence from the original bytes, Ghidra
decompilation or disassembly, or a cross-check between decoded data and the
designers' own record names. Each finding has a confidence label:

- **High**: read directly from code and confirmed by a second source (assembly,
  record names, other files, or a byte-level check).
- **Medium**: read from decompiled code or inferred from consistent data, with
  one source.
- **Low**: plausible interpretation, not established.

Tooling: `Tools/decode_pga2005_cameras.py` (standard library) writes
`Library/Imported/pga2005/cameras.json` and `swing.json`; tests are in
`Tests/test_pga2005_cameras.py`. Direct Ghidra 12.1.2 headless output and the
database are in the ignored `Library/Research/ghidra-presentation/` and
`Library/Research/ghidra-projects-presentation/pga2005-presentation`. These
are direct Ghidra observations, **not REA Evidence**.

## Inputs

| File | SHA-256 |
| --- | --- |
| Engine.dll | `94aa30bb645ea089fed6e98df0dce38d75c309e4531386cbe33c07f65bd19728` |
| d_camera.stn | `42ddf93ff792da4a61a0f3f05a5aff9c6c078afde1d01d655bec51f11b15ea6b` |
| s_camera.stn | `c3e3d5a502ffb26a1d0f8ea054f5030aef0389fb120862c1133015730eae2065` |
| f_camera.stn | `fdb168a49cfbf4f175f79dd430a7ca44a787ec18efa21c3029267a42d0d00a25` |
| b_camera.stn | `53afc27a7ac2ccbcca09abec70d0a28fcee89435a230f139538122f92a6f3f69` |
| Replay.stn | `f0b972af6ba95d934933d17a2f650cabe43c78ea8bdc52a1d6985d28c9695cf8` |
| anim.stn | `0b844e7a3081bec36a8f70bca3965e372f8aa9f534a68468b2d820974fd8d307` |
| swingon.dds | `cc2939bff406f13fdcff53d9045bd4a41307b00f1d271118f04900afa6a0fc9b` |
| swingoff.dds | `a4e67e2be7779f7f9c200e7b6793fda43c6e2390e1e53743e03e0de8a84f8f51` |

The `engine/Executable` and `install/Executable` copies of the camera scripts
are byte-identical.

## 1. What each script file is for (high)

The installer header `cabs/DATA1.HDR` writes one registry key per script under
`Software\EA SPORTS\Tiger Woods PGA TOUR 2005\Script\…` with a `Filename`
value. `ScriptCommand::LoadFromFile` (`0x1005d590`) reads `InstallDir` and
`FileName` from such a key and calls `Script::LoadSituationFile`.

| File | Registry key | Role (from contents) |
| --- | --- | --- |
| `d_camera.stn` | `Script\AutoCamera` | Default "TV" director: 153 situations, cuts, zooms, letterbox, reactions |
| `s_camera.stn` | `Script\SnapCamera` | Snap camera: instant cuts to a few framings, one in-flight landing cut |
| `f_camera.stn` | `Script\FixedCamera` | Fixed camera: one high-behind framing per turn; no in-flight rules |
| `b_camera.stn` | `Script\BallCamera` | Ball camera: chases the ball from impact |
| `Replay.stn` | `Script\Replay` | Which shots trigger an automatic replay, and with what chance |
| `anim.stn` | `Script\Animation` | Terrain effects: sand blast, splash, grass clippings, divot, tee |

So b/d/f/s mean **B**all, **D**efault/auto, **F**ixed and **S**nap. The same
format also carries commentary, gallery, music and golfer sound scripts
(`analyst.stn`, `announcer.stn`, `gallery.stn`, `music.stn`, `male.stn`, …);
the generic parser reads them but they are out of scope here.

`CRenderSettings::CameraScriptType` (`0x1022b5d4`) returns the stored type
unless dynamic cameras are off, in which case only types 2 and 3 survive and
anything else becomes type 2. The mapping of enum values 0–3 to the four
files lives in `TW2005.exe`, whose code is encrypted (see §6); it is an open
question. Separately, when `Animator::IsDynamic` is false,
`Camera::SetAttachmentType` and `CreateTransitionPath` force every duration to
zero, so all moves cut. Whether that flag follows the "dynamic cameras" option
or the display card check is not established (medium).

## 2. The `.stn` format (high)

Loader chain: `Script::LoadSituationFile` `0x10207822` reads a 0x1c-byte header,
then `LoadResponses` `0x1020b3e4`, `LoadActions` `0x102080bd`,
`LoadSituations` `0x10207d65`. All six files are version `0x10005`. After the
response table come NUL-terminated descriptions in situation, action,
response order. Record bytes past the fields below are editor garbage
(`0xcd` fill and old strings).

**Header** (little-endian u32): `version`, then count/offset pairs for
situations, actions and responses.

**Situation, 91 bytes** (`0x5b`; 86 bytes for other versions):

| Offset | Type | Meaning |
| --- | --- | --- |
| 0 | u8 | Situation type = event category: 11 camera, 2 game/replay, 1 and 3 effects |
| 1 | u8 | Event id; 0 matches any event |
| 2 | u32 | Condition mask: bit *n* tests event value *n*; conditions are listed in bit order |
| 6 | u16 × 10 | Operator per condition |
| 26 | u32 × 10 | Operand per condition |
| 66 | s16 × 10 | Action indices; `0xfff0` ends the list; duplicates weight a random choice |
| 86 | u32 | Flags: bit 0 pick one random action, bit 1 "key moment" (rebroadcast to all scripts) |
| 90 | u8 | Priority: **lower wins** (1 = top, 254 = catch-all) |

**Action, 87 bytes** (`0x57`):

| Offset | Type | Meaning |
| --- | --- | --- |
| 0 | u8 | Action type: 10 camera, 11 replay, 7 animation, 12 link, others sound |
| 1 | u8 | Probability %: runs if `random(100)+1 <= p` (`FUN_102160a5`) |
| 2 | u32 | Flags; bit 0 becomes `0x4000` "run every response in order" (`0x10215e27`) |
| 6 | s16 × 30 | Response indices |

**Response, 63 bytes** (`0x3f`). Byte 0 is the response type (13 camera,
9 animation, sound types otherwise). `Script::BuildResponseObject`
(`0x10209157`) builds a `CameraResponse` (`0x102194e0`, RTTI
`.?AVCameraResponse@@`) for type 13, which copies bytes 5–43:

| Offset | Type | Meaning |
| --- | --- | --- |
| 5 | u8 | Kind: 0 generic transition; 1–10 `DefaultView`; 11 `MatrixCam`; 12 `GreenCam`; 13 `HelicopterCam`; 14 `ShotTarget`; 15 green tower; 16 fairway tower |
| 6 | i32 | Command (table below) |
| 10 | f32 × 3 | Offset x, y, z in **inches** |
| 22 | i32 | Path type: −1 n/a, 0 straight, 1 arc, 2/3 arc with yaw |
| 26 | i32 | Start mode: 0 immediate, 1 new group (wait), 2 with previous |
| 30 | u32 | Flags: 1 reset view, 2 clear queue, 4 kill current, 8 accept while busy. Attach always gets 1 |
| 34 | i32 | Object type (table below) |
| 38 | u8 | Duration in tenths of a second; 0 = cut |
| 39 | i32 | Amount: zoom/letterbox/slow-motion %, angle in degrees, move distance/12 |
| 43 | u8 | Extra: bit 0 relative angle, bit 1 mirror for left-handed golfers |

Cross-check (high): 142 of 146 offsets written in response names, such as
`Attach Ball (0,1,-15)`, equal the decoded values divided by 12; all 70
"N seconds" names equal the duration byte/10; all 39 "Zoom N%"/"Letter Box
N" names equal the amount. The four offset mismatches are stale names
(`Attach Golfer (0,10,-18)` stores −24 ft). The camera timer multiplies
`byte / 100` by 10000 (`0x102d6c0c`) to get milliseconds, so the byte is
tenths of a second.

Commands (`Camera::StartTransition` `0x1018e16d`):

| Id | Command | Id | Command |
| --- | --- | --- | --- |
| 0 | Attach (camera position follows object) | 12 | Move absolute |
| 1 | Target (look-at follows object) | 13 | Zoom so ball and cup fit |
| 2 | Pitch angle | 14 | Attachment offset |
| 3 | Pan angle | 15 | Target offset |
| 4/5 | Rotate X / Y | 16 | Approach attachment |
| 6 | Zoom (amount/100) | 17–22 | Move up/down/left/right/forward/back |
| 7 | Tilt | 23 | Target absolute |
| 8 | Slow motion | 9 | Letterbox (amount/100) |
| 10 | Hole fly-over | 11 | Pause (hold the queue) |

Objects (`Camera::SetPositionalObject` `0x10193dbd`; class names from RTTI,
high): 0 `NoPosition` (freezes at the previous object's position), 1 tee,
2 pin (`HolePosition`), 3 landing, 4 other player's landing, 5 ball,
6 other ball, 7 golfer, 8 other golfer, 9 golfer head, 10 other golfer head,
11 ball+pin, 12 golfer+pin, 13 golfer+ball, 14–16 the "other player" combos,
17 shot target, 18 ball apex.

## 3. How the director runs

### Events (high for ids, medium for exact timing)

`ScriptCommand::View*` builds a `CameraEvent` (ctor `0x1021387a`, category 11,
available-value mask `0x77ffffff`) and calls `Script::EventOccurrence`:

| Id | Name | Source |
| --- | --- | --- |
| 28 | Start hole | `ViewTee` `0x10064b84` |
| 19 | Prep / start of turn (golfer at address) | `ViewSwing` `0x1006500c` |
| 21 | Pre-shot (unused by the camera files) | `ViewPreshot` `0x10064940` |
| 3 | Ball impact | `ViewBall` `0x1006533f` |
| 1 | Ball in flight, once per 5 % progress step | `ViewLanding` `0x10065678` |
| 22 | Golfer reaction after the shot | `ViewPostshot` `0x10065a16` |
| 29 | Hole end | `ViewEndOfHole` `0x10065f88` |
| 30 | Other player (unused by the camera files) | `ViewOtherPlayer` `0x10065d4f` |

In-flight events (`ScriptCommand::SetFlightIndex` `0x100666f2`): the flight
index is `min(20, trunc(progress × 20))`, starts at 3 and only increases; one
event fires per new index. Nothing fires until the ball flight has 60
samples (30 when the ball is within 72 in = 6 ft of the hole). The Auto
camera decides at index 5 (25 %), the Ball camera at 7, the Snap camera at 8.
The meaning of "progress" (time or distance fraction) is medium confidence.

### Event values (condition bits)

Filled by `FUN_102138df` (CameraEvent fill). Distances are inches.

| Bit | Value | Confidence |
| --- | --- | --- |
| 0 | Club class: 1 driver, 2 wood, 4 iron/wedge, 0x10 putter, 0x40/0x80/0x100 long/mid/short irons | High |
| 1 | Shot flags: 1 tee shot, 2 putt, 0x2000 flop, 0x400 full shot, 0x800/0x1000/4/0x4000/0x8000 other styles, launch bands | Medium |
| 2 | Terrain flags under the golfer (1 fairway, 2 rough, 4 green, 8 bunker, 0x10 fringe, 0x40 water, 0x80 OB, 0x100 hazard, 0x1000 tee box, 0x4000 in hole, 0x8000 on tee, 0x80000000 weed rough) | High |
| 3, 15 | Distance to pin: predicted landing → pin in flight, ball → hole otherwise | High |
| 4, 22 | Shot distance: golfer → ball or predicted rest/landing | Medium |
| 7, 8, 9 | Par, strokes this hole, strokes − par | High |
| 10 | Miss direction vs target: 1 left, 2 right, 4 short, 8 long | High |
| 11, 17 | Lateral and depth miss distance | Medium |
| 12 | Flight index (above) | Medium |
| 14 | Golfer model: 1 male, 2 female | Medium |
| 16 | Wind direction vs aim (±0.65 thresholds) | Medium |
| 18 | `CPlayer+0x15ff`; 0 on the first putt | Low |
| 21 | Terrain flags at the ball or predicted landing | High |
| 29, 30 | Game flags: 0x20 AI player, 0x40 practice, 0x10 match play, round length bits | Medium |
| 5, 6, 13, 19, 20, 23–28 | Flight value, wind speed, standing, lie index, elevation, course id; unused by cameras | Low–medium |

### Operators (high; `FUN_10215b87`, checked in assembly)

`0` always; `1` `==`; `2` `!=`; `3` `>`; `4` `<` (both unsigned);
`5` any bit of operand set; `6` value or operand non-zero; `7`
`(~value & operand) != 0`, i.e. "lacks at least one bit"; `8` no bit set;
any other value (the files use `0xffff`) never matches. Operator 7 with a
multi-bit operand is almost always true for single-valued lie flags, so
"landing < 10 feet" rules do **not** exclude bunker landings. Implement it
literally.

### Choosing a situation (high)

1. Candidates: same category, event id equal or 0, at least one action,
   every condition true (`Script::FindSituationsMatching` `0x1020bfe3`).
2. Lowest priority byte wins; ties go to the situation with **more
   conditions**; remaining ties are chosen uniformly at random
   (`DoSituationsMatching` `0x1020c1df`).
3. Flag bit 0: choose one action at random from the list (duplicates
   weight it). Otherwise run all listed actions.
4. The action runs only if its probability roll passes. A camera action
   invokes every response in order.

### From response to camera move (high, unless noted)

`CameraResponse::Invoke` (`0x10219553`) builds one `CameraTransition`. For
attach/target with a real object it appends a second transition (command 14
or 15) that applies the offset with the same duration. `Camera::AddTransitions`
(`0x1018dc3c`):

- flag 4 kills running transitions; flag 2 clears the queue;
- without flags 4 or 8, a response that arrives while the camera is
  transitioning is **dropped** ("new" responses);
- start mode 1 starts a new group that waits until the current group ends,
  2 starts together with the previous transition, 0 starts immediately.

`StartTransition` applies the command. Flag 1 first resets approach,
rotations, offsets, zoom 1, tilt 0, letterbox 0 and slow motion 1. Angles and
zoom/letterbox values ease with `0.5 + 0.5·sin(π·t − π/2)` (`FUN_1018d00f`).
Positions move along a cubic Bézier with control points at ⅓ and ⅔
(`CreateTransitionPath` `0x10193a4e`); arc paths pitch the controls up 30°,
and path 2/3 also yaw them ∓30°. Duration 0 is a cut.

Offsets live in a yaw-only frame. Its +z axis points from the attached
object toward the target object, or along the object's heading when both are
the same (`Camera::UpdateEndTheta` `0x10195400`, `AdjustPosition`
`0x101938e5`). x is right and y is up. So `Landing + (0,5,−20)` aimed at the
ball sits 20 ft beyond the landing spot, facing the incoming ball. The camera
is kept at least 15 in above the terrain (`CalculateCameraPosition`
`0x1019333c`).

Projection (`Camera::NextFrame` → `Render3D::SetProjection(near, far, fovY)`,
checked in DXWrap): vertical FOV = 45° / z′, where z′ = z² for z ≤ 1, z
otherwise, clamped to 0.0625–256 (`CalculateZoomFactor` `0x10192f55`). Near is
50 in (10 in in a close mode), far 75000 in. Zoom 100 % = 45°, 150 % = 30°,
70 % ≈ 91.8°. "Zoom ball & cup" picks the zoom so both fit.

## 4. Camera rules to implement (plain language)

Offsets are feet in the frame above. "Cut" means duration 0. Unless noted,
camera cuts kill and clear earlier transitions.

### Snap camera (`s_camera.stn`; all cuts)

| When | Camera |
| --- | --- |
| Start of hole; start of turn not on the tee; any other turn start (priority 125) | Golfer + (0, 8, −25), look at golfer + (0, 6, 0) |
| Start of turn, putting (putt shot, ball on green or fringe) | Golfer + (0, 12, −25), look at golfer + (0, 6, 0) |
| In flight at 40 %, shot longer than 30 yd, landing not on green | Landing + (0, 5, −30), look at landing + (0, 6, 0) |
| Same, landing on the green, not putting | Same landing camera. The authored "Green Landing Cam" (pin + (3, 7, −25)) is never referenced |
| Hole end | Pin + (0, 75, 50), look at tee |

### Fixed camera (`f_camera.stn`)

Start of hole and every turn: golfer + (0, 8, −25) looking at golfer
+ (0, 6, 0), held for the whole shot. Hole end: pin + (0, 75, 50) looking at
the tee. Eleven other authored actions (apex, overhead and side views) are
unused.

### Ball camera (`b_camera.stn`)

| When | Camera |
| --- | --- |
| Start of hole, every prep | Golfer + (0, 3, −13), look at golfer + (0, 3, 0), zoom 100 % (cut, no kill) |
| Impact, golfer not on green | Ball + (0, 1, −20), look at ball + (0, −1, 0), zoom 100 % |
| Impact on the green | Glide to ball + (0, 3, −13) over 3 s looking at the ball, hold 0.7 s, zoom 100 % |
| In flight at 35 %, not putting, from off the green, ball going in the hole, human player | Letterbox to 30 % over 1 s |
| Hole end | Pin + (0, 75, 50), look at tee |

### Auto camera (`d_camera.stn`)

The default for every turn is the **swing camera**: golfer + (0, 3, −13)
looking at golfer + (0, 3, 0), zoom 100 %, pan and pitch 0 (weed rough:
height 4 ft). AI players always get it (priority 1).

| Moment | Rules (priority in brackets) |
| --- | --- |
| Start of turn (prep) | Fairway < 150 yd [100] or < 60 yd [99]: random flag/player fly-ins that end on the swing camera. Rough [100]: tight-on-ball shots. Sand [100]: "blimp" zoom-out. Weed rough: rise-up shots. Green, first putt [50]: crawl from ball to hole, high-back or high-left sweeps. Later putts and other lies: swing camera |
| Impact | Tee shot [100]: "watch ball from behind with zoom" (cut to golfer + (0, 3, −13), then pan to the ball and zoom 175 % over 2 s) or "follow ball 30 ft away" (×3 weight); par 3 [90] uses 18 ft. Chip/pitch: cut to the swing camera, then glide to ball + (0, 4, −8) over 2 s. Flop: watch-with-zoom, or the same glide to (0, 4, −15). Putts: glide to the ball from 4–10 ft behind over 2 s, some only 30 % or 60 % of the time |
| In flight (25 %) | Default [254]: landing camera or follow ball 30 ft (par 3 [253]: 18 ft). Fairway landing [130–160]: follow ball or side "HL/HR" views. Landing within 10/20/30 ft or 40 yd of the pin, by left/right/short/long miss [90–120]: approach "tower" views behind the green, green-side towers, ball-and-pin framing. Holed or near-cup from off the green ("bling", human only) [40–50]: letterbox 30 % with a zoom from the pin or landing toward the golfer. Bad landing (rough, sand, OB) [90–100]: side view, landing camera or follow. Water [80–90]: follow or landing camera. Putts [90–250]: follow 8–10 ft behind the ball, green "tower" views and slides for long misses (left/right-handed variants) |
| Reaction | By club and result: close-ups of the head or body from front, side or behind, crane and pan-zoom moves; extra variants for female golfers; putting reactions keyed to par and stroke count |
| Hole end | Pin + (0, 75, 50), look at tee |

The full 153-row table is generated by
`python3 Tools/decode_pga2005_cameras.py --rules d_camera.stn`; `cameras.json`
holds every condition and step.

### Replay (`Replay.stn`; game event 2, high)

| Shot | Replay chance |
| --- | --- |
| Hole-in-one (priority 1) | 100 % |
| Tee shot onto the green on par 4+; 75+ yd shot to < 3 yd or holed; 50+ ft bunker shot to < 6 ft or holed; 29+ ft putt holed; birdie/eagle holed from 15+ yd (par 3/4) or 15+ ft (par 5); any 30+ ft shot holed; 40+ ft putt holed; tee shot on a par 3 to < 3 yd | 80 % |
| Chip-in from fairway, rough or bunker from 10+ yd | 65 % |

Each replay action has no responses; the file's only response is an unused
`MatrixCam` placeholder. How the replay itself is filmed
(`CGameSettings::GetReplayCamera`, `ScriptCommand::ReplayShot`) is not
decoded.

### Effects (`anim.stn`; medium)

Sand blast (bunker shot), grass clippings (rough, bit 5 > 10), divot (iron
full shot from fairway/tee, bit 5 > 75), tee animation (driver/wood off a tee,
bit 5 > 30), water splash (> 20) and sand kick-up on landing (> 30). Bit 5 is
probably an impact speed; its unit is unknown.

### Data quirks to keep (high)

- Three "Reaction driver ecstatic … (Reverse View)" situations contain operator
  `0xffff` and can never match.
- "Reaction putt (par 5 strokes 2)" tests strokes == 3; "landing < 30 feet
  SHORT (Par 3)" tests "long" and has no par condition.
- f_camera "Zoom 70%" is command 5 (rotate Y 70°); it is only used by an
  unused action.

## 5. Tri-click swing meter

Classes: `TriClickMeter` (`0x101a5fae`, vtable `0x102d4958`),
`SwingMeterFrame` (drawing), and `ClickSwingControlC` (vtable `0x102d86b4`),
which turns the meter result into a swing. Control methods
(`MultiplayerGameSettings::SwingMethodDescription` `0x10231c42`): `0x400`
Tri-Click, `0x800` Two-Click, `0x100` TrueSwing H, `0x200` TrueSwing V.
Difficulty levels (`DifficultyDescription` `0x10231ca9`): 0 Novice,
1 Intermediate, 2 Advanced, 3 Expert. All constants below were re-read from
Engine.dll bytes by `verify_engine` (50 constants, 12 instruction immediates,
all match).

### Angles (high)

Degrees, 0 = 3 o'clock, counter-clockwise positive: 270 = 6 o'clock, 180 = 9,
90 = 12. Screen point = centre + r·(cos θ, −sin θ).

| Angle | Meaning |
| --- | --- |
| 270 (6 o'clock) | Rest, 0 % power, perfect accuracy |
| 90 (12 o'clock) | 100 % power |
| 48 (≈ 1:24) | Hard stop; overswing limit (raw 123.3 %) |
| 63 | Backswing starts slowing at or past this angle (115 %) |
| 229 (≈ 7:22) | Earliest accuracy value (direction −1) |
| 311 (≈ 4:38) | Latest accuracy value; reaching it is a miss (direction +1) |

`power = (270 − powerAngle) / 180`;
`direction = (accuracyAngle − 270) / 41`, negated for the putter (club 20).

### Timing (high for formulas, medium for the simulated times)

Speed is `65536 / period` degrees per millisecond, where `period` is 16.16
fixed point. Frame time is capped at 180 ms, a frame moves at most 16°, and
the angle is clamped to 48–311. Input is a left or right mouse-button press,
or a new Space press (DirectInput `0x39`), read once per frame before the
move (`NextFrame` `0x101a67dd`).

| State | Motion |
| --- | --- |
| 1 lift | Starts when `ClickSwingControlC` begins the swing (`FUN_1016418f` → `SetNewSwing`), presumably on the first click (medium). Moves counter-clockwise from 270 while slowing from 160°/s to 20°/s (period × 1.005 per ms): about 418 ms, to about 298°. Clicks ignored |
| 2 backswing/power | Clockwise. Accelerates (period × 0.99 per ms) to the level's top speed. At ≤ 63° it slows (× slow-down ratio). Power click accepted only at ≤ 270° |
| 3 after power | Keeps going clockwise, slowing until 20°/s (about 12° of overshoot) |
| 4 return/accuracy | Counter-clockwise, accelerating (× speed-up ratio) back to top speed; accuracy click here |
| 5 | Runs on to 311°, then finished (6) |

| Level | Top speed °/s (putter) | Speed-up/ms | Slow-down/ms | Start → 100 % | Power click → 270° | 229–311 window | ±0.1 direction |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Novice | 200 (170) | 0.985 | 1.015 | 1.60 s | 1.21 s | 410 ms | ±41 ms |
| Intermediate | 260 (170) | 0.98 | 1.02 | 1.38 s | 0.95 s | 316 ms | ±32 ms |
| Advanced | 325 (200) | 0.975 | 1.025 | 1.24 s | 0.78 s | 253 ms | ±25 ms |
| Expert | 355 (200) | 0.97 | 1.03 | 1.20 s | 0.70 s | 231 ms | ±23 ms |

The times come from the reference port at 1 ms steps, not from the running
game. Speed modifiers (`SetNewSwing` `0x101a61c5`): clubs 21–32 at non-Novice
levels −30°/s; flop (shot style 5) ×1.25; styles 4, 8 and 9 ×1.15; golfer
trait `+0x344` above 1 multiplies by its square (meaning unknown, low).

### Clicks (high; `SetStateAtMouseClick` `0x101a654d`)

- **Power.** If `|trunc(angle − 90)| < 3` the angle snaps to exactly 90
  (green tick). Above 90 is a white tick, below 90 (overswing) a red tick.
- **Overswing (power boost).** With `over = 90 − angle`, the stored angle is
  `90 − 0.2·over`, so effective power is at most 104.7 %. The return-speed
  floor is multiplied by `1 − over/150` (up to 28 % faster), which makes
  accuracy harder.
- **Accuracy.** If `|trunc(angle − 270)| < 3` it snaps to 270 (green tick).
  Clicks at or before 229 are clamped to 229 (direction −1).
- **Missed power.** If no power click by 48°, the power tick goes to
  `170 − rand(0..19)` (55.6–66.1 %) and the return floor × 0.72.
- **Missed accuracy.** Reaching 311 gives direction +1 and a ×4 error (below).
- **Two-Click** ends at the power click with direction 0.

### Click to shot (medium–high; `ClickSwingControlC`)

`FUN_10164402` turns the result into a horizontal mouse offset for the
TrueSwing analyser:
`x = trunc(xFactor · sign(d) · d² + 0.5)`, with xFactor −100/−150/−220/−300
for Novice/Intermediate/Advanced/Expert. It is ×4 if accuracy was missed and
× 2p² when power > 100 % or power was missed (p = 1.2 then). Two control
flags flip the sign. `FUN_10164621` then plays a synthetic stroke: the
backswing lasts 700·max(p, 0.5) ms. Shot power (`FUN_10164344`) is p × base ×
shot-hit factor (style 3: 0.6, 6: 0.4, 7: 0.7, else 1) × 0.8 for the putter.
In the shared analyser, `FUN_101609dd` "ComputeClubfaceDirection" sets
face angle = sign(x)·|x|^0.6 · maxSliceAngle, with max slice 1.5°/3.5°/5°/6°
by level. **Which side is hook and which is slice is not established**; see
the open questions.

### TrueSwing (analog mouse; medium, high level only)

`MouseSwingControlC`/`HumanSwingControlC` sample mouse points with times
(`SWINGINFO_MSG::AddPoint`). Debug strings in `0x10381d10–0x10382668` name the
pipeline: impact info (top and impact points), swing duration, average
velocity, `AdjustClubVelocity`, power/spin multipliers,
`ComputeClubfaceDirection`, tempo `AddPaceError` (slow/fast tempo),
`AddStraightEdgeError`, which penalises perfectly straight strokes,
`AddBTBAndLie`, and `AddShotSetupAndHill`. Per-level tuning: mouse ranges
(100/220/2000, 30/170/230, 25/140/180, 15/120/160), backswing pixel limit
500 for Novice and 2000 otherwise, magnet assist 0.8/0.45/0.05/0,
power-shot penalty 5/3/2/2, miss-hit club rotation 1.25°/2.5°/4°/5°, and putt
power exponent 1.0/1.1/1.2/1.2 (1.0 for the click methods). Expert disallows
power shots and high spin. The ball-flight work owns the details
(`0x1015f…0x10164…`).

### Dial drawing vs the native HUD (high)

`SwingMeterFrame::Draw` (`0x10085201`) draws a quad as four triangles
(bottom, left, top, right) around the texture centre (UV 0.5, 0.5). Texture
`0x300c` (lit) covers the arc **from 315° (about 4:30) clockwise to the
marker**, and `0x300d` (unlit) covers the rest; that these IDs are
`swingon.dds`/`swingoff.dds` is inferred from the art (medium). A partial wedge finishes the
current quadrant. Ticks (`FUN_10084a77`) are radial quads 4 units wide, from
radius 76 out to a circle of radius 96 centred 2 units left and 7 down of the
pivot, in a 255-unit frame. The `swingon` art matches the code: green at
6 o'clock, yellow at 9, orange at 12, red from 12 to about 48°, and
green→teal→blue from 270° to about 315°. The painted ring centre is
(123.5, 135.5) in the 256² image, not the pivot (128, 128).

Compared with the native HUD (`PGAOriginalSwingMeter`, read only: lit wedge
from 6 o'clock clockwise by power × 180°, accuracy ray at ±45° around
6 o'clock, power ping-pong over 2.4 s):

1. Correct: clockwise from 6 o'clock, 12 o'clock = 100 %, perfect accuracy at
   6 o'clock, early clicks on the 7–8 o'clock side, and the wedge pivots at
   the texture centre like the original.
2. The original lit sector starts at **315° (about 4:30), not 270°**. The
   270–315° accuracy band is lit before the swing, and the lit area follows
   the marker back during the accuracy phase.
3. The original power arc continues past 12 o'clock to 48° (overswing, red)
   rather than stopping at 100 %.
4. The original sweeps once: a ~28° counter-clockwise lift, then one
   accelerating clockwise sweep. If you do not click, power fails at 48°. It
   never ping-pongs.
5. The original accuracy range is 229–311° (±41°, not ±45°). The marker
   accelerates through it at the level's top speed (200–355°/s).
6. The original leaves ticks where the clicks happened, coloured green for an
   exact 100 % or 270°, white for under, red for overswing.
7. The painted ring centre is about 4.5 px left of and 7.5 px below the pivot
   (128, 128), so the art is slightly off-centre in both versions.

## 6. HUD layout (low data, mostly unknown)

No HUD layout data exists in the media. `DataImages*` hold only DDS/TGA/BMP
images, cursors, fonts (`.hgf`) and three thumbnail `.tbf` tables. The
`.ini` files are render settings, and the `.stn` files contain no screen
positions. The PE resources of `TW2005.EXE` hold shaders, a device dialog, a
type library and render states only.

Known geometry: the meter frame defaults to rect (100, 200)–(356, 456), a
256×256 square. The caller supplies a scale and a position through
`TriClickMeter(const CRect*, float scale, CPoint)` and `MoveInRect`. That
caller, and the club bag, wind, lie and distance panels, live in
`TW2005.EXE`. Its `.text` and `.data` sections have entropy 8.00 (encrypted,
`stxt774`/`stxt371` loader sections), so their layout cannot be read
statically without bypassing the protection, which this work did not do.
Reference screenshots are the practical route.

## 7. Confidence summary

| Topic | Confidence |
| --- | --- |
| File roles, `.stn` layout, operators, selection, response fields | High |
| Command/object/path/start/flag enums, FOV and zoom formula, easing | High |
| Event ids and the main event values (lie, distances, par, miss) | High |
| Flight index meaning (progress fraction), shot-distance definition | Medium |
| Offset frame orientation | Medium–high (code plus names) |
| Meter angles, constants, state machine, snap and overswing rules | High |
| Simulated meter times | Medium (model, not runtime) |
| Click → lateral offset → clubface chain | Medium–high |
| Hook vs slice side, CAMERASCRIPTTYPE numbering, HUD positions | Unknown |

## 8. Open questions

1. Which `CAMERASCRIPTTYPE` value (0–3) selects which file, and what the
   in-game option labels are (code in encrypted `TW2005.EXE`).
2. Hook vs slice: whether a late accuracy click (direction > 0) curves left
   or right for a right-hander. The sign chain is xFactor (negative) →
   lateral pixels → `ComputeClubfaceDirection`; the screen-x and clubface
   conventions in the analyser need the ball-flight decode or a reference
   capture.
3. The exact quantity behind the flight index (`CBallFlight+0x331`) and the
   sample counter (`+0x32c`).
4. Meanings of event bits 5, 6, 13, 18–20 and 23–28; shot styles 3, 4, 7, 8, 9
   (`CPlayer+0x78dd`); golfer trait `+0x344`.
5. Who calls each `View*` function and when, for frame-exact event timing.
6. Screen placement and scale of the meter and the other HUD panels.

## 9. Reproduction

```
python3 Tools/decode_pga2005_cameras.py                 # cameras.json + swing.json
python3 Tools/decode_pga2005_cameras.py --rules d_camera.stn
python3 Tools/decode_pga2005_cameras.py --simulate 1 0 1383 2336   # level, click ms...
python3 -m unittest Tests/test_pga2005_cameras.py
```

Ghidra: Engine.dll was imported fresh into
`Library/Research/ghidra-projects-presentation/pga2005-presentation`
(auto-analysis succeeded). Exports are in
`Library/Research/ghidra-presentation/pass1…pass12`, made with
`Tools/ExportGameFunctions.java` and a scratch helper script that searches
xrefs, vtables and symbols. The physics project was not opened.
