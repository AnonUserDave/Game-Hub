# PGA Tour 2005 ball simulation specification

Static reconstruction of the ball physics in `Engine.dll`
(SHA-256 `94aa30bb645ea089fed6e98df0dce38d75c309e4531386cbe33c07f65bd19728`, PE32 x86,
image base `0x10000000`). It is precise enough for a native implementation to
replace the provisional physics.

- Constants with addresses, widths and bytes:
  [`evidence/pga2005-ballflight.json`](evidence/pga2005-ballflight.json).
- Executable reference:
  [`Tools/pga2005_ballflight_reference.py`](../../Tools/pga2005_ballflight_reference.py).
- Tests: [`Tests/test_pga2005_ballflight.py`](../../Tests/test_pga2005_ballflight.py).

## Status and confidence

Everything here comes from static analysis. Headless Ghidra 12.1.2 decompiled
the functions, using the kept database
`Library/Research/ghidra-projects/pga2005-physics`. The outputs are in the
ignored `Library/Research/ghidra-ballflight{,-2..-6}`. Apple LLVM `objdump`
disassembly confirmed every formula below, with special care over x87 operand
widths. The game was never run.

Decompiler text is not original source. Where the decompiler showed a
`(float)` cast but the instruction stores a double, this document follows the
instruction. The reference simulator implements this specification. Nobody has
compared it with the running game.

Confidence labels:

- **High:** the formula, operand widths and control flow were checked
  instruction by instruction.
- **Medium:** the control flow is clear, but a name or meaning is interpretive
  or a helper was not decompiled.
- **Low:** an inference from data or partial reading.

## 1. Units, axes and time base

| Item | Value | Source | Conf. |
| --- | --- | --- | --- |
| Length | inches. Ball radius 0.84 in (`0x102d9758`), r² 0.7056 (`0x102d9760`) | Impact, Collide, rolling | High |
| Mass | ball 1.62 (oz) (`0x102d9768`); I = 0.4·m·r² = 0.4572288 (`0x102d97f0`) | Collide, PureRolling | High |
| Tick | 1/fps s. `StartBall 0x101f758b`: k = fps/60 (`+0x325`), inv = 60/fps (`+0x2d5`), g = inv²·0.10717 in/tick² (`0x102d97c8` f64; 9.80 m/s²) | StartBall | High |
| Human fps | 60. `GolferHumanSwing::Update 0x101a7c93` calls `HitBall(club, aim, pos, 0x3c)` | — | High |
| Axes | +Y up. Aim 0 points along +Z. `CVector3::RotateY(a)` (Utils.dll `0x1001c3f0`) maps (x,z) → (x·cos a + z·sin a, z·cos a − x·sin a), so positive angles turn +Z toward +X | — | High |
| Velocity | inches per tick; spin is radians per tick. The aerodynamic polynomials use 60 Hz units (s·k, w·k) | Flying | High |
| Wind | mph × 0.293333 → in/tick at 60 Hz (`CGolfBall::SetupBall 0x1013786f`). The vector is the air's velocity, so +Z is a tailwind for aim 0 | SetupBall, Flying | High (factor), Medium (sign convention) |

The integrator is semi-implicit Euler. Each tick, the state routine first
updates velocity and spin, then `BallLoopUpdatePos 0x101f8696` saves the old
position and adds the velocity.

The vertical position tracks the ball's contact point (bottom), not its centre:
- rolling snaps y to the ground height;
- the cup code compares y + 0.84 with the rim.

The contact-geometry code uses r = −0.84·n from the centre.

## 2. Launch: swing → `ClubAtImpactS` → `Impact`

### 2.1 Plumbing (high)

`HitBall 0x1013834c` → `CGolfBall::SetupBall 0x1013786f` copies
`ClubAtImpactS` into the embedded `CBallFlight`. That object starts at
`CGolfBall+0x2a9`.

