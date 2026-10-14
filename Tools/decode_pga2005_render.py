#!/usr/bin/env python3
"""Decode PGA Tour 2005 weather/time render presets into numeric JSON.

Reads the installed ``render1.ini`` .. ``render40.ini`` and writes
``Library/Imported/pga2005/render/presets.json``. The output holds numbers
only (no texture names or comments). Each preset is decoded with the same
reader semantics as ``CGlobalRenderSettings::UpdateFromIni`` (Engine.dll
``0x101e87d0``), starting from the defaults set by
``CGlobalRenderSettings::Init`` (``0x101e6597``).

The module also provides small reference helpers for a native renderer:
``blend`` (``CGlobalRenderSettings::Lerp`` ``0x101ea673``), ``terrain_color``
(``GlobalDiffuseContrastScaleTerrain`` ``0x101e710a``), ``tree_grey``
(``CRVegetation::FillDiffuseBuffers`` ``0x101d2ab4``), ``flare_layout``
(``LensFlare::Draw`` ``0x100be5c6``) and ``rain_drop_count``
(``0x100cd5e5``). The evidence is in docs/research/PGA2005-RENDER-PRESETS.md.
It is static Ghidra decompilation of Engine.dll (SHA-256 ``94aa30bb…9728``),
not original source, and no original code is executed.

Standard library only. ``python3 Tools/decode_pga2005_render.py --help``.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import re
import tempfile

SCHEMA_VERSION = 1
ENGINE_SHA256 = "94aa30bb645ea089fed6e98df0dce38d75c309e4531386cbe33c07f65bd19728"
PRESET_COUNT = 40
PRESETS_PER_ROW = 5  # DAT_10379f74
WEATHER_ROWS = ["clear", "fair", "partly_cloudy", "cloudy", "foggy", "overcast", "light_rain", "heavy_rain"]
TIME_SLOTS = ["sunrise", "morning", "noon", "afternoon", "sunset"]
FLOAT_EPSILON = 1e-5  # FUN_101e77bc ignores |value| <= 1e-5 (keeps the previous value)
CONTRAST_EPSILON = 1e-4  # UpdateFromIni sets the contrast flag when |Scale - 1| > 1e-4
MAX_FOG_PARTICLES = 40  # DefineFogParameters 0x100ad13f clamps the count to 0..40
MAX_FLARE_TEXTURE_INDEX = 40  # texture index = value - 1, clamped to <= 40 (41 slots)
RAIN_DROPS_PER_DENSITY = 10000.0  # FUN_100cd0d4: drops = trunc(m_density * 10000)
# Skydome-local sun point used when [LensFlare] Position is absent (0x101c0739–0x101c0790).
DEFAULT_SUN_POSITION = (74831.2265625, 18868.849609375, 156948.265625)
SEARCH_DIRS = ("install/Executable", "engine/Executable")


# ---------------------------------------------------------------------------
# INI access with the engine's reader semantics
# ---------------------------------------------------------------------------
_NUMBER = re.compile(r"\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)")
_INTEGER = re.compile(r"\s*([+-]?\d+)")


def c_atof(text: str | None) -> float:
    """C ``atof``: parse the longest numeric prefix, 0.0 when there is none."""
    match = _NUMBER.match(text or "")
    return float(match.group(1)) if match else 0.0


def c_atoi(text: str | None) -> int:
    match = _INTEGER.match(text or "")
    return int(match.group(1)) if match else 0


def parse_ini(text: str) -> dict[str, dict[str, str]]:
    """Case-insensitive sections/keys; the first occurrence wins (profile API)."""
    sections: dict[str, dict[str, str]] = {}
    current: dict[str, str] | None = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(";"):
            continue
        if line.startswith("[") and "]" in line:
            current = sections.setdefault(line[1:line.index("]")].strip().lower(), {})
            continue
        if current is None or "=" not in line:
            continue
        key, value = line.split("=", 1)
        current.setdefault(key.strip().lower(), value.strip())
    return sections


class Profile:
    """The four ProfileC readers used by UpdateFromIni (Utils.dll)."""

    def __init__(self, sections: dict[str, dict[str, str]]):
        self.sections = sections

    def raw(self, section: str, key: str) -> str | None:
        return self.sections.get(section.lower(), {}).get(key.lower())

    def has(self, section: str, key: str) -> bool:
        return self.raw(section, key) is not None

    def float(self, section: str, key: str, current: float) -> tuple[float, bool]:
        """FUN_101e77bc: missing or |v| <= 1e-5 keeps ``current``."""
        value = c_atof(self.raw(section, key))
        return (value, True) if abs(value) > FLOAT_EPSILON else (current, False)

    def int(self, section: str, key: str, current: int) -> int:
        """FUN_101e7798: GetInt with the current value as default."""
        raw = self.raw(section, key)
        return current if raw is None else c_atoi(raw)

    def tuple4(self, section: str, key: str) -> list[float] | None:
        """ProfileC::Get4Tuple (Utils 0x10011ed0): comma tokens, 4th defaults to 1.0."""
        raw = self.raw(section, key)
        if raw is None or raw == "0,0,0,0":
            return None
        tokens = [t for t in raw.split(",") if t]
        values = [c_atof(t) for t in tokens[:4]] + [0.0] * (3 - min(3, len(tokens)))
        if len(tokens) < 4:
            values = values[:3] + [1.0]
        return values

    def position(self, section: str, key: str) -> list[float] | None:
        """ProfileC::GetPosition (Utils 0x10011db0): two values mean (x, 0, z)."""
        raw = self.raw(section, key)
        if raw is None or raw == "0,0,0":
            return None
        values = [c_atof(t) for t in [t for t in raw.split(",") if t][:3]]
        if len(values) == 3:
            return values
        values += [0.0] * (2 - len(values))
        return [values[0], 0.0, values[1]]


# ---------------------------------------------------------------------------
# Defaults (CGlobalRenderSettings::Init 0x101e6597) and decoding (UpdateFromIni)
# ---------------------------------------------------------------------------
def init_defaults() -> dict:
    return {
        "sky_type": 0,
        "tree_ambient": 0,
        "global_lighting": {"diffuse": [1.0, 1.0, 1.0, 1.0], "skydome_diffuse": [1.0, 1.0, 1.0, 1.0]},
        "terrain_contrast": {"mid": 0.85, "shift": 0.85, "scale": 1.0, "enabled": False},
        "tree_contrast": {"mid": 0.85, "shift": 0.85, "scale": 1.0, "enabled": False},
        "fog": {
            "enabled": 0, "start": 0.0, "end": 0.0, "color": [180 / 255, 172 / 255, 160 / 255, 1.0],
            "pan_start": 0.0, "pan_end": 0.0, "pan_color": [0.0, 0.0, 0.0, 0.0],
            "hpan_start": 0.0, "hpan_end": 0.0, "hpan_color": [0.0, 0.0, 0.0, 0.0],
            "particles": {
                "count": 0, "width": 3200.0, "height": 900.0, "depth": 3200.0, "clip_radius": 1600.0,
                "fade_radius": 1400.0, "free_radius": 400.0, "void_radius": 280.0,
                "min_particle_radius": 800.0, "max_particle_radius": 1400.0,
                "min_particle_alpha": 0.26, "max_particle_alpha": 0.32,
                "min_illumination": [0.86, 0.86, 0.86, 1.0], "max_illumination": [1.0, 1.0, 1.0, 1.0],
                "unit_mass": 0.68, "fog_floor": 1000.0, "screen_aligned": 0, "use_distance_fog": 1,
                "near_fog_plane": 800.0, "far_fog_plane": 23000.0, "line_tolerance": 0.56,
            },
        },
        "shadow_map": {"rotation": 0.0, "height_scale": 1.0, "center_uv": [0.5, 1.0], "clamp_value": 0.5, "shadow_id": 0},
        "bump_scale": 1.0,
        "lens_flare": {
            "enabled": 0, "position": None, "texture_count": 0, "flare_opacity": 0.2, "sun_opacity": 1.0,
            "corona_opacity": 1.0, "sun_size": 1.0, "sun_texture": None, "flares": [], "coronas": [],
        },
        "rain": {"on": 0},
        "skydome_animation": {"delta_u": 0.0, "delta_v": 0.0},
        "flag": {"ambient_shaft": [1.0, 1.0, 1.0, 0.32], "ambient_flag": [1.0, 1.0, 1.0, 0.56]},
        "golfer_light0": None,
    }


def _texture_index(value: int) -> int:
    """value - 1 clamped above at 40; there is no lower clamp in the engine."""
    return min(value - 1, MAX_FLARE_TEXTURE_INDEX)


def decode_preset(text: str) -> dict:
    """Return the settings one renderN.ini produces on a freshly Init()ed object."""
    p = Profile(parse_ini(text))
    s = init_defaults()
    s["tree_ambient"] = p.int("TreeAmbient", "Value", s["tree_ambient"])
    s["sky_type"] = p.int("SKY", "SKYTYPE", s["sky_type"])
    sm = s["shadow_map"]
    sm["rotation"] = p.float("ShadowMap", "Rotation", sm["rotation"])[0]
    sm["height_scale"] = p.float("ShadowMap", "HeightScale", sm["height_scale"])[0]
    center = p.tuple4("ShadowMap", "CenterUV")  # FUN_101e7805 (2-tuple); first two values
    if center:
        sm["center_uv"] = center[:2]
    sm["clamp_value"] = p.float("ShadowMap", "ClampValue", sm["clamp_value"])[0]
    sm["shadow_id"] = p.int("ShadowMap", "ShadowId", sm["shadow_id"])
    s["bump_scale"] = p.float("BumpMap", "Scale", s["bump_scale"])[0]
    gl = s["global_lighting"]
    gl["diffuse"] = p.tuple4("GlobalLightingValues", "Diffuse") or gl["diffuse"]
    gl["skydome_diffuse"] = p.tuple4("GlobalLightingValues", "SkydomeDiffuse") or gl["skydome_diffuse"]
    for name, section in (("terrain_contrast", "TerrainContrast"), ("tree_contrast", "TreeContrast")):
        c = s[name]
        c["mid"] = p.float(section, "MidValue", c["mid"])[0]
        c["shift"] = p.float(section, "Shift", c["shift"])[0]
        c["scale"], read = p.float(section, "Scale", c["scale"])
        if read and abs(c["scale"] - 1.0) > CONTRAST_EPSILON:
            c["enabled"] = True
    fog = s["fog"]
    fog["start"] = p.float("Fog", "Start", fog["start"])[0]
    fog["end"] = p.float("Fog", "End", fog["end"])[0]
    fog["color"] = p.tuple4("Fog", "Color") or fog["color"]
    for prefix in ("pan", "hpan"):
        key = "Pan" if prefix == "pan" else "HPan"
        value, read = p.float("Fog", key + "Start", fog[prefix + "_start"])
        fog[prefix + "_start"] = value if read else fog["start"]
        value, read = p.float("Fog", key + "End", fog[prefix + "_end"])
        fog[prefix + "_end"] = value if read else fog["end"]
        fog[prefix + "_color"] = p.tuple4("Fog", key + "Color") or list(fog["color"])
    part = fog["particles"]
    part["count"] = p.int("Fog", "gFogNumParticles", 0)  # reset to 0 before the read
    for key, field in (("gFogWidth", "width"), ("gFogHeight", "height"), ("gFogDepth", "depth"),
                       ("gFogClipRadius", "clip_radius"), ("gFogFadeRadius", "fade_radius"),
                       ("gFogFreeRadius", "free_radius"), ("gFogVoidRadius", "void_radius"),
                       ("gFogMinParticleRadius", "min_particle_radius"),
                       ("gFogMaxParticleRadius", "max_particle_radius"),
                       ("gFogMinParticleAlpha", "min_particle_alpha"),
                       ("gFogMaxParticleAlpha", "max_particle_alpha"),
                       ("gFogUnitMass", "unit_mass"), ("gFogFogFloor", "fog_floor"),
                       ("gFogNearFogPlane", "near_fog_plane"), ("gFogFarFogPlane", "far_fog_plane"),
                       ("gFogLineTolerance", "line_tolerance")):
        part[field] = p.float("Fog", key, part[field])[0]
    part["min_illumination"] = p.tuple4("Fog", "gFogMinParticleIllumination") or part["min_illumination"]
    part["max_illumination"] = p.tuple4("Fog", "gFogMaxParticleIllumination") or part["max_illumination"]
    part["screen_aligned"] = 1 if p.int("Fog", "gFogScreenAligned", part["screen_aligned"]) else 0
    part["use_distance_fog"] = 1 if p.int("Fog", "gFogUseDistanceFog", 0) else 0
    part["effective_count"] = max(0, min(MAX_FOG_PARTICLES, part["count"]))
    fog["enabled"] = 1 if p.int("Fog", "Enabled", 0) else 0
    s["rain"]["on"] = 1 if p.int("RainParameters", "on", 0) else 0
    lf = s["lens_flare"]
    lf["enabled"] = 1 if p.int("LensFlare", "Enabled", 0) else 0
    if lf["enabled"]:
        lf["position"] = p.position("LensFlare", "Position")
        lf["texture_count"] = p.int("LensFlare", "TextureCount", 0)
        lf["flare_opacity"] = p.float("LensFlare", "FlareOpacity", lf["flare_opacity"])[0]
        lf["sun_opacity"] = p.float("LensFlare", "SunOpacity", lf["sun_opacity"])[0]
        lf["corona_opacity"] = p.float("LensFlare", "CoronaOpacity", lf["corona_opacity"])[0]
        texture = 0  # the running index variable is shared by every texture read
        for i in range(1, p.int("LensFlare", "FlareCount", 0) + 1):
            size = p.float("LensFlare", f"Flare{i}Size", float("nan"))[0]
            position = p.float("LensFlare", f"Flare{i}Position", float("nan"))[0]
            texture = _texture_index(p.int("LensFlare", f"Flare{i}Texture", texture))
            lf["flares"].append({"size": size, "position": position, "texture": texture})
        lf["sun_texture"] = texture = _texture_index(p.int("LensFlare", "SunTexture", texture))
        lf["sun_size"] = p.float("LensFlare", "SunSize", lf["sun_size"])[0]
        for i in range(1, p.int("LensFlare", "CoronaCount", 0) + 1):
            size = p.float("LensFlare", f"Corona{i}Size", float("nan"))[0]
            texture = _texture_index(p.int("LensFlare", f"Corona{i}Texture", texture))
            lf["coronas"].append({"size": size, "texture": texture})
    flag = s["flag"]
    flag["ambient_shaft"] = p.tuple4("Flag", "ambientColorShaft") or flag["ambient_shaft"]
    flag["ambient_flag"] = p.tuple4("Flag", "ambientColorFlag") or flag["ambient_flag"]
    anim = s["skydome_animation"]
    anim["delta_u"] = p.float("SkydomeAnimationControls", "deltaU", anim["delta_u"])[0]
    anim["delta_v"] = p.float("SkydomeAnimationControls", "deltaV", anim["delta_v"])[0]
    s["rain"].update(decode_rain(p))
    light = [p.tuple4("Golfer Shader Commmon", "Light0Diffuse"), p.tuple4("Golfer Shader Commmon", "Light0Ambient"),
             p.position("Golfer Shader Commmon", "Light0Direction")]
    if all(v is not None for v in light):
        s["golfer_light0"] = {"diffuse": light[0], "ambient": light[1], "maya_angles": light[2]}
    return s


def decode_rain(p: Profile) -> dict:
    """UpdateRainEffectFromIni 0x101e9ddf. ``None`` marks a key the INI lacks.

    The engine reuses one float for every read and skips zero values, so a
    missing key would inherit the previous key's value; that quirk is not
    reproduced here because no installed preset relies on it.
    """
    out: dict = {}
    for key, field in (("m_density", "density"), ("rainDistance", "distance"), ("dropLength", "drop_length"),
                       ("dropSize", "drop_size"), ("dropVelocity", "drop_velocity"), ("rainBottom", "bottom"),
                       ("minDensity", "min_density"), ("maxDensity", "max_density")):
        value, read = p.float("RainParameters", key, float("nan"))
        out[field] = value if read else None
    out["color"] = p.tuple4("RainParameters", "m_color")
    out["target_drops"] = (int(out["density"] * RAIN_DROPS_PER_DENSITY)
                           if out["density"] is not None else None)
    return out


# ---------------------------------------------------------------------------
# Runtime helpers (reference formulas for the native renderer)
# ---------------------------------------------------------------------------
def _lerp(a, b, t):
    if isinstance(a, list):
        return [_lerp(x, y, t) for x, y in zip(a, b)]
    return (b - a) * t + a


# Fields CGlobalRenderSettings::Lerp interpolates; everything listed in
# LOWER_FIELDS is copied from the lower preset; ACTIVE_FIELDS keep whatever the
# active object already held. Paths use "/" separators into decode_preset().
LERP_FIELDS = [
    "global_lighting/diffuse", "global_lighting/skydome_diffuse",
    "terrain_contrast/mid", "terrain_contrast/shift", "terrain_contrast/scale",
    "tree_contrast/mid", "tree_contrast/shift", "tree_contrast/scale",
    "fog/start", "fog/end", "fog/color", "fog/pan_start", "fog/pan_end", "fog/pan_color",
    "fog/hpan_start", "fog/hpan_end", "fog/hpan_color",
    "fog/particles/width", "fog/particles/height", "fog/particles/depth", "fog/particles/clip_radius",
    "fog/particles/fade_radius", "fog/particles/free_radius", "fog/particles/void_radius",
    "fog/particles/min_particle_radius", "fog/particles/max_particle_radius",
    "fog/particles/min_particle_alpha", "fog/particles/max_particle_alpha",
    "fog/particles/min_illumination", "fog/particles/max_illumination",
    "fog/particles/unit_mass", "fog/particles/fog_floor", "fog/particles/near_fog_plane",
    "fog/particles/far_fog_plane", "fog/particles/line_tolerance",
    "shadow_map/rotation", "shadow_map/height_scale", "shadow_map/clamp_value", "bump_scale",
    "lens_flare/flare_opacity", "lens_flare/sun_opacity", "lens_flare/corona_opacity", "lens_flare/sun_size",
    "flag/ambient_shaft", "flag/ambient_flag",
]
LERP_TRUNC_FIELDS = ["tree_ambient", "fog/particles/count"]
LOWER_FIELDS = ["sky_type", "rain", "fog/particles/screen_aligned", "fog/particles/use_distance_fog",
                "lens_flare/enabled"]
ACTIVE_FIELDS = ["terrain_contrast/enabled", "tree_contrast/enabled", "shadow_map/center_uv",
                 "shadow_map/shadow_id", "fog/enabled"]
ZERO_FIELDS = ["skydome_animation/delta_u", "skydome_animation/delta_v"]


def _get(tree: dict, path: str):
    for part in path.split("/"):
        tree = tree[part]
    return tree


def _set(tree: dict, path: str, value) -> None:
    parts = path.split("/")
    for part in parts[:-1]:
        tree = tree[part]
    tree[parts[-1]] = value


def blend(lower: dict, upper: dict, t: float, active: dict | None = None) -> dict:
    """CGlobalRenderSettings::Lerp(lower, upper, t) into ``active``.

    ``active`` defaults to a copy of ``lower`` (its retained fields then match
    the lower preset; the original keeps them from the last full INI load).
    """
    out = copy.deepcopy(active if active is not None else lower)
    for path in LERP_FIELDS:
        _set(out, path, _lerp(_get(lower, path), _get(upper, path), t))
    for path in LERP_TRUNC_FIELDS:
        _set(out, path, int(_lerp(_get(lower, path), _get(upper, path), t)))  # ftol truncates
    for path in LOWER_FIELDS:
        _set(out, path, copy.deepcopy(_get(lower, path)))
    for path in ZERO_FIELDS:
        _set(out, path, 0.0)
    lf, lo, hi = out["lens_flare"], lower["lens_flare"], upper["lens_flare"]
    if lo["enabled"]:  # inner block runs only when the lower preset has the flare enabled
        # The present flag comes from the lower preset; the vector lerps toward
        # the upper object's value, which Init() leaves at (0,0,0) when unread.
        lf["position"] = (None if lo["position"] is None
                          else _lerp(lo["position"], hi["position"] or [0.0, 0.0, 0.0], t))
        # Sizes, textures and counts come from the lower preset; positions lerp
        # slot by slot. Upper slots beyond its FlareCount hold Init() random
        # values in the original (random(500)/100 - 1); this helper keeps the
        # lower position there instead and flags the slot.
        flares = []
        for i, f in enumerate(lo["flares"]):
            g = hi["flares"][i] if i < len(hi["flares"]) else None
            flares.append({"size": f["size"], "texture": f["texture"],
                           "position": _lerp(f["position"], g["position"], t) if g else f["position"],
                           "upper_slot_unset": g is None})
        lf["flares"] = flares
        lf["coronas"] = copy.deepcopy(lo["coronas"])
        lf["sun_texture"], lf["texture_count"] = lo["sun_texture"], lo["texture_count"]
    out["fog"]["particles"]["effective_count"] = max(0, min(MAX_FOG_PARTICLES, out["fog"]["particles"]["count"]))
    return out


def _contrast(value: float, c: dict) -> float:
    return min(1.0, max(0.0, (value - c["mid"]) * c["scale"] + c["shift"]))


def terrain_color(rgb: tuple[int, int, int], settings: dict, *, tree_set: bool = False,
                  contrast_enabled: bool | None = None) -> tuple[int, int, int]:
    """GlobalDiffuseContrastScaleTerrain/Trees applied to a baked TCR vertex colour.

    Returns 0..255 RGB; alpha is forced to 0xff by VBAddPolys_Terrain.
    ``contrast_enabled`` defaults to the settings' own flag.
    """
    c = settings["tree_contrast" if tree_set else "terrain_contrast"]
    enabled = c["enabled"] if contrast_enabled is None else contrast_enabled
    diffuse = settings["global_lighting"]["diffuse"]
    out = []
    for channel, k in zip(rgb, diffuse[:3]):
        v = channel * 0.003921569
        if enabled:
            v = _contrast(v, c)
        out.append(int(v * k * 255.0) & 0xFF)
    return tuple(out)


def tree_grey(byte: int, settings: dict, *, contrast_enabled: bool | None = None) -> tuple[int, int, int]:
    """FillDiffuseBuffers default path: grey = (byte + TreeAmbient) * 2, low 8 bits."""
    grey = ((byte + settings["tree_ambient"]) * 2) & 0xFF
    return terrain_color((grey, grey, grey), settings, tree_set=True, contrast_enabled=contrast_enabled)


def flare_layout(sun: tuple[float, float], screen: tuple[int, int], settings: dict,
                 texture_sizes: dict[int, tuple[int, int]]) -> dict:
    """Screen-space quads (left, top, right, bottom) drawn by LensFlare::Draw."""
    lf = settings["lens_flare"]
    half_w, half_h = screen[0] >> 1, screen[1] >> 1
    dx, dy = half_w - sun[0], half_h - sun[1]
    sun_half = lf["sun_size"] * 8.0  # NextFrame 0x100bf7e5: fixed pixels at the original resolution
    quads = {"sun": (int(sun[0] - sun_half), int(sun[1] - sun_half), int(sun[0] + sun_half), int(sun[1] + sun_half)),
             "flares": []}
    for flare in lf["flares"]:
        w, h = texture_sizes.get(flare["texture"], (0, 0))
        cx, cy = half_w + dx * flare["position"], half_h + dy * flare["position"]
        hw, hh = w * flare["size"] * 0.5, h * flare["size"] * 0.5
        quads["flares"].append((int(cx - hw), int(cy - hh), int(cx + hw), int(cy + hh)))
    return quads


def rain_drop_count(target_drops: int, rain_detail: int, minutes: int) -> int:
    """Active drop count at 0x100cd5e5: varies with whole minutes of tick time."""
    base = int(target_drops * (rain_detail / 4.0))
    bias = 1.0 if target_drops > 6000 else 0.5
    count = int(base * (0.2 * math.cos(minutes * 3.0) + 0.6 * math.sin(minutes) + bias))
    return max(1000, min(10000, count))


# ---------------------------------------------------------------------------
# Files and output
# ---------------------------------------------------------------------------
def find_executable_dir(source: Path) -> Path:
    for sub in SEARCH_DIRS:
        candidate = source / sub
        if (candidate / "render1.ini").is_file():
            return candidate
    if (source / "render1.ini").is_file():
        return source
    raise FileNotFoundError(f"render1.ini not found under {source}")


def decode_all(executable: Path) -> dict:
    presets = []
    for number in range(1, PRESET_COUNT + 1):
        data = (executable / f"render{number}.ini").read_bytes()
        settings = decode_preset(data.decode("latin-1"))
        row, slot = divmod(number - 1, PRESETS_PER_ROW)
        presets.append({"number": number, "weather_row": row, "time_slot": slot,
                        "source_sha256": hashlib.sha256(data).hexdigest(), "settings": settings})
    return {
        "schema_version": SCHEMA_VERSION,
        "engine_sha256": ENGINE_SHA256,
        "weather_rows": WEATHER_ROWS,
        "time_slots": TIME_SLOTS,
        "selection": {
            "weather_row": "min(7, trunc(weatherNormalized * 8))",
            "position": "(timeNormalized * 720 + 20 * (hole - 1)) / 180",
            "lower": "row * 5 + min(trunc(position), 4) + 1",
            "upper": "row * 5 + min(trunc(position) + 1, 4) + 1",
            "blend": "position - trunc(position)",
        },
        "default_sun_position": list(DEFAULT_SUN_POSITION),
        "lerp": {"interpolated": LERP_FIELDS, "interpolated_truncated": LERP_TRUNC_FIELDS,
                 "from_lower": LOWER_FIELDS, "kept_from_active": ACTIVE_FIELDS, "zeroed": ZERO_FIELDS},
        "presets": presets,
    }


def _clean(value):
    """JSON has no NaN; unread per-flare values become null."""
    if isinstance(value, float) and math.isnan(value):
        return None
    if isinstance(value, dict):
        return {k: _clean(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_clean(v) for v in value]
    return value


def write_json(document: dict, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, suffix=".tmp") as stream:
        json.dump(_clean(document), stream, indent=1)
        stream.write("\n")
    os.replace(stream.name, path)
    os.chmod(path, 0o644)


def _fmt(values) -> str:
    return ",".join(f"{v:g}" for v in values)


def markdown_table(document: dict) -> str:
    rows = ["| # | Weather / time | SKY | Fog start–end | Fog colour | Diffuse | Terrain contrast (mid/shift/scale, on) "
            "| Flare | Flare position | Rain |",
            "| ---: | --- | ---: | --- | --- | --- | --- | ---: | --- | ---: |"]
    for preset in document["presets"]:
        s = preset["settings"]
        tc, lf = s["terrain_contrast"], s["lens_flare"]
        label = f"{WEATHER_ROWS[preset['weather_row']]} / {TIME_SLOTS[preset['time_slot']]}"
        rows.append(
            f"| {preset['number']} | {label} | {s['sky_type']} | {s['fog']['start']:g}–{s['fog']['end']:g} "
            f"| {_fmt(s['fog']['color'][:3])} | {_fmt(s['global_lighting']['diffuse'])} "
            f"| {tc['mid']:g}/{tc['shift']:g}/{tc['scale']:g}, {'yes' if tc['enabled'] else 'no'} "
            f"| {lf['enabled']} | {_fmt(lf['position']) if lf['enabled'] and lf['position'] else '–'} "
            f"| {s['rain']['on']} |")
    return "\n".join(rows)


def main(argv: list[str] | None = None) -> int:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source", type=Path, default=root / "Library/SourceMedia/pga2005",
                        help="Extracted media root, or a directory holding render1.ini")
    parser.add_argument("--output", type=Path, default=root / "Library/Imported/pga2005/render/presets.json")
    parser.add_argument("--table", action="store_true", help="Print a Markdown summary table instead of writing JSON")
    args = parser.parse_args(argv)
    document = decode_all(find_executable_dir(args.source))
    if args.table:
        print(markdown_table(document))
        return 0
    write_json(document, args.output)
    print(f"wrote {args.output} ({len(document['presets'])} presets)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
