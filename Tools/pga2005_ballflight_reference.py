#!/usr/bin/env python3
"""Deterministic reference model of the PGA Tour 2005 ball simulation.

Clean-room reimplementation of the behaviour recovered statically from
Engine.dll (SHA-256 94aa30bb...9728) and described in
docs/research/PGA2005-PHYSICS.md. It is *not* original source: it mirrors
decompiled control flow and constants (labelled with their addresses), and it
was never compared with a running copy of the game.

Units are the original ones: inches, radians, one tick = 1/fps second with
velocities in inches per tick. The game runs ball physics at 60 Hz for human
shots (GolferHumanSwing::Update 0x101a7c93 passes fps=60 to HitBall), so the
default fps is 60. Axes: +Y up, +Z forward for aim angle 0, +X is where a
positive RotateY angle turns +Z (sin a, 0, cos a).

Standard library only. Python doubles stand in for x87 extended precision, so
results agree with the original to ordinary floating-point tolerance, not
bit-for-bit. Stores the original makes to 32-bit floats are mirrored with f32().

Public API:
    simulate_shot(launch, terrain, conditions=..., ...) -> ShotResult
    flat_terrain(surface, height=0.0) -> terrain callback
    PBL_SURFACES: decoded Pebble Beach surface records for tests/fixtures
    full_swing_power(club, difficulty) -> power for a 100% swing
"""
from __future__ import annotations

from dataclasses import dataclass, field
import math
import random
import struct
from typing import Callable, Optional, Sequence

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def f32(value: float) -> float:
    """Round to IEEE single precision, as the original does on float stores."""
    return struct.unpack("<f", struct.pack("<f", value))[0]


def _norm(v):
    return math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])


# ---------------------------------------------------------------------------
# Constants (address: width) - see docs/research/evidence/pga2005-ballflight.json
# ---------------------------------------------------------------------------

REFERENCE_FPS = 60.0                      # 0x102d6598 f32 60.0
GRAVITY_60HZ = 0.1071700006723404         # 0x102d97c8 f64, inches/tick^2 at 60 Hz
BALL_RADIUS = 0.8399999737739563          # 0x102d9758 f64, inches
BALL_RADIUS_SQ = 0.7056000232696533       # 0x102d9760 f64
BALL_MASS = 1.6200000047683716            # 0x102d9768 f64, ounces
BALL_INERTIA = 0.45722880959510803        # 0x102d97f0 f64 = 0.4*m*r^2
TANGENT_MASS = 0.4628571569919586         # 0x102d97d0 f64 = m/3.5
R_OVER_I = 1.8371546268463135             # 0x102d97e8 f64 = r/I
CLUB_SPEED_SCALE = 8.333333015441895      # 0x102d9750 f64
FACE_TANGENT_LOSS = 0.8999999761581421    # 0x102d9770 f64 (ball keeps 1-0.9 of tangential club speed)
PUTT_SPEED_SCALE = 1.7999999523162842     # 0x102d9778 f64
MIN_LAUNCH_FRACTION = 0.4000000059604645  # 0x102d9950 f64
LIE_COMP_TARGET = 0.9599999785423279      # 0x102d98f8 f64
SAND_WOOD_POWER = 0.699999988079071       # 0x102d9870 f64
SAND_IRON_POWER = 1.5                     # 0x102d98b8 f64
SAND_SPIN_BLEND = 0.5                     # 0x1038bb00 f64

# Flying 0x101f5b7d
WIND_MIN_HEIGHT = 18.0                    # 0x102d9858 f64
WIND_FACTOR = 0.6000000238418579          # 0x102d98c8 f64
AERO_K = 0.00047456868924200535           # 0x102d9780 f64 (rho*A/(2m), rho~1.2 kg/m^3)
DRAG = (-0.00034868568764068186,          # 0x102d9788 f64  (s*w term)
        0.01689407043159008,              # 0x102d9790 f64  (w term)
        0.0007809523958712816,            # 0x102d9798 f64  (s term)
        0.22579047083854675)              # 0x102d97a0 f64  (constant)
LIFT = (-0.0006282891263253987,           # 0x102d97a8 f64
        0.040709469467401505,             # 0x102d97b0 f64
        -0.0002010476018767804,           # 0x102d97b8 f64
        0.08473428338766098)              # 0x102d97c0 f64
SPIN_DECAY = 0.003000000026077032         # 0x102d97f8 f64
HEADWIND_SPIN_DECAY = 0.30000001192092896  # 0x102d98d0 f64

# Collide 0x101f3310
GREEN_DENT = 0.800000011920929            # 0x1038bae0 f64
FULL_RESTITUTION_SPEED = 8.0              # 0x1038bae8 f64
RESTITUTION_FALLOFF = 1.75                # 0x1038baf0 f64
FRICTION_SCALE = 0.30000001192092896      # 0x1038baf8 f64
ROUGH_SOFTNESS = 0.6669999957084656       # 0x102d9948 f64
WET_DENT_SLOPE = 1.399999976158142        # 0x102d9868 f64
WET_RESTITUTION_SLOPE = 0.10999999940395355  # 0x102d9860 f64
SPIN_KICK_MIN_WET = 0.699999988079071     # 0x102d98d8 f64
SPIN_KICK_MIN_DISTANCE = 2268.0           # 0x102d98e0 f64 (63 yd)
SPIN_KICK_FORWARD = 0.10000000149011612   # 0x102d98e8 f64
SPIN_KICK_SCALE = 4.0 / FRICTION_SCALE    # 0x102d9940 / 0x1038baf8, cached at 0x10450088

# Rolling 0x101f6112 / 0x101f6742
SLIP_FRICTION = 1.5                       # 0x1038bb08 f64
SLIP_TORQUE = 2.5                         # 0x102d9958 f64
GREEN_BREAK = 0.6000000238418579          # 0x102d98a0 f64
GREEN_ROLL = 0.574999988079071            # 0x102d9898 f64
FAST_GREEN_SLOPE = 1.159999966621399      # 0x102d98a8 f64
SLOW_GREEN_SLOPE = 0.550000011920929      # 0x102d98b0 f64
SNAP_HEIGHT = 1.5                         # 0x102d9800 f64

# Cup 0x101f9966
CUP_RADIUS = 2.0                          # 0x102d9808 f64
CUP_DEPTH = 4.0                           # 0x102d9810 f64
CUP_STEP = 0.125                          # 0x102d9818 f64
CUP_WALL = (0.03999999910593033, 0.30000001192092896)  # 0x102d9820/0x102d9828 (restitution, friction)
CUP_RIM = (0.03999999910593033, 0.6000000238418579)    # 0x102d9830/0x102d9838
CUP_FAST = 3.75                           # 0x102d9840 f64
CUP_LIP_HEIGHT = 0.800000011920929        # 0x102d9848 f64
CUP_SPIN_KEEP = 0.10000000149011612       # 0x102d98c0 f64
CUP_NORMAL_FUDGE_RADIUS = 2.325000047683716  # 0x102d9990 f32 (TerrainData::CupNormalFudge)

MAX_TICKS = 0x800                         # BallCalculate 0x101f2a1b

STATE_DONE, STATE_STOPPED, STATE_FLYING, STATE_SLIPPING, STATE_ROLLING = 0, 1, 2, 4, 8