| CBallFlight | Source | Meaning |
| --- | --- | --- |
| `+0x4/+0x8/+0xc` | course vtable `+0xb8/+0x88/+0x8c` | wet scale; rough length; sand difficulty. A wet scale above 1 becomes wet − (1 − `GetAbilityFactor`)·(wet − 1). The ability factor (player vtable `+0x20`, `0x1013bfad`) is 0.25, 0.6, 0.9 or 1.0 from Novice to Expert |
| `+0x10/+0x14` | `CCourse::GetWindXZ 0x1017c310` × 0.293333 | wind x/z in in/tick |
| `+0x18` | aim + club`+0x30` | heading. `BallAtImpact 0x101f26d2`: h = −`+0x18`, sin → `+0x365`, cos → `+0x36d` |
| `+0x1c..+0x24` | `CHole::PinPosition` | cup centre (f32) |
| `+0x28..+0x30` | `Position` | start (f32) |
| `+0x40` | club`+0x28` = 1/club`+0x2c` (f32) | 1/power |
| `+0x44..+0x4c` | club`+0xc..+0x14` | face normal, RotateY(face) of (0,0,1) |
| `+0x50..+0x58` | club`+0..+8` | club path direction, RotateY(path) of (0,0,1) |
| `+0x6c` | club`+0x24` | loft adjustment (rad) |
| `+0x70` | club index | 0..44 |
| `+0x74` | club`+0x38` | sand blend |
| `+0x78` | club`+0x40` | spin multiplier |
| `+0x7f` | fps | |
| `+0x8c` | club`+0x20` | launch (uphill) adjustment (rad) |
| `+0x90` | player vtable`+0x58` `GetTerrainVImpactReducer` | 0.0 for `CPlayer` and `HumanPlayer` (`0x10002fb0`) |
| `+0x99` | `Position::GetSubTerrainType` | lie record index |
| `+0x281` | player`+0x78dd` | ShotTypeE: 0 Full, 1 Chip, 2 Putt, 3 Punch, 4 Flop, 5 Pitch, 6 Pick, 7 Blast |
| `+0x3ad/+0x3b1/+0x3b5` | `CPlayer::GetBallCoeffs 0x10141fb6` | ball spin-decay, spin and speed coefficients |

`StartBall` calls `Impact`. It then sets the position to the start, the ground
height `+0x2ad` to the start y, and clears the bounce, cup and bunker flags.

### 2.2 Club tables (high values; medium club names)

There are four f64[45] arrays indexed by club. The bunker variant of each array
is the same array at index `club+25`.

| Address | Meaning |
| --- | --- |
| `0x1038b540` | speed factor S (driver 0.454135, putter 0.0471) |
| `0x1038b6a8` | launch angle Θ, in rad: the face-normal tilt (9° driver 0.12526 = 7.18°; LW 0.63896 = 36.6°) |
| `0x1038b810` | pitch offset P (0 except 0.1 for the bunker variants 33..44) |
| `0x1038b978` | spin factor G (driver 0.8675; 1-iron 1.2662; putter 1.0) |

Club names, in Language.dll string order:

| Index | Club |
| --- | --- |
| 0 | 9° Driver |
| 1 | 12° Driver |
| 2–7 | 2–7 Wood |
| 8–16 | 1–9 Iron |
| 17 | PW |
| 18 | SW |
| 19 | LW |
| 20 | Putter |
| 21–32 | chip variants (inferred) |
| 33–44 | bunker variants of 8–19 |

`Caddy::GetMaxClubDistance 0x101132c9` holds an independent per-club table, in
inches: driver 10800, 3W 10044, 7-iron 6408, putter 1260. Full values are in the
JSON.

### 2.3 `CBallFlight::Impact 0x101f4e6a` (high)

```
S, Θ, P, G = tables[club]
info = TerrainHeightCPP(start.x, start.z, flags 0x70014000)   # material, normal
rec, F = ConsiderTerrain(material, lieIndex(+0x99), rough(+8), sand(+0xc))
if shotType == 5(Pitch) and rec.flags & ROUGH: F = (1-F)*0.5 + F
if rec.flags & BUNKER and (club < 21 or club > 32):
    b = f32 sandBlend (+0x74)
    if club < 8:  F *= (0.699999988 - 1)*b + 1
    else:         F *= (1.5 - 1)*b + 1
                  S = (S - S[club+25])*b + S[club+25]   # same for Θ, G, P
if F < 0.9599999785: F += (0.9599999785 - F)*lieComp(+0x90)
speed = S * 8.333333015 * inv / f40          # f40 = f32(1/power)
v_club = dirPath(+0x50..) * speed * ballSpeed(+0x3b5)
```