# Surface flags (TCL surface record +0x28)
FAIRWAY, ROUGH, GREEN, BUNKER, FRINGE = 0x1, 0x2, 0x4, 0x8, 0x10
SHORT_GRASS = 0x1015                      # fairway | green | fringe | tee
WEED = 0x80000000
SECTION_TREE, SECTION_BLEND, SECTION_ALT_BOUNCE = 0x8, 0x80, 0x80000

# Club tables: four f64[45] arrays, index = club (0..44). Sand variants are the
# same arrays at index club+25 (addresses 0x1038b608/770/8d8/ba40).
_SPEED = (0.454135047, 0.454135047, 0.438867057, 0.424762947, 0.396425746, 0.356348923,
          0.338624832, 0.319647861, 0.405253573, 0.381621402, 0.353449088, 0.342224346,
          0.334411347, 0.323632809, 0.311667667, 0.300351044, 0.287740812, 0.299902405,
          0.242010838, 0.210276444, 0.0471, 0.221774779735683, 0.20583204845815,
          0.193020925110132, 0.186473017621145, 0.18049449339207, 0.176508810572687,
          0.172523127753304, 0.169391519823789, 0.164836453744493, 0.160281387665198,
          0.140352973568282, 0.128395925110132, 0.3096, 0.29016, 0.27144, 0.26352, 0.2556,
          0.2448, 0.23544, 0.22536, 0.22032, 0.2196, 0.18144, 0.16344)       # 0x1038b540
_LAUNCH = (0.125260075, 0.148298645, 0.15142215, 0.15806368, 0.175466815, 0.193124225,
           0.21885955, 0.2237952, 0.135684, 0.1511555, 0.16667875, 0.196854, 0.23011625,
           0.270317, 0.3103585, 0.351, 0.41, 0.49, 0.57, 0.63896, 0.0, 0.069813170079772,
           0.104719755119658, 0.139626340159544, 0.17453292519943, 0.209439510239316,
           0.244346095279202, 0.279252680319088, 0.314159265358974, 0.366519142918803,
           0.418879020478632, 0.471238898038461, 0.541052068118233, 0.15965, 0.19982,
           0.23999, 0.28016, 0.32033, 0.36153, 0.4223, 0.5047, 0.5871, 0.67156, 0.74366,
           0.80546)                                                             # 0x1038b6a8
_PITCH = (0.0,) * 33 + (0.1,) * 12                                              # 0x1038b810
_SPIN = (0.8675, 0.8032, 0.864, 0.917, 0.9657, 0.9822, 1.0372, 1.0869, 1.2662, 1.3351,
         1.3958, 1.3071, 1.2624, 1.221, 1.1977, 1.1783, 1.1648, 1.03, 1.05, 0.97) + \
        (1.0,) * 13 + (1.2662, 1.3351, 1.3958, 1.3071, 1.2624, 1.221, 1.1977, 1.1783,
                       1.1648, 1.1358, 1.1283, 1.1454)                         # 0x1038b978
PUTTER = 20
CLUB_NAMES = ("9 Degree Driver", "12 Degree Driver", "2 Wood", "3 Wood", "4 Wood", "5 Wood",
              "6 Wood", "7 Wood", "1 Iron", "2 Iron", "3 Iron", "4 Iron", "5 Iron", "6 Iron",
              "7 Iron", "8 Iron", "9 Iron", "Pitching Wedge", "Sand Wedge", "Lob Wedge",
              "Putter")
# Caddy::GetMaxClubDistance 0x101132c9 (inches; caddie estimate at max power 14)
CADDY_MAX_DISTANCE = (10800, 10800, 10368, 10044, 9432, 8604, 8028, 7632, 9360, 8784, 8136,
                      7776, 7416, 6912, 6408, 5940, 5292, 4752, 3708, 2952, 1260, 4536, 4320,
                      4068, 3888, 3744, 3600, 3420, 3276, 3024, 2736, 2160, 1692, 2268, 2160,
                      2016, 1944, 1872, 1800, 1692, 1620, 1512, 1368, 1080, 828)


def club_table(club: int):
    """(speed, launch angle rad, pitch offset rad, spin factor) for a club index."""
    return _SPEED[club], _LAUNCH[club], _PITCH[club], _SPIN[club]


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class SurfaceRecord:
    """One TCL surface record: c0..c9 (float32) and flags (+0x28)."""
    c: tuple
    flags: int
    name: str = ""


@dataclass(frozen=True)
class Surface:
    """A material: its surface records and the texture-section flags (+0xa)."""
    records: tuple
    section_flags: int = 0
    name: str = ""


@dataclass
class TerrainSample:
    height: float
    normal: tuple          # need not be unit length
    surface: Surface


Terrain = Callable[[float, float], Optional[TerrainSample]]


@dataclass(frozen=True)
class BallCoeffs:
    """CPlayer::GetBallCoeffs 0x10141fb6 -> CBallFlight +0x3ad/+0x3b1/+0x3b5."""
    spin_decay: float
    spin: float
    speed: float


BALL_TYPES = {
    0: BallCoeffs(spin_decay=1.0, spin=f32(0.97), speed=f32(1.02)),   # 0x3f800000 0x3f7851ec 0x3f828f5c
    1: BallCoeffs(spin_decay=f32(0.95), spin=f32(1.05), speed=1.0),   # 0x3f733333 0x3f866666 0x3f800000
    2: BallCoeffs(spin_decay=f32(0.9), spin=f32(1.13), speed=f32(0.99)),  # 0x3f666666 0x3f90a3d7 0x3f7d70a4
}
NEUTRAL_BALL = BallCoeffs(1.0, 1.0, 1.0)

WIND_MPH_TO_IN_PER_TICK = 0.293333         # CGolfBall::SetupBall literal (f32)
WET_SCALE = {1: f32(0.6), 2: f32(0.8), 3: 1.0, 4: f32(1.2), 5: f32(1.4)}      # GREENCOND -> CCourse::GetWetScale
ROUGH_SCALE = {1: f32(1.3), 2: 1.0, 3: f32(0.7)}                               # ROUGHLENGTH Light/Average/Heavy
MAGNET_EFFECT = {0: f32(0.8), 1: f32(0.45), 2: f32(0.05), 3: 0.0}              # CPlayer::GetMagnetEffect 0x1013c1a7
ABILITY_FACTOR = {0: 0.25, 1: f32(0.6), 2: f32(0.9), 3: 1.0}                   # CPlayer::GetAbilityFactor 0x1013bfad
DIFFICULTY_NAMES = ("Novice", "Intermediate", "Advanced", "Expert")             # DifficultyDescription 0x10231ca9


@dataclass
class Conditions:
    """Course condition scalars as read by the flight code (CBallFlight +4/+8/+0xc/+0x10/+0x14)."""
    wet: float = 1.0            # GreenCond scale; >1 firmer/faster
    rough: float = 1.0          # RoughLength scale; 1.3 Light, 0.7 Heavy
    sand: float = 1.0           # sand difficulty (1.0 standard course)
    wind_mph: tuple = (0.0, 0.0)  # (x, z) wind velocity in mph
    magnet: float = 0.0         # CPlayer::GetMagnetEffect(); rough c0 bonus = 0.05*magnet

    @classmethod
    def from_settings(cls, green_cond: int = 3, rough_length: int = 2,
                      difficulty: Optional[int] = None, **kw):
        """Map GREENCOND/ROUGHLENGTH enums to scalars.

        With a difficulty, CGolfBall::SetupBall 0x1013786f softens a wet scale
        above 1: wet - (1 - GetAbilityFactor())*(wet - 1).
        """
        wet = WET_SCALE.get(green_cond, 1.0)
        if difficulty is not None and wet > 1.0:
            ability = ABILITY_FACTOR.get(difficulty, ABILITY_FACTOR[1])
            wet = f32(wet - (1.0 - ability) * f32(wet - 1.0))
        if difficulty is not None and "magnet" not in kw:
            kw["magnet"] = MAGNET_EFFECT.get(difficulty, MAGNET_EFFECT[1])
        return cls(wet=wet, rough=ROUGH_SCALE.get(rough_length, 1.0), **kw)

    def wind_per_tick(self):
        return (f32(f32(self.wind_mph[0]) * f32(WIND_MPH_TO_IN_PER_TICK)),
                f32(f32(self.wind_mph[1]) * f32(WIND_MPH_TO_IN_PER_TICK)))


@dataclass
class Launch:
    """ClubAtImpactS-level launch inputs (see PGA2005-PHYSICS.md section 2).

    power      club+0x2c; CBallFlight+0x40 = f32(1/power). A 100% swing is
               full_swing_power(club, difficulty); putter max is 8.
    path       club+0x18, rad: club head direction RotateY(path) of +Z
    face       club+0x1c, rad: face normal RotateY(face) of +Z
    loft_adjust club+0x24 -> CBallFlight+0x6c, added to the club launch angle
    launch_adjust club+0x20 -> +0x8c, extra pitch (uphill lie), applied after spin
    spin_mult  club+0x40 -> +0x78
    sand_blend club+0x38 -> +0x74, bunker lies only: 0 = bunker tables (index
               club+25), half spin; 1 = normal tables, x1.5 power (x0.7 woods)
    lie_comp   CBallFlight+0x90 (GetTerrainVImpactReducer; 0 for every player class seen)
    aim        CPlayer::AimAngle, rad; heading = RotateY(aim + aim_offset)
    shot_type  0 Full,1 Chip,2 Putt,3 Punch,4 Flop,5 Pitch,6 Pick,7 Blast (CBallFlight+0x281)
    lie_index  sub-terrain record index at the ball (CBallFlight+0x99)
    """
    club: int
    power: float
    path: float = 0.0
    face: float = 0.0
    loft_adjust: float = 0.0
    launch_adjust: float = 0.0
    spin_mult: float = 1.0
    sand_blend: float = 0.0
    lie_comp: float = 0.0
    aim: float = 0.0
    aim_offset: float = 0.0
    shot_type: int = 0
    lie_index: int = 0
    position: tuple = (0.0, 0.0, 0.0)


@dataclass
class ShotResult:
    trajectory: list            # [(tick, x, y, z, state)]
    final_position: tuple
    final_velocity: tuple
    final_spin: tuple
    first_bounce: Optional[tuple]
    first_bounce_tick: Optional[int]
    carry: float                # horizontal inches start -> first ground contact
    total: float                # horizontal inches start -> rest
    roll: float                 # total - carry
    apex: float                 # max height above start, inches
    ticks: int
    holed: bool
    touched_cup: bool
    out_of_world: bool
    next_lie_index: Optional[int]
    launch_velocity: tuple
    launch_spin: tuple
    bounces: int
    end_state: int
    end_surface: Optional[str] = None
    events: list = field(default_factory=list)

    @property
    def carry_yards(self):
        return self.carry / 36.0

    @property
    def total_yards(self):
        return self.total / 36.0

    @property
    def roll_yards(self):
        return self.roll / 36.0


# ---------------------------------------------------------------------------
# Decoded Pebble Beach surfaces (PBL.TCL, via Tools/decode_pga2005_library.py)
# ---------------------------------------------------------------------------

def _rec(name, flags, *c):
    return SurfaceRecord(tuple(f32(v) for v in c), flags, name)


PBL_SURFACES = {
    "fairway": Surface((_rec("Fairway", 0x201, 0.95, 0.95, 0.09, 0.25, 0.7, 0.7, 0.375, 0.3, 60.0, 0.2),),
                       0x8002, "pbl_fairway"),
    "green": Surface((_rec("Green", 0x4, 0.975, 0.975, 0.07, 0.25, 0.7, 0.7, 0.375, 0.2, 36.0, 0.2),),
                     0x2, "pbl_green"),
    "fringe": Surface((_rec("Fringe", 0x210, 0.95, 0.95, 0.07, 0.25, 0.7, 0.7, 0.375, 0.25, 48.0, 0.2),),
                      0x808C1, "pbl_green_fringe"),
    "tee": Surface((_rec("Tee Box", 0x1200, 1.0, 1.0, 0.07, 0.25, 0.7, 0.7, 0.375, 0.25, 36.0, 0.2),),
                   0x80002, "pbl_teebox"),
    "rough": Surface((_rec("Md Rough", 0x202, 0.8, 0.7, 0.06, 0.15, 0.725, 0.725, 0.375, 0.9, 40.0, 0.3),
                      _rec("Lt Rough", 0x202, 0.9, 0.7, 0.06, 0.15, 0.725, 0.725, 0.375, 0.9, 40.0, 0.3),
                      _rec("Dp Rough", 0x202, 0.7, 0.7, 0.06, 0.15, 0.725, 0.725, 0.375, 0.9, 40.0, 0.3)),
                     0x8002, "pbl_rough"),
    "heavy_rough": Surface(tuple(_rec("Dp Rough", 0x80000200, c0, 0.6, 0.0015, 0.1, 0.75, 0.75, 0.375, 5.0,
                                      17.33333, 0.4) for c0 in (0.63, 0.72, 0.54)), 0x8002, "pbl_heavy_rough"),
    "bunker": Surface((_rec("Med Sand", 0x208, 0.5, 0.9, 0.008, 0.05, 0.6, 0.6, 0.375, 1.8, 5.0, 0.3),
                       _rec("Lt. Sand", 0x208, 0.6, 0.93, 0.008, 0.05, 0.6, 0.6, 0.375, 1.8, 5.0, 0.3),
                       _rec("Dp Sand", 0x208, 0.4, 0.6, 0.008, 0.05, 0.6, 0.6, 0.375, 1.8, 5.0, 0.3),
                       _rec("Plug Sand", 0x208, 0.3, 0.5, 0.008, 0.05, 0.6, 0.6, 0.375, 1.8, 5.0, 0.3)),
                      0x2, "pbl_bunker"),
}


def flat_terrain(surface: Surface, height: float = 0.0, slope: tuple = (0.0, 0.0),
                 regions: Sequence = ()) -> Terrain:
    """Planar terrain y = height + sx*x + sz*z.

    `regions` is a sequence of (predicate(x, z) -> bool, Surface) evaluated in
    order before falling back to `surface`.
    """
    sx, sz = slope
    normal = (-sx, 1.0, -sz)

    def sample(x: float, z: float) -> TerrainSample:
        chosen = surface
        for predicate, region_surface in regions:
            if predicate(x, z):
                chosen = region_surface
                break
        return TerrainSample(height + sx * x + sz * z, normal, chosen)
    return sample