The putter branch runs when `club == 20`. It leaves state 4, rolling and
slipping:

```
v_club rotated by heading: x' = x*cos h - z*sin h ; z' = z*cos h + x*sin h
n = normalized terrain normal at start (NormalizeCoefficient 0x101fd4bc)
v = (v_club - n (v_club·n)) * 1.7999999523 ; omega = 0
```

Every other club:

```
a = f6c(loft adj, f32) + Θ ; if f32(0.4*Θ) > a: a = f32(0.4*Θ)
n = (fx, fy cos a + fz sin a, fz cos a - fy sin a)    # face normal tilted by a about X
vn = n (v_club·n) ; vt = v_club - vn
v  = (vn + 0.1000000238*vt) * F                       # 1 - 0.8999999762
s  = c1 * G / 0.84                                    # c1 = lie record spin factor (f32)
if BUNKER: club<20: s *= 1 - (1 - b)*0.5 ; club>20: s *= 0.5
if ROUGH:  s *= rough (+8)
omega = ((0.9*vt) × n) * s * ballSpin(+0x3b1) * spinMult(+0x78)
pitch p = launchAdj(+0x8c) + P : vy' = cos p vy + sin p vz ; vz' = cos p vz - sin p vy
          (velocity only; the spin is not rotated)
heading: rotate v and omega as in the putter branch
state = 2 (flying)
```

With a square face and path, omega = (−0.9·speed·sin a·s·…, 0, 0), which is
backspin. The contact offset −0.84·n is computed but unused. An open face
relative to the path (face > path) curves toward +X, as in the D-plane model.

### 2.4 `TerrainData::ConsiderTerrain 0x101fd345 / 0x101fd3f3` (high)

The routine walks the lie index down while the record's c0 is 0.0. There is no
bounds check, and the "no record → 0.7" branch is unreachable.

```
F = c0
if ROUGH:  F = ((rough - 1)*0.2 + 1) * (g_m + c0)   # g_m = f32(GetMagnetEffect()*0.05) (global 0x10450140)
if BUNKER: F = ((sand  - 1)*0.2 + 1) * c0          # overrides
```

`GetMagnetEffect` is Novice 0.8, Intermediate 0.45, Advanced 0.05 and Expert
0. The 0.2 slopes are `0x102d9980` and `0x102d9988`.

### 2.5 Swing control layer (medium-low; documented, not reimplemented)

`HumanSwingControlC` is the RTTI base for `MouseSwingControlC` (TrueSwing),
`ClickSwingControlC` and `ReplaySwingControlC`. Vtable slot 3, `0x10162c8d`,
builds `ClubAtImpactS` in this order:

1. The derived setup fills the path vector `club+0..8`: Click `0x10164402`,
   Mouse `0x10162aba`.
2. Power `club+0x2c` comes from vtable slot 17.
   - **Click (`0x10164344`):**
     ```
     power = TriClickMeter::GetPowerPercent (= (270 − angle)/180) · this+0x50
             · CPlayer::GetShotHitFactor (Punch 0.6, Pick 0.4, Blast 0.7, else 1)
     ```
     It is ×0.8 for the putter.
   - **Mouse (`0x10160b35`):** the "AdjustClubVelocity" curve.
   - `this+0x50` = `Caddy::GetAveragePlayerPower 0x10112529`. For the putter
     and clubs 21–32 it is `GetMaxClubPower` (8 putter, 14 otherwise). For a
     human it is otherwise 14 × `GetAverageDistance()` / 9720. Average distance
     by difficulty: Novice 9612, Intermediate 10116, Advanced/Expert 10800 in.
     A 100% Advanced or Expert swing is therefore power 15.5556.
3. `0x1016258d` sets:
   - spin multiplier = SWINGINFO`+0x348`;
   - power ×= SWINGINFO`+0x344` (power-shot multiplier);
   - launch adjustment = SWINGINFO`+0x350` ("UphillAngle").
4. `0x101609dd` "ComputeClubfaceDirection":
   ```
   path = sign(x)·|x|^0.6 · MaxSliceAngle
   ```
   x is the path vector's x component. MaxSliceAngle is 1.5°, 3.5°, 5° or 6°
   by difficulty.