def full_swing_power(club: int, difficulty: int = 2, human: bool = True,
                     average_distance: Optional[float] = None) -> float:
    """Power (club+0x2c) of a 100% swing for a ClubCaddie player (static reading).

    Caddy::GetAveragePlayerPower 0x10112529: putter/chips (20..32) use
    GetMaxClubPower (8 putter, 14 otherwise); human players otherwise scale by
    GetAverageDistance()/GetMaxProDistance() (9720). CPlayer::GetAverageDistance
    0x1013bf67: difficulty 0 -> 9612, 1 -> 10116, 2/3 -> 10800 inches.
    """
    max_power = 8.0 if club == PUTTER else 14.0
    if club == PUTTER or 20 < club < 33 or not human:
        return max_power
    if average_distance is None:
        average_distance = {0: 9612.0, 1: 10116.0}.get(difficulty, 10800.0)
    return f32(f32(average_distance) / 9720.0 * max_power)


# ---------------------------------------------------------------------------
# Simulator
# ---------------------------------------------------------------------------


class BallFlight:
    """Mirror of CBallFlight's state machine for one shot."""

    def __init__(self, launch: Launch, terrain: Terrain, conditions: Conditions,
                 ball: BallCoeffs, fps: int, pin: Optional[tuple], rng: random.Random,
                 record_every: int):
        self.launch, self.terrain, self.cond, self.ball = launch, terrain, conditions, ball
        self.fps = int(fps)
        self.k = f32(self.fps) / f32(REFERENCE_FPS)             # +0x325
        self.inv = f32(REFERENCE_FPS) / f32(self.fps)           # +0x2d5
        self.g = self.inv * self.inv * GRAVITY_60HZ             # +0x2dd
        self.pin = pin
        self.rng = rng
        self.record_every = max(1, record_every)
        self.wind = conditions.wind_per_tick()
        self.state = STATE_FLYING
        self.v = [0.0, 0.0, 0.0]
        self.w = [0.0, 0.0, 0.0]
        x0, y0, z0 = (f32(c) for c in launch.position)
        self.start = (x0, y0, z0)
        self.p = [x0, y0, z0]
        self.prev = list(self.p)
        self.ground = y0                                        # +0x2ad
        self.bounces = 0                                        # +0x3a9
        self.speed = 0.0                                        # +0x29d
        self.vn2 = 0.0                                          # +0x2a5
        self.n_eff = [0.0, 1.0, 0.0]                            # +0x285..+0x295
        self.obj_restitution = 0.0                              # +0x2e5
        self.obj_friction = 0.0                                 # +0x2ed
        self.sample: Optional[TerrainSample] = None             # +0xb5 TerrainData / +0x14e
        self.bunker_entry = None                                # +0x375/+0x2b5/+0x2bd
        self.holed = False                                      # +0x94
        self.touched_cup = False                                # +0x376
        self.out_of_world = False                               # +0x60
        self.next_lie = None                                    # +0x99
        self.first_bounce = None
        self.first_bounce_tick = None
        self.tick = 0
        self.events = []

    # -- terrain ------------------------------------------------------------
    def _query(self, x, z):
        sample = self.terrain(x, z)
        if sample is not None and self.pin is not None:
            sample = self._cup_normal_fudge(x, z, sample)
        return sample

    def _cup_normal_fudge(self, x, z, sample):
        """TerrainData::CupNormalFudge 0x101fe0b6 (inside TerrainHeightCPP)."""
        px, py, pz = (f32(c) for c in self.pin)
        if math.hypot(px - f32(x), pz - f32(z)) < CUP_NORMAL_FUDGE_RADIUS:
            normal = (px - f32(x), (py + 4.0) - f32(sample.height), pz - f32(z))
            return TerrainSample(sample.height, normal, sample.surface)
        return sample

    def _unit_normal(self):
        n = self.sample.normal
        length = _norm(n)
        return [n[0] / length, n[1] / length, n[2] / length]

    # -- launch ---------------------------------------------------------------
    def start_ball(self):
        """CBallFlight::BallAtImpact 0x101f26d2 + StartBall 0x101f758b + Impact 0x101f4e6a."""
        heading = -f32(f32(self.launch.aim) + f32(self.launch.aim_offset))   # +0x35d
        self.sin_h, self.cos_h = math.sin(heading), math.cos(heading)        # +0x365 / +0x36d
        self.impact()
        self.p = list(self.start)
        self.ground = self.start[1]
        self.launch_velocity = tuple(self.v)
        self.launch_spin = tuple(self.w)

    def _heading(self, vec):
        x, z = vec[0], vec[2]
        vec[2] = self.cos_h * z + self.sin_h * x
        vec[0] = self.cos_h * x - self.sin_h * z

    @staticmethod
    def consider_terrain(surface: Surface, lie_index: int, rough: float, sand: float, magnet: float):
        """TerrainData::ConsiderTerrain 0x101fd345 / 0x101fd3f3 -> (record, power factor)."""
        index = lie_index
        while True:   # steps down while c0 == 0.0 (no bounds check; 0.7 fallback unreachable)
            record = surface.records[index % len(surface.records)]
            index -= 1
            if record.c[0] != 0.0 or index < -len(surface.records):
                break
        c0 = record.c[0]
        if record.flags & ROUGH:
            factor = ((rough - 1.0) * 0.20000000298023224 + 1.0) * (f32(0.05 * magnet) + c0)
        else:
            factor = c0
        if record.flags & BUNKER:
            factor = ((sand - 1.0) * 0.20000000298023224 + 1.0) * c0
        return record, factor

    def impact(self):
        L = self.launch
        club = L.club
        speed_t, launch_t, pitch_t, spin_t = club_table(club)
        self.sample = self._query(*self.start[::2])
        record, e8 = self.consider_terrain(self.sample.surface, L.lie_index, self.cond.rough,
                                           self.cond.sand, self.cond.magnet)
        flags = record.flags
        if L.shot_type == 5 and flags & ROUGH:                      # Pitch out of rough
            e8 = (1.0 - e8) * 0.5 + e8
        f74 = f32(L.sand_blend)
        if flags & BUNKER and (club < 0x15 or club > 0x20):
            if club < 8:
                e8 = ((SAND_WOOD_POWER - 1.0) * f74 + 1.0) * e8
            else:
                e8 = ((SAND_IRON_POWER - 1.0) * f74 + 1.0) * e8
                speed_t = (speed_t - _SPEED[club + 25]) * f74 + _SPEED[club + 25]
                launch_t = (launch_t - _LAUNCH[club + 25]) * f74 + _LAUNCH[club + 25]
                spin_t = (spin_t - _SPIN[club + 25]) * f74 + _SPIN[club + 25]
                pitch_t = (pitch_t - _PITCH[club + 25]) * f74 + _PITCH[club + 25]
        if e8 < LIE_COMP_TARGET:
            e8 = (LIE_COMP_TARGET - e8) * f32(L.lie_comp) + e8
        f40 = f32(1.0 / f32(L.power))                               # club+0x28 = 1/club+0x2c
        scale = (speed_t * CLUB_SPEED_SCALE * self.inv) / f40
        path = f32(L.path)
        direction = (f32(math.sin(path)), 0.0, f32(math.cos(path)))     # CVector3::RotateY (Utils.dll)
        face = f32(L.face)
        face_n = (f32(math.sin(face)), 0.0, f32(math.cos(face)))
        sb = f32(self.ball.speed)
        v = [direction[i] * scale * sb for i in range(3)]
        if club == PUTTER:
            vx, vz = v[0], v[2]
            v[0] = vx * self.cos_h - vz * self.sin_h
            v[2] = vz * self.cos_h + vx * self.sin_h
            n = self._unit_normal()                                 # NormalizeCoefficient 0x101fd4bc
            d = v[0] * n[0] + v[1] * n[1] + v[2] * n[2]
            self.v = [(v[i] - d * n[i]) * PUTT_SPEED_SCALE for i in range(3)]
            self.w = [0.0, 0.0, 0.0]
            self.state = STATE_SLIPPING
            return
        angle = f32(L.loft_adjust) + launch_t
        floor = f32(launch_t * MIN_LAUNCH_FRACTION)
        if floor > angle:
            angle = floor
        sa, ca = math.sin(angle), math.cos(angle)
        n = (face_n[0], face_n[1] * ca + face_n[2] * sa, face_n[2] * ca - face_n[1] * sa)
        dot = v[0] * n[0] + v[1] * n[1] + v[2] * n[2]
        vn = [n[i] * dot for i in range(3)]
        vt = [v[i] - vn[i] for i in range(3)]
        keep = 1.0 - FACE_TANGENT_LOSS
        vtk = [vt[i] * keep for i in range(3)]
        self.v = [(vn[i] + vtk[i]) * e8 for i in range(3)]
        s = (record.c[1] * spin_t) / BALL_RADIUS
        if flags & BUNKER:
            if club < 0x14:
                s = (1.0 - (f32(1.0) - f74) * (1.0 - SAND_SPIN_BLEND)) * s
            elif club > 0x14:
                s = s * SAND_SPIN_BLEND
        if flags & ROUGH:
            s = f32(self.cond.rough) * s
        tt = [vt[i] - vtk[i] for i in range(3)]
        scale_w = s * f32(self.ball.spin) * f32(L.spin_mult)
        self.w = [(tt[1] * n[2] - tt[2] * n[1]) * scale_w,
                  (tt[2] * n[0] - tt[0] * n[2]) * scale_w,
                  (tt[0] * n[1] - tt[1] * n[0]) * scale_w]
        pitch = f32(L.launch_adjust) + pitch_t
        sp, cp = math.sin(pitch), math.cos(pitch)
        vy, vz = self.v[1], self.v[2]
        self.v[1] = cp * vy + sp * vz
        self.v[2] = cp * vz - sp * vy
        self._heading(self.v)
        self._heading(self.w)
        self.state = STATE_FLYING

    # -- per-tick motion -------------------------------------------------------
    def flying(self):
        """CBallFlight::Flying 0x101f5b7d."""
        if self.p[1] - self.ground > WIND_MIN_HEIGHT:
            wx, wz = self.wind
        else:
            wx = wz = 0.0
        v, w, k = self.v, self.w, self.k
        r = (v[0] - wx * WIND_FACTOR * self.inv, v[1] - WIND_FACTOR * 0.0 * self.inv,
             v[2] - wz * WIND_FACTOR * self.inv)
        sp2 = r[0] * r[0] + r[1] * r[1] + r[2] * r[2]
        s = math.sqrt(sp2)
        spin = _norm(w)
        cd = ((DRAG[0] * s * k + DRAG[1]) * spin * k + DRAG[2] * s * k + DRAG[3]) * AERO_K
        drag = -(cd * sp2) / s if s > 0.0 else 0.0
        cl = ((LIFT[0] * s * k + LIFT[1]) * spin * k + LIFT[2] * s * k + LIFT[3]) * AERO_K
        c = (r[2] * w[1] - r[1] * w[2], r[0] * w[2] - r[2] * w[0], r[1] * w[0] - r[0] * w[1])
        cn = _norm(c)
        # The original divides by |w x v| unguarded; zero spin would give NaN.
        lift = (cl * sp2) / cn if cn > 0.0 else 0.0
        v[0] = r[0] * drag + c[0] * lift + v[0]
        v[1] = (r[1] * drag + c[1] * lift) - self.g + v[1]
        v[2] = r[2] * drag + c[2] * lift + v[2]
        dot = wz * v[2] + wx * v[0]
        extra = 0.0
        if dot < 0.0:
            vm2 = v[0] * v[0] + v[1] * v[1] + v[2] * v[2]
            a, b = (dot * v[0]) / vm2, (dot * v[2]) / vm2
            extra = math.sqrt(a * a + b * b) * HEADWIND_SPIN_DECAY
        decay = 1.0 - (1.0 + extra) * SPIN_DECAY * self.inv * f32(self.ball.spin_decay)
        for i in range(3):
            w[i] *= decay

    def rolling_and_slipping(self):
        """CBallFlight::RollingAndSlipping 0x101f6112 (putts start here)."""
        rec = self.sample.surface.records[0]
        c4, c5, fl = rec.c[4], rec.c[5], rec.flags
        n = self._unit_normal()
        f = 1.0 - c4                      # x87 results are stored as doubles here
        if fl & ROUGH:
            f = (2.0 - f32(self.cond.rough)) * f
        elif fl & SHORT_GRASS:
            f = (2.0 - f32(self.cond.wet)) * f
        g = self.g
        gn = -g * n[1]
        d1, d2, d3 = gn * n[0] * f, (-g - gn * n[1]) * f, gn * n[2] * f
        v, w = self.v, self.w
        d = v[0] * n[0] + v[1] * n[1] + v[2] * n[2]
        t = [v[i] - d * n[i] for i in range(3)]
        tl = _norm(t)
        t = [t[i] / tl for i in range(3)] if tl > 0.0 else [0.0, 0.0, 0.0]
        sp = _norm(v)
        for i in range(3):
            v[i] = t[i] * sp
        friction = -g * n[1] * c5 * SLIP_FRICTION
        if fl & ROUGH:
            friction = (2.0 - f32(self.cond.rough)) * friction
        elif fl & SHORT_GRASS:
            friction = (2.0 - f32(self.cond.wet)) * friction
        dw = (friction * SLIP_TORQUE) / BALL_RADIUS
        v[0] = -d1 + v[0]
        v[1] = d2 + v[1]
        v[2] = -d3 + v[2]
        w[0] = (t[1] * n[2] - t[2] * n[1]) * dw + w[0]
        w[1] = (t[2] * n[0] - t[0] * n[2]) * dw + w[1]
        w[2] = (t[0] * n[1] - t[1] * n[0]) * dw + w[2]
        if _norm(v) <= _norm(w) * BALL_RADIUS:
            self.state = STATE_ROLLING

    def pure_rolling(self):
        """CBallFlight::PureRolling 0x101f6742."""
        rec = self.sample.surface.records[0]
        c6, c7, fl = rec.c[6], rec.c[7], rec.flags
        n = self._unit_normal()
        v, g = self.v, self.g
        d = v[0] * n[0] + v[1] * n[1] + v[2] * n[2]
        t = [v[i] - d * n[i] for i in range(3)]
        tl = _norm(t)
        t = [t[i] / tl for i in range(3)] if tl > 0.0 else [0.0, 0.0, 0.0]
        sp = _norm(v)
        for i in range(3):
            v[i] = t[i] * sp
        rx, ry, rz = (-BALL_RADIUS * n[0], -BALL_RADIUS * n[1], -BALL_RADIUS * n[2])
        a = -g * rz * BALL_MASS
        b = rx * g * BALL_MASS
        m = math.sqrt(a * a + b * b)
        if m != 0.0:
            proj = abs(b * t[2] + a * t[0])
            a, b = a * (proj / m), b * (proj / m)
            turn = math.sqrt(a * a + b * b) * c6
            if fl & GREEN:
                turn *= GREEN_BREAK
            w = [(rz * v[1] - ry * v[2]) / BALL_RADIUS_SQ,
                 (rx * v[2] - rz * v[0]) / BALL_RADIUS_SQ,
                 (ry * v[0] - rx * v[1]) / BALL_RADIUS_SQ]
            wl = _norm(w)
            if wl > 0.0:
                turn = turn / (wl * BALL_INERTIA)
                u = [b * w[1], a * w[2] - b * w[0], -(a * w[1])]
                flip = u[1] < 0.0
                if flip:
                    u = [-u[0], -u[1], -u[2]]
                a1 = math.atan2(u[0], u[1])
                s1, c1 = math.sin(a1), math.cos(a1)
                _rot(v, 1, 0, s1, c1)
                a2 = -math.atan2(u[2], u[1] * c1 + u[0] * s1)
                s2, c2 = math.sin(a2), math.cos(a2)
                _rot(v, 2, 1, s2, c2)
                if not flip:
                    turn = -turn
                _rot(v, 2, 0, math.sin(turn), math.cos(turn))
                _rot(v, 2, 1, math.sin(-a2), math.cos(-a2))
                _rot(v, 1, 0, math.sin(-a1), math.cos(-a1))
        acc = -((t[1] * g * 5.0) / 7.0)
        for i in range(3):
            v[i] = t[i] * acc + v[i]
        resist = ((g * n[1] * 5.0) / 7.0) * c7
        if fl & GREEN:
            resist *= GREEN_ROLL
        if fl & SHORT_GRASS:
            wet = f32(self.cond.wet)
            if wet > 1.0:
                resist = (-((wet - 1.0) * FAST_GREEN_SLOPE + 1.0) + 2.0) * resist
            elif wet == 1.0:
                resist = (-wet + 2.0) * resist
            else:                         # discontinuous at 1.0 in the original
                resist = (-wet * SLOW_GREEN_SLOPE + 2.0) * resist
        if fl & ROUGH:
            resist = (-f32(self.cond.rough) + 2.0) * resist
        if resist <= _norm(v):
            for i in range(3):
                v[i] = t[i] * -resist + v[i]
        else:
            self.stop_ball()
        self.w = [(-v[2] * ry) / BALL_RADIUS_SQ, 0.0, (ry * v[0]) / BALL_RADIUS_SQ]

    # -- collisions ------------------------------------------------------------
    def collide(self, normal, terrain_contact: bool = True):
        """CBallFlight::Collide 0x101f3310. terrain_contact=False is the object path (cup)."""
        surface = self.sample.surface
        alt = bool(surface.section_flags & SECTION_ALT_BOUNCE)
        index = 1 if alt and len(surface.records) > 1 else 0
        rec = surface.records[index]
        c, fl = rec.c, rec.flags
        short = (fl & SHORT_GRASS) != 0
        wet, rough = f32(self.cond.wet), f32(self.cond.rough)
        if surface.section_flags & SECTION_TREE:
            self.events.append(("tree", tuple(self.p)))   # TreeCollide 0x101f2b24: not modelled
            return
        self.bounces += 1
        v, w, k = self.v, self.w, self.k
        n = self.n_eff
        if terrain_contact:
            nl = _norm(normal)
            n[:] = [normal[0] / nl, normal[1] / nl, normal[2] / nl]
            self.speed = _norm(v)
            vn = v[0] * n[0] + v[1] * n[1] + v[2] * n[2]
            self.vn2 = (vn * n[2]) ** 2 + (vn * n[1]) ** 2 + (vn * n[0]) ** 2
            d = [-(v[i] / self.speed + n[i]) for i in range(3)]
            dent = (abs(vn) / c[8]) * k
            if fl & GREEN:
                dent *= GREEN_DENT
            if fl & FRINGE:
                dent *= GREEN_DENT
            if fl & ROUGH:
                dent = (2.0 - rough) * dent
            if short:
                dent = (2.0 - ((wet - 1.0) * WET_DENT_SLOPE + 1.0)) * dent
            soft = c[9]
            if fl & ROUGH:
                soft *= ROUGH_SOFTNESS
            if fl & WEED:
                soft *= 0.5
            if (fl & FAIRWAY or fl & GREEN) and self.bounces > 1:
                soft *= 0.75 if self.bounces == 2 else 0.5
            dent += soft
            dl = _norm(d)
            if dent <= dl:
                n[:] = [(dent / dl) * d[i] + n[i] for i in range(3)]
            else:
                n[:] = [-v[0], -v[1], -v[2]]
            nl = _norm(n)
            n[:] = [n[0] / nl, n[1] / nl, n[2] / nl]
            self.speed *= k
        obj = not terrain_contact
        r = [-BALL_RADIUS * n[0], -BALL_RADIUS * n[1], -BALL_RADIUS * n[2]]
        vc = [(r[2] * w[1] - r[1] * w[2]) + v[0],
              (r[0] * w[2] - r[2] * w[0]) + v[1],
              (r[1] * w[0] - r[0] * w[1]) + v[2]]
        vcn = vc[0] * n[0] + vc[1] * n[1] + vc[2] * n[2]
        vct = [vc[i] - vcn * n[i] for i in range(3)]
        lt = _norm(vct)
        t = [vct[i] / lt for i in range(3)] if lt >= 1e-10 else [0.0, 0.0, 1.0]
        a1 = math.atan2(n[0], n[1])
        s1, c1 = math.sin(a1), math.cos(a1)
        n1y = c1 * n[1] + s1 * n[0]
        t1 = [t[0] * c1 - t[1] * s1, t[1] * c1 + t[0] * s1, t[2]]
        _rot(v, 1, 0, s1, c1)
        _rot(w, 1, 0, s1, c1)
        a2 = -math.atan2(n[2], n1y)
        s2, c2 = math.sin(a2), math.cos(a2)
        t2y = t1[1] * c2 - t1[2] * s2
        t2z = t1[2] * c2 + t2y * s2              # original uses the already-rotated y here
        _rot(v, 2, 1, s2, c2)
        _rot(w, 2, 1, s2, c2)
        if v[1] < 0.0:
            a3 = math.atan2(t1[0], t2z)
            s3, c3 = math.sin(a3), math.cos(a3)
            _rot(v, 2, 0, s3, c3)
            _rot(w, 2, 0, s3, c3)
            jx = (BALL_RADIUS * w[2] + v[0]) * TANGENT_MASS
            if obj:
                e = 1.0 + self.obj_restitution
            else:
                if self.speed <= FULL_RESTITUTION_SPEED:
                    fall = 1.0
                elif fl & GREEN:
                    fall = 1.0 - ((self.speed - FULL_RESTITUTION_SPEED) / (c[8] / GREEN_DENT)) * RESTITUTION_FALLOFF
                else:
                    fall = 1.0 - ((self.speed - FULL_RESTITUTION_SPEED) / c[8]) * RESTITUTION_FALLOFF
                c2v = c[2]
                if fl & FAIRWAY:
                    c2v = f32(c2v * f32(0.9))
                e = c2v * fall + 1.0
                if short:
                    e = ((wet - 1.0) * WET_RESTITUTION_SLOPE + 1.0) * e
            jn = e * v[1] * BALL_MASS
            jz = (v[2] - BALL_RADIUS * w[0]) * TANGENT_MASS
            jt = math.sqrt(jz * jz + jx * jx)
            if obj:
                limit = abs(jn) * self.obj_friction
            else:
                limit = abs(jn) * c[3] * FRICTION_SCALE
                if short:
                    limit = wet * limit
            if limit < jt:
                if obj:
                    coef = self.obj_friction
                else:
                    coef = c[3] * FRICTION_SCALE
                    if short:
                        coef = wet * coef
                fac = abs((coef * jn) / jt)
                jx *= fac
                jz *= fac
            v[0] = v[0] - jx / BALL_MASS
            v[1] = v[1] - jn / BALL_MASS
            v[2] = v[2] - jz / BALL_MASS
            w[0] = jz * R_OVER_I + w[0]
            w[2] = jx * R_OVER_I + w[2]
            if not obj:
                damp = 1.0
                if fl & ROUGH and not alt:
                    damp = 0.800000011920929
                if alt:
                    damp = 0.8999999761581421
                if fl & WEED:
                    damp = 0.6000000238418579
                if fl & FAIRWAY:
                    damp = 0.9700000286102295
                if fl & GREEN:
                    damp = 0.9700000286102295
                for i in range(3):
                    v[i] *= damp
                    w[i] *= damp
            if v[1] * k < 0.5 and math.sqrt(v[2] * v[2] + v[0] * v[0]) * k < 1.0:
                if not obj and self.bounces < 6 and short and wet > SPIN_KICK_MIN_WET:
                    dx, dz = self.p[0] - self.start[0], self.p[2] - self.start[2]
                    if math.sqrt(dz * dz + dx * dx) > SPIN_KICK_MIN_DISTANCE:
                        kick = c[3] * FRICTION_SCALE * SPIN_KICK_SCALE
                        if (-BALL_RADIUS * (v[0] * w[2])) + ((-w[0] * v[2]) * -BALL_RADIUS) >= 0.0:
                            kick *= SPIN_KICK_FORWARD
                        v[0] = v[0] - (-w[2] * -BALL_RADIUS) * kick
                        v[2] = v[2] - (-BALL_RADIUS * w[0]) * kick
                        self.events.append(("spin_kick", self.bounces, kick))
                self.state = STATE_ROLLING
            _rot(v, 2, 0, math.sin(-a3), math.cos(-a3))
            _rot(w, 2, 0, math.sin(-a3), math.cos(-a3))
        _rot(v, 2, 1, math.sin(-a2), math.cos(-a2))
        _rot(w, 2, 1, math.sin(-a2), math.cos(-a2))
        _rot(v, 1, 0, math.sin(-a1), math.cos(-a1))
        _rot(w, 1, 0, math.sin(-a1), math.cos(-a1))

    def stop_ball(self):
        """CBallFlight::StopBall 0x101f769c: state 1 and next lie (sub-terrain) index."""
        self.state = STATE_STOPPED
        surface = self.sample.surface if self.sample else None
        if surface is None:
            return
        fl = surface.records[0].flags
        if fl & BUNKER:
            entry = self.bunker_entry
            if (entry is None or abs(self.p[0] - entry[1][0]) >= 6.0 or abs(self.ground - entry[1][1]) >= 6.0
                    or abs(self.p[2] - entry[1][2]) >= 6.0 or entry[0] < 10.0):
                self.next_lie = 1
            elif entry[0] < 12.0 or self.rng.random() <= 0.8999999761581421:
                self.next_lie = 0 if self.rng.random() >= 0.10000000149011612 else 2
            elif (entry[0] >= 14.0 and self.rng.random() > 0.8999999761581421) or \
                    self.rng.random() < 0.10000000149011612:
                self.next_lie = 3
            else:
                self.next_lie = 2
        if fl & ROUGH:
            if surface.section_flags & SECTION_BLEND:
                self.next_lie = 1
            elif self.rng.randrange(2) < 1:
                self.next_lie = self.rng.randrange(len(surface.records))
            else:
                self.next_lie = 0

    # -- loop ------------------------------------------------------------------
    def update_pos(self) -> bool:
        """CBallFlight::BallLoopUpdatePos 0x101f8696."""
        if self.state == STATE_FLYING:
            self.flying()
        elif self.state == STATE_SLIPPING:
            self.rolling_and_slipping()
        elif self.state == STATE_ROLLING:
            self.pure_rolling()
        else:
            self.state = STATE_DONE
            return False
        self.prev = list(self.p)
        for i in range(3):
            self.p[i] += self.v[i]
        return True

    def terrain_height(self) -> bool:
        """CBallFlight::BallLoopTerrainHeight 0x101f7ccb (single query model)."""
        sample = self._query(self.p[0], self.p[2])
        if sample is None:
            self.stop_ball()
            self.out_of_world = True
            return False
        if self.state == STATE_FLYING and f32(sample.height) + 1.0 <= f32(self.p[1]):
            self.ground = f32(sample.height)    # quick-height path: no collision tests
            return True
        self.sample = sample
        self.ground = sample.height
        return False

    def test_terrain_collisions(self, high: bool):
        """CBallFlight::BallLoopTestTerrainCollisions 0x101f8d87 (no steep-wall segment test)."""
        if high:
            return
        if self.state == STATE_FLYING:
            if self.ground < self.p[1]:
                return
            self.p[1] = self.ground
            if self.first_bounce is None:
                self.first_bounce = tuple(self.p)
                self.first_bounce_tick = self.tick
            self.collide(self.sample.normal, True)
            rec = self.sample.surface.records[0]
            if rec.flags & BUNKER and self.bunker_entry is None:
                self.bunker_entry = (math.sqrt(self.vn2), (self.p[0], self.ground, self.p[2]))
        elif self.p[1] - self.ground < SNAP_HEIGHT:
            self.p[1] = self.ground
        else:
            self.state = STATE_FLYING

    def cup_dynamics(self) -> bool:
        """CBallFlight::CupDynamics 0x101f9966."""
        cx, cy, cz = (f32(c) for c in self.pin)
        state0 = self.state
        x0, y0, z0 = self.prev
        x1, z1 = self.p[0], self.p[2]
        half = CUP_RADIUS + 0.5
        if not _segment_hits_square(f32(x0), f32(z0), f32(x1), f32(z1), cx - half, cz - half, cx + half, cz + half):
            return False
        if state0 & STATE_FLYING and not f32(self.p[1]) < cy:
            return False
        dx, dz = x1 - x0, z1 - z0
        a = math.atan2(dx, dz)
        s, c = math.sin(a), math.cos(a)
        length = dz * c + dx * s
        dxc = f32(cx - f32(x0))                 # float subtraction in the original
        lat = dxc * c - (cz - z0) * s
        along = (cz - z0) * c + dxc * s
        if not abs(lat) < CUP_RADIUS:
            return False
        h = math.sqrt(CUP_RADIUS * CUP_RADIUS - lat * lat)
        enter, exit_ = along - h, along + h
        if not (enter < length and exit_ > 0.0):
            return False
        self.touched_cup = True
        if self.state & (STATE_SLIPPING | STATE_ROLLING):
            hi = exit_ if exit_ < length else length
            lo = enter if enter > 0.0 else 0.0
            drop = ((hi - lo) / length) * self.g
            self.v[1] -= drop
            self.p[1] = -(drop - self.p[1])
            self.state = STATE_FLYING
            if length + BALL_RADIUS < exit_:
                return True
        y1 = self.p[1]
        span = math.sqrt((y1 - y0) ** 2 + length * length)
        t = 0.0
        horiz = 0.0
        while True:
            while True:
                t += CUP_STEP
                yy = ((y1 - y0) / span) * t + y0
                ww = (length / span) * t
                if f32(yy) < cy:
                    break
                if along <= ww:
                    return True
            if f32(yy) <= cy - f32(CUP_DEPTH):
                self.holed = True
                self.events.append(("holed", (self.p[0], yy, self.p[2])))
                self.stop_ball()
                return True
            dist = math.sqrt(lat * lat + (along - ww) ** 2)
            if CUP_RADIUS <= dist and (not state0 & (STATE_SLIPPING | STATE_ROLLING) or enter < ww):
                return False
            dyc = (yy + BALL_RADIUS) - cy
            if dyc >= 0.0:
                if length * self.k < CUP_FAST or CUP_LIP_HEIGHT <= dyc:
                    self.n_eff[1] = dyc
                    horiz = math.sqrt(max(0.0, BALL_RADIUS_SQ - dyc * dyc))
                else:
                    horiz = CUP_LIP_HEIGHT      # normal y keeps its previous value (original quirk)
            else:
                self.n_eff[1] = 0.0
                horiz = BALL_RADIUS
            if CUP_RADIUS - dist < horiz and exit_ - length <= length - enter:
                n = self.n_eff
                n[0] = (lat / dist) * horiz
                n[2] = ((along - ww) / dist) * horiz
                nl = _norm(n)
                n[:] = [n[0] / nl, n[1] / nl, n[2] / nl]
                sb, cb = math.sin(-a), math.cos(-a)
                nx, nz = n[0], n[2]
                n[2] = cb * nz + sb * nx
                n[0] = cb * nx - sb * nz
                back = (CUP_RADIUS - horiz) - CUP_STEP
                u = -((lat / dist) * back) + lat
                q = -(((ww - along) / dist) * back + along) + ww
                self.p[0] = (u * cb - q * sb) + x0
                self.p[2] = q * cb + u * sb + z0
                self.p[1] = yy
                self.obj_restitution, self.obj_friction = CUP_WALL if n[1] == 0.0 else CUP_RIM
                self.events.append(("cup_wall" if n[1] == 0.0 else "cup_rim", tuple(self.p)))
                self.collide(None, False)
                for i in range(3):
                    self.w[i] *= CUP_SPIN_KEEP
                return True
            if not ww < length:
                return True

    def ball_loop(self) -> bool:
        """CBallFlight::BallLoop 0x101f795f."""
        if self.state == STATE_DONE:
            return False
        if not self.update_pos():
            return False
        high = self.terrain_height()
        if self.state == STATE_STOPPED:
            self.ground = self.p[1]
        else:
            # BallLoopTestTreeCollisions / BallLoopTestMiscCollisions: not modelled
            if self.pin is not None and self.cup_dynamics():
                self.ground = -1e10
            else:
                self.test_terrain_collisions(high)
        return self.state != STATE_DONE


def _rot(vec, a: int, b: int, s: float, c: float):
    """The original's 2-D rotation idiom: vec[a] = c*a + s*b; vec[b] = c*b - s*a_old."""
    old = vec[a]
    vec[a] = c * vec[a] + s * vec[b]
    vec[b] = c * vec[b] - s * old


def _segment_hits_square(x0, z0, x1, z1, minx, minz, maxx, maxz) -> bool:
    """Stand-in for LineIntersectsSquare (not decompiled): 2-D segment vs. box."""
    t0, t1 = 0.0, 1.0
    for p, d, lo, hi in ((x0, x1 - x0, minx, maxx), (z0, z1 - z0, minz, maxz)):
        if d == 0.0:
            if p < lo or p > hi:
                return False
            continue
        ta, tb = (lo - p) / d, (hi - p) / d
        if ta > tb:
            ta, tb = tb, ta
        t0, t1 = max(t0, ta), min(t1, tb)
        if t0 > t1:
            return False
    return True


def simulate_shot(launch: Launch, terrain: Terrain, conditions: Optional[Conditions] = None,
                  ball: BallCoeffs = NEUTRAL_BALL, fps: int = 60, pin: Optional[tuple] = None,
                  seed: int = 0, record_every: int = 1, max_ticks: int = MAX_TICKS) -> ShotResult:
    """Run one shot from impact to rest (or MAX_TICKS) and summarise it."""
    conditions = conditions or Conditions()
    flight = BallFlight(launch, terrain, conditions, ball, fps, pin, random.Random(seed), record_every)
    flight.start_ball()
    trajectory = [(0, *flight.p, flight.state)]
    apex = flight.p[1]
    ticks = 0
    while ticks < max_ticks:
        ticks += 1
        flight.tick = ticks
        alive = flight.ball_loop()
        apex = max(apex, flight.p[1])
        if ticks % flight.record_every == 0 or not alive:
            trajectory.append((ticks, *flight.p, flight.state))
        if not alive:
            break
    sx, _, sz = flight.start
    total = math.hypot(flight.p[0] - sx, flight.p[2] - sz)
    if flight.first_bounce is not None:
        carry = math.hypot(flight.first_bounce[0] - sx, flight.first_bounce[2] - sz)
    else:
        carry = total
    end_surface = flight.sample.surface.name if flight.sample else None
    return ShotResult(trajectory=trajectory, final_position=tuple(flight.p),
                      final_velocity=tuple(flight.v), final_spin=tuple(flight.w),
                      first_bounce=flight.first_bounce, first_bounce_tick=flight.first_bounce_tick,
                      carry=carry, total=total,
                      roll=total - carry, apex=apex - flight.start[1], ticks=ticks,
                      holed=flight.holed, touched_cup=flight.touched_cup,
                      out_of_world=flight.out_of_world, next_lie_index=flight.next_lie,
                      launch_velocity=flight.launch_velocity, launch_spin=flight.launch_spin,
                      bounces=flight.bounces, end_state=flight.state, end_surface=end_surface,
                      events=flight.events)