5. `0x101610cd` "AddBTBAndLie" divides path by the lie factor (§2.6). It
   computes a "risk" from power, mouse ranges and wet/sand/rough, and from that
   the face (`club+0x1c`) mishit rotation, up to
   `MaxMissHitClubRotation` (1.25°, 2.5°, 4° or 5°). It applies an
   off-the-tee driver penalty and a mishit speed reduction.
6. `0x10162054` "AddShotSetupAndHill" applies, from SWINGINFO`+0x324`:
   - setup direction, loft and sand blend;
   - plane/aim offset (`club+0x30`), mirrored for lefties;
   - up- and side-hill corrections scaled by `GetUpAndSideHillReduction`.
7. `0x101623d4` applies, for clubs < 11: `loft += −(path − face)·0.5`.
8. The path and face vectors reset to (0,0,1) and are rotated by RotateY(path)
   and RotateY(face). `club+0x28` = 1/power.

The AI path (`BinarySwingFinder::TestSwing 0x100ef823` →
`CGolfBall::PreCalculateBall 0x10137bfd`) uses a club vector of
power·(sin hook, 0, cos hook), f40 = 1 and a square face. That supports reading
`power` as the club-speed magnitude.

### 2.6 Player, ball and lie tables (high values)

| Ball type (`player+0x12ed`) | Speed | Spin | Spin decay |
| --- | --- | --- | --- |
| 0 Two-Piece | 1.02 | 0.97 | 1.0 |
| 1 Solid Core | 1.0 | 1.05 | 0.95 |
| 2 Wound Balata | 0.99 | 1.13 | 0.9 |

The lie accuracy factor (`0x10161eb0`) is 1 − penalty, by record index:

| Surface | Penalties |
| --- | --- |
| Rough | Md 0.3, Lt 0.25, Dp 0.35 |
| Weed | Md 0.8, Lt 0.7, Dp 0.85 |
| Sand | Med 0.45, Lt 0.4, Dp 0.5, Plug 0.55 |

The lie only affects launch power through c0 in §2.4.

## 3. Tick loop (`BallCalculate 0x101f2a1b`, `BallLoop 0x101f795f`) (high)

There are at most 0x800 ticks. Each tick runs:

1. **`BallLoopUpdatePos`.** State 2 runs `Flying`, 4 runs `RollingAndSlipping`
   and 8 runs `PureRolling`. Any other state becomes 0 and the shot ends
   (`EndBallCalculate`). Then prev = pos and pos += v.
2. **`BallLoopTerrainHeight 0x101f7ccb`.** If the ball is flying and
   QuickTerrainHeight + 1 ≤ y, ground (`+0x2ad`) = quick height and no
   collision test runs this tick. Otherwise a precise `TerrainHeightCPP` returns
   height, normal and material into `+0x14e`/TerrainData. The probe flags are
   `0x78014000`, or `0x78054000` when rolling.

   A missing height falls back to an 8-patch average. An invalid camera
   location sets StopBall and out-of-world (`+0x60` = 1).
3. **If state 1 (stopped):** ground = y.
4. **Otherwise:**
   - tree/object tests (§9);
   - then, if `CupCollisions` (`+0x97`) is set and `CupDynamics` returns true,
     ground = −1e10;
   - else `BallLoopTestTerrainCollisions 0x101f8d87`:
     - Flying with ground ≥ y: y = ground, then `Collide(terrain normal)`. If the
       surface is a bunker, record the entry once: |v·n| (`+0x2b5`) and the
       position.
     - Rolling (4/8): if y − ground < 1.5, y = ground; else state = 2.
     - Steep walls: the previous→current segment is tested against the mesh.
       Faces with n_y ≤ 0.25(n_x²+n_z²) are accepted. The hit restores the old
       position, runs `Collide`, multiplies v and ω by 0.9 and takes one extra
       step. This is not modelled in the reference.

`StopBall` sets state 1. The ball keeps the velocity of that tick and moves once
more. The next tick ends the shot.

## 4. `CBallFlight::Flying 0x101f5b7d` (high)