def launch_summary(result: ShotResult, fps: int = 60):
    """Ball speed (mph), vertical launch (deg), spin (rpm) from launch vectors."""
    vx, vy, vz = result.launch_velocity
    speed = math.sqrt(vx * vx + vy * vy + vz * vz) * fps / 17.6
    launch = math.degrees(math.atan2(vy, math.hypot(vx, vz)))
    rpm = _norm(result.launch_spin) * fps * 60.0 / (2.0 * math.pi)
    return speed, launch, rpm


def _demo():
    fairway = flat_terrain(PBL_SURFACES["fairway"])
    green = flat_terrain(PBL_SURFACES["green"])
    print("club                 power  speed mph launch deg  spin rpm  carry yd  roll yd  total yd  air s")
    for club in range(0, 20):
        power = full_swing_power(club, 2)
        result = simulate_shot(Launch(club=club, power=power), fairway, ball=BALL_TYPES[0])
        speed, launch, rpm = launch_summary(result)
        print(f"{CLUB_NAMES[club]:20s} {power:6.3f} {speed:9.1f} {launch:10.2f} {rpm:9.0f} "
              f"{result.carry_yards:9.1f} {result.roll_yards:8.1f} {result.total_yards:9.1f} "
              f"{result.first_bounce_tick / 60.0:6.2f}")
    print("putts on Normal green (wet 1.0): power -> distance ft")
    for power in (1.0, 2.0, 4.0, 6.0, 8.0):
        result = simulate_shot(Launch(club=PUTTER, power=power), green, ball=BALL_TYPES[0])
        print(f"  {power:4.1f} -> {result.total / 12.0:6.1f} ft  ({result.ticks} ticks)")


if __name__ == "__main__":
    _demo()