```
(wx, wz) = wind (+0x10,+0x14) if y - ground(+0x2ad) > 18 else 0
r  = v - (wx, 0, wz)*0.6000000238*inv                 # air-relative velocity
s  = |r|, w = |omega|, S = s*k, W = w*k               # 60 Hz units
Cd = ((-0.000348685688*S + 0.0168940704)*W + 0.000780952396*S + 0.225790471) * 0.000474568689
Cl = ((-0.000628289126*S + 0.0407094695)*W - 0.000201047602*S + 0.0847342834) * 0.000474568689
c  = omega × r                                         # lift direction
v += r*(-Cd*s) + c*(Cl*s²/|c|) ; v.y -= g
d  = wz*v.z + wx*v.x                                  # raw wind, after the update
h  = d < 0 ? 0.3*|d*(v.x, v.z)|/|v|² : 0              # head-wind term
omega *= 1 - (1 + h)*0.003000000026*inv*ballDecay(+0x3ad)
```

The drag and lift accelerations are both Coefficient·|r|². 0.000474569 equals
ρA/(2m) for ρ ≈ 1.2 kg/m³. With zero spin the original divides 0/0 for lift.
That never happens in practice, and the reference guards it.

## 5. `CBallFlight::Collide 0x101f3310` (high control flow; c-names medium)

The surface record is index 1 when texture-section flag 0x80000 is set and
there is more than one record; otherwise index 0. Section flag 0x8 (tree)
routes to `TreeCollide` without counting a bounce. Otherwise `bounces += 1`.

The terrain branch (param5 true) builds a "dent" normal:

```
n = normalize(terrain normal) ; speed(+0x29d) = |v| ; (+0x2a5) = (v·n)²
d = -(v/|v| + n)
dent = |v·n| / c8 * k
  green or fringe: ×0.800000012 (each)
  rough: ×(2 − rough)
  short grass (flags 0x1015): ×(2 − ((wet−1)·1.4 + 1))
soft = c9 ; rough ×0.667 ; weed ×0.5
  fairway/green: second bounce ×0.75, later bounces ×0.5
dent += soft
n = dent <= |d| ? normalize(n + (dent/|d|)·d) : normalize(-v)
speed *= k
```

Steeper or softer landings tilt the normal toward the incoming direction. That
converts forward speed into the normal impact.

Contact frame and impulse:

```
rc = -0.84 n ; vc = v + omega × rc ; t = unit(vc - n(vc·n)) or (0,0,1) below 1e-10
a1 = atan2(n.x, n.y): rotate (y,x) of v, omega and t by a1   [idiom: A' = cA + sB; B' = cB − sA]
a2 = -atan2(n'.z, n'.y): rotate (z,y) by a2
   t''.y = t'.y c2 − t'.z s2 ;  t''.z = t'.z c2 + t''.y s2   (quirk: uses the NEW y)
if v.y < 0 (approaching):
   a3 = atan2(t'.x, t''.z): rotate (z,x) by a3
   Jx = (0.84·ω.z + v.x)·0.462857157       # m/3.5
   e  = object ? 1 + objRestitution
              : 1 + c2'·fall, where
                fall = 1                        if speed ≤ 8
                     = 1 − 1.75·(speed−8)/c8    (green: c8/0.8)
                c2' = f32(c2·0.9f) on fairway;
                short grass: e ×= (wet−1)·0.11 + 1
   Jn = e·v.y·1.62 ;  Jz = (v.z − 0.84·ω.x)·0.462857157
   lim = |Jn|·c3·0.3 (×wet on short grass; object: |Jn|·objFriction)
   if lim < |Jt|: J_t ×= |coef·Jn/|Jt||   (coef = c3·0.3[·wet] or objFriction)
   v −= (Jx, Jn, Jz)/1.62 ;  ω.x += Jz·1.83715463 ;  ω.z += Jx·1.83715463   (r/I; sign of the ω.z term kept as in the original)
   terrain only: v, ω ×= damping
       1.0;
       rough (not alt) 0.8;
       alt section 0.9;
       weed 0.6;
       fairway 0.97;
       green 0.97   (later ones override)
   if v.y·k < 0.5 and |v_xz|·k < 1.0:
       if terrain, bounces < 6, short grass, wet > 0.7 and |pos − start|_xz > 2268:
           L = c3·0.3·(4/0.3)   (×0.1 when 0.84(ω.x v.z − ω.z v.x) ≥ 0, i.e. forward spin)
           v.x −= 0.84·ω.z·L ;  v.z += 0.84·ω.x·L        # spin-back or forward kick
       state = 8 (pure rolling)
   rotate back by −a3
rotate back by −a2, then −a1
```

The coefficient of restitution is c2·fall, which is ≤ 0.09 on PBL fairways, so
landings are nearly dead. Shots run out as a sequence of one-tick micro-bounces
in state 2. Each one is damped by 0.97 and friction-limited until the
tangential speed falls below 1 in/tick. The ball then switches to pure rolling,
with the "spin kick" applied once.

## 6. `CBallFlight::RollingAndSlipping 0x101f6112` (high; putts start here)

Uses record 0. All intermediates are doubles.

```
n = normalized normal of the last precise terrain sample
f = 1 − c4 ;  rough: f ×= (2 − rough)  else short grass: f ×= (2 − wet)
gt = (g n_y n_x, −g + g n_y², g n_y n_z)·f            # tangential gravity
t = unit(v − n(v·n)) ; v = t·|v|                       # project, keep speed
F = −g·n_y·c5·1.5 ; same rough/short-grass factor as f
dω = F·2.5/0.84
v += gt ; ω += (t × n)·dω                              # F < 0, so ω tends to the rolling sign
if |v| ≤ |ω|·0.84: state = 8
```

Linear speed is not reduced while slipping. Friction only spins the ball up.

## 7. `CBallFlight::PureRolling 0x101f6742` (high)

```
n, t, v = t|v| as above ; r = −0.84 n
a = −g·r.z·1.62 ; b = r.x·g·1.62                     # horizontal fall-line torque
if (a,b) ≠ 0:
   p = |b·t.z + a·t.x| ; (a,b) ×= p/|(a,b)|           # side-slope part only
   L = |(a,b)|·c6 (green ×0.6)
   ω = (r × v)·(−1)/r²  [= (v × r)/r², the rolling spin]
   L /= |ω|·I                                          # gyroscopic precession angle
   u = (b ω.y, a ω.z − b ω.x, −a ω.y) ; flip = u.y < 0 ; if flip: u = −u
   a1 = atan2(u.x, u.y): rotate (y,x) of v ; a2 = −atan2(u.z, u.y c1 + u.x s1): rotate (z,y)
   rotate (z,x) by (flip ? +L : −L) ; undo a2, undo a1
v += t·(−(5/7)·g·t.y)                                  # slope acceleration along travel
R = (5/7)·g·n_y·c7
   green ×0.575
   short grass:
       wet > 1: ×(1 − 1.16(wet−1))
       wet = 1: ×1
       wet < 1: ×(2 − 0.55·wet)   ← discontinuous at 1
   rough: ×(2 − rough)
if R ≤ |v|: v −= t·R  else StopBall()
ω = (−v.z·r.y/r², 0, r.y·v.x/r²)
```

Break therefore comes only from precession about the travel direction. A ball
across a slope turns downhill. The 0.375 c6 is constant across PBL/TUR surfaces.

## 8. Stop and next lie (`StopBall 0x101f769c`) (high)

State becomes 1. A ball-disappears flag (0x800 without water 0x40) sets `+0x98`.
The next-lie index `+0x99` is chosen as follows (`rn()` is uniform [0,1)):

- **Bunker.** If no entry was recorded, the ball moved ≥ 6 in on any axis since
  entry, or the entry |v·n| < 10, choose 1 (Lt). Otherwise:
  - if entry < 12 or rn() ≤ 0.9: rn() ≥ 0.1 → 0 (Med), else 2 (Dp);
  - else if (entry ≥ 14 and rn() > 0.9) or rn() < 0.1: 3 (Plug);
  - else 2.
- **Rough.** A blend section (flag 0x80) gives 1. Otherwise
  `random(2) < 1 ? random(count) : 0`.

## 9. Cup, trees and objects

### `TerrainData::CupNormalFudge 0x101fe0b6` (high)

Runs inside `TerrainHeightCPP`, outside the front end. Within 2.325 in
(horizontal) of the pin, the terrain normal becomes
(pin.x − x, pin.y + 4 − h, pin.z − z). The ball is funnelled toward the hole.

### `CupDynamics 0x101f9966` (medium)

`LineIntersectsSquare` was not decompiled. The reference uses a segment–box
test.

The routine runs when the previous→current XZ segment crosses the square of
half-size 2.5 around the cup, and the ball is not flying above cup height.

1. **Path frame.** With a = atan2(dx, dz):
   - L = horizontal step;
   - u = cup lateral offset;
   - w = cup distance along the path;
   - h = √(4 − u²), giving entry/exit points w ∓ h.
2. **Touch test.** If |u| < 2, entry < L and exit > 0, the cup is touched
   (`+0x376`).
3. **Rolling ball.** It drops by g × the fraction of the step over the hole and
   becomes flying. If L + 0.84 < exit, return (it falls in naturally).
4. **Sampling.** Sample the 3-D path every 0.125 in.
   - Above cup height: continue until past w, then return.
   - At or below cup y − 4: holed (`+0x94`), StopBall.
   - Outside radius 2 (and past entry for a rolling ball): return false.
5. **Wall/rim contact.** The ball meets the wall or rim when
   2 − dist < horiz and exit − L ≤ L − entry.
   - dyc = y + 0.84 − cupY.
   - dyc ≥ 0 (rim): n_y = dyc and horiz = √(0.7056 − dyc²). A fast ball
     (L·k ≥ 3.75 and dyc < 0.8) uses horiz = 0.8 and keeps the old n_y.
   - dyc < 0 (wall): n_y = 0, horiz = 0.84.
   - The normal points toward the hole centre. The ball is moved back
     (2 − horiz − 0.125).
   - `Collide` runs in object mode: wall restitution 0.04 and friction 0.3; rim
     0.04 and 0.6.
   - Then ω ×= 0.1.

Lip-outs emerge from this rim and wall collision. They are not scripted.

### Trees and objects (interface only)

- `BallLoopTestTreeCollisions 0x101f87ad` and `TreeCollide 0x101f2b24` run when
  `AllowCollisions` (`+0x7d`) is set.
- `BallLoopTestMiscCollisions 0x101f8b0e` covers objects.
- Constants are in the JSON; the behaviour is not modelled.
- A native port needs a callback that, given the old and new positions, returns
  a hit point and normal and applies `Collide` with object coefficients.

## 10. Conditions

| Setting | Values | Default (PBL INI) |
| --- | --- | --- |
| GreenCond → wet (`CCourse::GetWetScale 0x1017ac0e`) | 1 Very Slow 0.6, 2 Slow 0.8, 3 Normal 1.0, 4 Fast 1.2, 5 Very Fast 1.4 | 3 Normal (1.0) |
| RoughLength (`GetRoughLength 0x1017abcc`) | 1 Light 1.3, 2 Average 1.0, 3 Heavy 0.7 | 2 Average (1.0) |
| WindSpeed | 1 Still, 2 Calm, 3 Breezy, 4 Gusty, 5 Strong (selects a `Wind1` type) | 1 Still |
| Sand difficulty | `CCourse` 1.0; composite holes 1.3 − 0.6·setting | 1.0 |

Wind magnitude per WindSpeed comes from a runtime-initialised `Wind1` table
(`0x10439028`). It is not recovered. The course rounds speed to integer mph
(`ForecastWind 0x1017c23f`).

"Wet" acts as firmness. Larger values mean faster greens, less dent and more
bounce.

## 11. Reference simulator

```python
from pga2005_ballflight_reference import *
terrain = flat_terrain(PBL_SURFACES["fairway"])            # or any callable (x, z) -> TerrainSample|None
r = simulate_shot(Launch(club=0, power=full_swing_power(0, 2)), terrain,
                  Conditions.from_settings(green_cond=3, rough_length=2, wind_mph=(0, 0)),
                  ball=BALL_TYPES[1], fps=60, pin=None, seed=0)
r.carry, r.roll, r.total, r.apex, r.trajectory, r.holed, r.next_lie_index
```

`TerrainSample(height, normal, Surface(records=(SurfaceRecord(c0..c9, flags),…), section_flags))`
mirrors the TCL surface record. `Launch` mirrors §2.1:

- power, path, face;
- loft, launch and spin adjustments;
- sand blend, aim, shot type, lie index, start position.

Not modelled: steep walls, trees, objects, the quick/precise height split and
the swing-control layer (§2.5).

Representative output, all static model predictions. The setup is a flat PBL
fairway, a tee-box lie for woods, ball type 1 (Solid Core) and a 100% swing at
power 15.556 (Advanced or Expert):

| Club | Ball speed | Launch | Spin | Carry | Roll | Total |
| --- | --- | --- | --- | --- | --- | --- |
| 9° Driver | 199 mph | 6.5° | 4100 rpm | 277 yd | 27 yd | 304 yd |
| 3 Wood | 185 mph | 8.1° | 5100 rpm | 270 yd | 14 yd | 283 yd |
| 5 Iron | 137 mph | 11.8° | 7600 rpm | 200 yd | 6 yd | 206 yd |
| 7 Iron | 125 mph | 15.9° | 9000 rpm | 176 yd | 2 yd | 178 yd |
| PW | 111 mph | 25.0° | 11500 rpm | 135 yd | −0.5 yd | 134 yd |

Air time for the driver is about 5.8 s. Full swings for all 20 clubs land
within −5%…+10% of the independent `Caddy::GetMaxClubDistance` table, which
`Tests/test_pga2005_ballflight.py` checks. Driver totals by difficulty, from
Novice to Expert: 279, 290, 304 and 304 yd.

Putts on a flat green, distance in feet:

| Green | Power 1 | 2 | 3 | 4 | 6.4 (100% click, ×0.8) | 8 |
| --- | --- | --- | --- | --- | --- | --- |
| Slow | 1.7 | 6.6 | 14.8 | 26.2 | 67 | 105 |
| Normal | 2.5 | 10.1 | 22.6 | 40.3 | 103 | 161 |
| Fast | 3.3 | 13.1 | 29.4 | 52.2 | 134 | 209 |

The caddie's putter maximum, 1260 in, is 105 ft. With a cup 10 ft away, powers
2.0–2.5 hole out and 3.0 or more lip out over the rim.

## 12. Quirks of the original to preserve

- The `Collide` tangent rotation uses the updated y (§5).
- The `Collide` ω.z impulse sign does not cancel x-slip.
- The wet-scale rolling factor is discontinuous at 1.0. Slow (0.8) is ×1.56;
  Normal is ×1.0.
- `ConsiderTerrain` steps down without a lower bound. Blend materials store
  texture indices as denormal c0/c1 (≈1e-44), so a lie on index 0 of a bunker
  blend launches at near-zero power.
- `StopBall` still moves the ball by that tick's velocity.
- The fast-rim branch in `CupDynamics` reuses the previous normal y.
- Lift divides by |ω × v| unguarded.

## 13. Open questions

- The `LineIntersectsSquare` implementation, and tree, object and wall response
  details.
- The `MouseSwingControlC` power curve (`0x10160b35`, `0x10160967`,
  `0x10160df5`) and its random cap. Risk mapping in `0x101610cd` is only
  summarised.
- The default shot-setup values in `GolfShotC::Straight`/`Draw`/… These are
  initialised at runtime (BSS `0x1043bf70`).
- WindSpeed → mph ranges (the `Wind1` type table is runtime-initialised).
- `.plr` player files are descrambled per `TBFile::Read` call (Utils.dll
  `0x10018430`):
  - single bytes are raw;
  - pairs swap 0x55 bits and are stored in reverse order.

  The name is at offset 3. Fields after `tagGolferBody` appear shifted by +6.
  Under that inference, PGA_TOUR "Tiger Woods" has difficulty byte 0 and ball
  type 1, and Tour_2 has 2 and 0 (low confidence). For human play, the game
  settings difficulty (`+0x162`) overrides the file.
- Runtime confirmation of every number above.

## 14. Reproduction

Run decompilation with the kept project:

```
python3 Tools/analyze_pga2005_ghidra.py --ghidra ~/Desktop/Tools/ghidra_12.1.2/ghidra_12.1.2_PUBLIC \
  --java /opt/homebrew/opt/openjdk@21 --target Library/SourceMedia/pga2005/engine/Executable/Engine.dll \
  --profile physics --resume-project --keep-project --output Library/Research/ghidra-ballflight --procedure 0x101f4e6a ...
```

`--java` takes the JDK home, because the script appends `bin/java`. Pass
several addresses with repeated `--procedure` flags. A full LLVM disassembly was
kept in the ignored `Library/Research/ballflight-work/engine.dis.txt`.

Run the tests with `python3 -m unittest Tests/test_pga2005_ballflight.py`, and
the demo table with `python3 Tools/pga2005_ballflight_reference.py`. Neither
needs the original media.
