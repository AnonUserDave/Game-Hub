#!/usr/bin/env python3
"""Decode PGA Tour 2005 presentation scripts and swing-meter constants.

Reads the original situation scripts (``*.stn``) that drive the camera
director, auto-replay and terrain-effect animations, and writes
``cameras.json`` with typed rules. Optionally reads Engine.dll to verify the
recovered tri-click swing-meter constants and writes ``swing.json``.

Everything here is static: no original code runs. Record layouts and field
meanings come from direct Ghidra 12.1.2 decompilation of Engine.dll
(SHA-256 ``94aa30bb…9728``); see ``docs/research/PGA2005-PRESENTATION.md``.

Standard library only. ``python3 Tools/decode_pga2005_cameras.py --help``.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import random
import struct
import tempfile

SCHEMA_VERSION = 1
ENGINE_SHA256 = "94aa30bb645ea089fed6e98df0dce38d75c309e4531386cbe33c07f65bd19728"

# ---------------------------------------------------------------------------
# .stn container (Script::LoadSituationFile 0x10207822)
# ---------------------------------------------------------------------------
HEADER_SIZE = 0x1C
SITUATION_SIZE = 0x5B   # versions 0x10002..0x10005 (Script::LoadSituations 0x10207d65)
SITUATION_SIZE_OLD = 0x56
ACTION_SIZE = 0x57      # versions 0x10003..0x10005 (Script::LoadActions 0x102080bd)
ACTION_SIZE_OLD = 0x42
RESPONSE_SIZE = 0x3F    # all versions (Script::LoadResponses 0x1020b3e4)
EMPTY_SLOT = -16        # 0xfff0 terminates/pads index lists
MAX_CONDITIONS = 10
MAX_SITUATION_ACTIONS = 10
MAX_ACTION_RESPONSES = 30

# Registry keys written by the installer (DATA1.HDR) select each file.
SCRIPT_FILES = {
    "d_camera.stn": ("AutoCamera", "Default dynamic 'TV' camera director (153 situations)"),
    "s_camera.stn": ("SnapCamera", "Snap camera: instant cuts to a few fixed framings"),
    "f_camera.stn": ("FixedCamera", "Fixed camera: one framing chosen per turn, no in-flight changes"),
    "b_camera.stn": ("BallCamera", "Ball camera: chases the ball after impact"),
    "Replay.stn": ("Replay", "Auto-replay triggers (which shots get an instant replay, with chance)"),
    "anim.stn": ("Animation", "Terrain effect animations (sand blast, splash, divot, tee)"),
}

# Situation type byte = SituationEvent category (+0x275), selects the situation list.
SITUATION_TYPES = {1: "shot_effect", 2: "game_event", 3: "ball_effect", 11: "camera"}

# Camera event ids (CameraEvent ctor 0x1021387a callers in ScriptCommand).
CAMERA_EVENTS = {
    0: ("any", "Matches every event (wildcard in the situation record)"),
    1: ("ball_in_flight", "ScriptCommand::ViewLanding 0x10065678; one event per 5% flight-progress step"),
    3: ("ball_impact", "ScriptCommand::ViewBall 0x1006533f; right after the club strikes the ball"),
    19: ("prep_swing", "ScriptCommand::ViewSwing 0x1006500c; golfer's turn / address ('Prep', 'Starting Turn')"),
    21: ("preshot", "ScriptCommand::ViewPreshot 0x10064940"),
    22: ("reaction", "ScriptCommand::ViewPostshot 0x10065a16; golfer reaction after the shot"),
    28: ("start_hole", "ScriptCommand::ViewTee 0x10064b84; first view of a hole"),
    29: ("hole_end", "ScriptCommand::ViewEndOfHole 0x10065f88; after holing out"),
    30: ("other_player", "ScriptCommand::ViewOtherPlayer 0x10065d4f"),
}

# CameraEvent value slots (FUN_102138df, the CameraEvent fill). The event mask is
# 0x77ffffff, so bits 27 and 31 are never available. Values are u32.
TERRAIN_FLAGS = {  # Position terrain flags (docs/research/PGA2005-REA.md)
    0x1: "fairway", 0x2: "rough", 0x4: "green", 0x8: "bunker", 0x10: "fringe",
    0x20: "unplayable", 0x40: "water", 0x80: "out_of_bounds", 0x100: "hazard",
    0x200: "drop_allowed", 0x400: "free_drop", 0x800: "ball_disappears",
    0x1000: "tee_box", 0x2000: "stance_allowed", 0x4000: "in_hole", 0x8000: "on_tee",
    0x10000: "touched_hole", 0x40000: "tournament_structure", 0x80000000: "weed_rough",
}
CLUB_FLAGS = {  # FUN_1021038a, from CPlayer::GetLastClub
    0x1: "driver(0-1)", 0x2: "wood(0-7)", 0x4: "iron_or_wedge(8-44,not20)", 0x8: "club21-32",
    0x10: "putter(20)", 0x20: "short_wedge_group", 0x40: "long_iron_group",
    0x80: "mid_iron_group", 0x100: "short_iron_group",
}
SHOT_FLAGS = {  # FUN_102104f9: shot style at CPlayer+0x78dd plus launch bands
    0x1: "tee_shot", 0x2: "putt(style6)", 0x4: "style7", 0x10: "launch_band_low", 0x20: "launch_band_high",
    0x40: "side_band_a", 0x80: "side_band_b", 0x100: "side_band_c", 0x200: "side_band_d",
    0x400: "full_shot(style0-2)", 0x800: "style3", 0x1000: "style4", 0x2000: "flop(style5)",
    0x4000: "style8", 0x8000: "style9", 0x10000: "launch_band_mid", 0x20000: "launch_band_top",
}
MISS_FLAGS = {0x1: "left", 0x2: "right", 0x4: "short", 0x8: "long"}
MODEL_FLAGS = {0x1: "male", 0x2: "female"}
WIND_FLAGS = {0x1: "x<-0.65", 0x2: "x>0.65", 0x4: "z<-0.65", 0x8: "ideal_z>0.65",
              0x10: "z>0.65", 0x20: "ideal_z<-0.65"}
GAME_FLAGS = {  # FUN_102124e8
    0x1: "more_than_7_players", 0x2: "game_mode_16", 0x4: "season_tournament", 0x8: "tournament_event_type0",
    0x10: "match_play", 0x20: "ai_player", 0x40: "practice", 0x80: "skills_flag",
    0x80000: "front_9", 0x100000: "back_9", 0x200000: "18_holes", 0x400000: "flag_0x800_round",
    0x800000: "one_hole", 0x1000000: "three_holes", 0x2000000: "flag_0x400_round",
    0x4000000: "final_round", 0x8000000: "settings_1d7_or_1d8", 0x10000000: "trait_flag_2e3_clear",
    0x20000000: "game_mode_3_or_6", 0x40000000: "setting_12_is_8",
}
ELEVATION_FLAGS = {0x1: "target_not_below_ball", 0x2: "target_below_ball"}

# bit -> (name, unit/flag table, meaning, confidence)
EVENT_VARIABLES = {
    0: ("club_class", CLUB_FLAGS, "Class flags of the selected club", "high"),
    1: ("shot_type", SHOT_FLAGS, "Tee-shot flag, shot style and launch bands", "medium"),
    2: ("golfer_lie", TERRAIN_FLAGS, "Terrain flags where the golfer stands", "high"),
    3: ("distance_to_pin", "inches", "In flight: predicted landing to pin; otherwise ball to hole", "high"),
    4: ("shot_distance", "inches", "Golfer to ball (or predicted landing)", "medium"),
    5: ("flight_value", "raw", "ftol of a ball-flight float (anim.stn uses it as impact speed)", "low"),
    6: ("player_value_0xdc", "raw", "CPlayer virtual +0xdc", "low"),
    7: ("par", "count", "Hole par", "high"),
    8: ("strokes", "count", "Strokes this hole (par in some modes)", "high"),
    9: ("strokes_minus_par", "count", "Score relative to par this hole", "high"),
    10: ("miss_direction", MISS_FLAGS, "Landing vs target line: left/right and short/long", "high"),
    11: ("lateral_miss", "inches", "|sideways distance| of landing from target line", "medium"),
    12: ("flight_index", "count", "Flight progress in 5% steps (min(20, trunc(progress*20))); starts at 3", "medium"),
    13: ("wind_speed", "raw", "ftol of course wind magnitude", "low"),
    14: ("golfer_model", MODEL_FLAGS, "Golfer model flags (male/female)", "medium"),
    15: ("distance_to_pin_2", "inches", "Second copy of bit 3 for range tests", "high"),
    16: ("wind_direction", WIND_FLAGS, "Wind direction vs aim (thresholds +/-0.65)", "medium"),
    17: ("depth_miss", "inches", "|long/short distance| of landing from the target", "medium"),
    18: ("player_u16_0x15ff", "count", "CPlayer+0x15ff; 0 on the first putt (inferred)", "low"),
    19: ("match_standing", "count", "Match/tournament standing", "low"),
    20: ("ball_sub_terrain", "raw", "Lie index under the ball", "medium"),
    21: ("ball_lie", TERRAIN_FLAGS, "Terrain flags at the ball / predicted landing", "high"),
    22: ("shot_distance_2", "inches", "Copy of bit 4", "high"),
    23: ("elevation_change", "inches", "|target elevation - ball elevation|", "medium"),
    24: ("elevation_sign", ELEVATION_FLAGS, "Sign of the elevation change", "low"),
    25: ("constant_18", "raw", "Always 18", "high"),
    26: ("game_mode", "raw", "Game settings byte +0x13", "medium"),
    28: ("course_id", "raw", "Course identity index", "medium"),
    29: ("game_flags", GAME_FLAGS, "Game/round flags (AI player 0x20, practice 0x40 ...)", "medium"),
    30: ("game_flags_2", GAME_FLAGS, "Copy of bit 29", "high"),
}

# Condition operators (FUN_10215b87). Values compare as unsigned 32-bit.
OPERATORS = {
    0: ("always", "true"),
    1: ("eq", "value == x"),
    2: ("ne", "value != x"),
    3: ("gt", "value > x (unsigned)"),
    4: ("lt", "value < x (unsigned)"),
    5: ("any", "(value & x) != 0"),
    6: ("either_nonzero", "value != 0 or x != 0"),
    7: ("not_all", "(~value & x) != 0  (some bit of x missing)"),
    8: ("none", "(value & x) == 0"),
}

ACTION_TYPES = {1: "sound", 2: "positional_sound", 7: "animation", 10: "camera", 11: "replay",
                12: "link", 0xFF: "library_sound"}
RESPONSE_TYPES = {1: "music", 2: "sound", 8: "course_sound", 9: "animation", 13: "camera", 16: "link"}

# CameraResponse kind byte (CameraResponse::Invoke 0x10219553).
CAMERA_RESPONSE_KINDS = {0: "transition", 1: "default_view", 2: "default_view", 3: "default_view",
                         4: "default_view", 5: "default_view", 6: "default_view", 7: "default_view",
                         8: "default_view", 9: "default_view", 10: "default_view_0", 11: "matrix_cam",
                         12: "green_cam", 13: "helicopter_cam", 14: "shot_target", 15: "green_tower_cam",
                         16: "fairway_tower_cam"}
# CameraTransition type (Camera::StartTransition 0x1018e16d).
CAMERA_COMMANDS = {
    0: ("attach", "Move camera to an object (position source)"),
    1: ("target", "Aim camera at an object (look-at)"),
    2: ("pitch", "Set pitch angle (amount degrees)"),
    3: ("pan", "Set pan angle (amount degrees)"),
    4: ("rotate_x", "Rotate about X (amount degrees)"),
    5: ("rotate_y", "Rotate about Y (amount degrees)"),
    6: ("zoom", "Zoom to amount/100"),
    7: ("tilt", "Tilt (roll) amount degrees"),
    8: ("slow_motion", "Time scale amount/100"),
    9: ("letterbox", "Letterbox amount/100"),
    10: ("hole_flyover", "Fly over the hole"),
    11: ("pause", "Wait duration before the next group"),
    12: ("move_absolute", "Move to absolute xyz"),
    13: ("zoom_ball_cup", "Zoom so ball and cup both fit"),
    14: ("attachment_offset", "Set offset from the attached object"),
    15: ("target_offset", "Set offset from the target object"),
    16: ("approach_attachment", "Approach attached object by amount/100"),
    17: ("move_up", "Move up amount/12"), 18: ("move_down", "Move down amount/12"),
    19: ("move_left", "Move left amount/12"), 20: ("move_right", "Move right amount/12"),
    21: ("move_forward", "Move forward amount/12"), 22: ("move_back", "Move back amount/12"),
    23: ("target_absolute", "Look at absolute xyz"),
}
# ObjectType -> PositionalObject class (Camera::SetPositionalObject 0x10193dbd, RTTI names).
OBJECT_TYPES = {
    -1: ("none", None), 0: ("no_position", "NoPosition (static point at the previous object's position)"),
    1: ("tee", "TeeBoxPosition"),
    2: ("pin", "HolePosition"), 3: ("landing", "LandingPosition"), 4: ("other_landing", "OutLandingPosition"),
    5: ("ball", "GolferBallPosition"), 6: ("other_ball", "OutGolferBallPosition"),
    7: ("golfer", "GolferPosition"), 8: ("other_golfer", "OutGolferPosition"),
    9: ("golfer_head", "GolferHeadPosition"), 10: ("other_golfer_head", "OutGolferHeadPosition"),
    11: ("ball_and_pin", "BallHoleComboPosition"), 12: ("golfer_and_pin", "GolferHoleComboPosition"),
    13: ("golfer_and_ball", "GolferBallComboPosition"), 14: ("other_ball_and_pin", "OutBallHoleComboPosition"),
    15: ("other_golfer_and_pin", "OutGolferHoleComboPosition"),
    16: ("other_golfer_and_ball", "OutGolferBallComboPosition"),
    17: ("shot_target", "ShotTargetPosition"), 18: ("ball_apex", "BallApexPosition"),
}
# PathType (Camera::CreateTransitionPath 0x10193a4e): cubic Bezier, controls at 1/3 and 2/3.
PATH_TYPES = {-1: "none", 0: "straight", 1: "arc_up_30deg", 2: "arc_up_30deg_yaw_left",
              3: "arc_up_30deg_yaw_right"}
# Group/start mode (Camera::StartNextTransitionGroup 0x101908ef).
START_MODES = {0: "immediate", 1: "new_group", 2: "with_previous"}
TRANSITION_FLAGS = {0x1: "reset_view", 0x2: "clear_queue", 0x4: "kill_current", 0x8: "queue_while_busy"}
EXTRA_FLAGS = {0x1: "relative_angle", 0x2: "mirror_for_lefty"}


def _flag_names(value: int, table: dict) -> list[str]:
    names = [name for bit, name in table.items() if value & bit]
    rest = value & ~sum(table)
    if rest:
        names.append(hex(rest))
    return names


def _u32(value: int) -> int:
    return value & 0xFFFFFFFF


def _inches(value: int) -> str:
    return f"{value} in = {value / 12:g} ft = {value / 36:.1f} yd"


class StnFormatError(ValueError):
    pass


def _cstrings(data: bytes, start: int, count: int) -> tuple[list[str], int]:
    names, offset = [], start
    for _ in range(count):
        end = data.find(b"\0", offset)
        if end < 0:
            raise StnFormatError("Description string table is truncated")
        names.append(data[offset:end].decode("latin-1"))
        offset = end + 1
    return names, offset


def _index_list(data: bytes, offset: int, count: int) -> list[int]:
    values = struct.unpack_from(f"<{count}h", data, offset)
    result = []
    for value in values:
        if value == EMPTY_SLOT:
            break
        result.append(value)
    return result


def parse_stn(data: bytes) -> dict:
    """Split a .stn file into raw situation/action/response records and names."""
    if len(data) < HEADER_SIZE:
        raise StnFormatError("File shorter than the 0x1c-byte header")
    version, n_sit, o_sit, n_act, o_act, n_res, o_res = struct.unpack_from("<7I", data, 0)
    sit_size = SITUATION_SIZE if 0x10002 <= version <= 0x10005 else SITUATION_SIZE_OLD
    act_size = ACTION_SIZE if 0x10003 <= version <= 0x10005 else ACTION_SIZE_OLD
    for count, offset, size, label in ((n_sit, o_sit, sit_size, "situation"), (n_act, o_act, act_size, "action"),
                                       (n_res, o_res, RESPONSE_SIZE, "response")):
        if count > 100000 or offset < HEADER_SIZE or offset + count * size > len(data):
            raise StnFormatError(f"{label} table escapes the file")
    if not (o_sit + n_sit * sit_size <= o_act or n_act == 0) or not (o_act + n_act * act_size <= o_res or n_res == 0):
        raise StnFormatError("Record tables overlap")
    table_end = o_res + n_res * RESPONSE_SIZE
    names, strings_end = _cstrings(data, table_end, n_sit + n_act + n_res)
    return {
        "version": version,
        "record_sizes": {"situation": sit_size, "action": act_size, "response": RESPONSE_SIZE},
        "offsets": {"situations": o_sit, "actions": o_act, "responses": o_res, "strings": table_end,
                    "strings_end": strings_end},
        "situations": [data[o_sit + i * sit_size:o_sit + (i + 1) * sit_size] for i in range(n_sit)],
        "actions": [data[o_act + i * act_size:o_act + (i + 1) * act_size] for i in range(n_act)],
        "responses": [data[o_res + i * RESPONSE_SIZE:o_res + (i + 1) * RESPONSE_SIZE] for i in range(n_res)],
        "situation_names": names[:n_sit],
        "action_names": names[n_sit:n_sit + n_act],
        "response_names": names[n_sit + n_act:],
    }


def describe_condition(bit: int, op: int, value: int) -> dict:
    name, kind, meaning, confidence = EVENT_VARIABLES.get(bit, (f"bit{bit}", "raw", "Unavailable slot", "low"))
    op_name, op_text = OPERATORS.get(op, ("never", "unknown operator: always false"))
    if isinstance(kind, dict):
        shown = "|".join(_flag_names(value, kind)) or "0"
    elif kind == "inches":
        shown = _inches(value)
    else:
        shown = str(value)
    single = bin(value).count("1") == 1
    text = {
        "always": "always",
        "eq": f"{name} == {shown}", "ne": f"{name} != {shown}",
        "gt": f"{name} > {shown}", "lt": f"{name} < {shown}",
        "any": f"{name} has {shown}" if single else f"{name} has any of {shown}",
        "either_nonzero": f"{name} != 0 or {shown} != 0",
        "not_all": f"{name} lacks {shown}" if single else f"{name} lacks at least one of {shown}",
        "none": f"{name} lacks {shown}" if single else f"{name} has none of {shown}",
    }.get(op_name, f"{name}: operator {op} never matches")
    return {"bit": bit, "variable": name, "operator": op_name, "operator_code": op, "value": value,
            "value_hex": hex(value), "display": text, "variable_meaning": meaning,
            "variable_confidence": confidence}


def decode_situation(record: bytes, index: int, name: str, action_names: list[str]) -> dict:
    stype, event = record[0], record[1]
    mask = struct.unpack_from("<I", record, 2)[0]
    ops = struct.unpack_from(f"<{MAX_CONDITIONS}H", record, 6)
    values = struct.unpack_from(f"<{MAX_CONDITIONS}I", record, 26)
    bits = [b for b in range(32) if mask >> b & 1]
    if len(bits) > MAX_CONDITIONS:
        raise StnFormatError(f"Situation {index} has more than ten condition bits")
    conditions = [describe_condition(bit, ops[i], values[i]) for i, bit in enumerate(bits)]
    actions = _index_list(record, 66, MAX_SITUATION_ACTIONS) if len(record) >= 86 else []
    flags = struct.unpack_from("<I", record, 86)[0] if len(record) >= 90 else 0
    priority = record[90] if len(record) >= 91 else 100
    event_name = CAMERA_EVENTS.get(event, (f"event_{event}", ""))[0] if stype in (2, 11) else f"event_{event}"
    return {
        "index": index, "name": name.strip(), "situation_type": stype,
        "situation_type_name": SITUATION_TYPES.get(stype, f"type_{stype}"),
        "event": event, "event_name": event_name,
        "condition_mask": hex(mask), "requires_all_mask_bits": bool(mask & 0x80000000),
        "conditions": conditions, "condition_count": len(bits),
        "never_matches": any(c["operator"] == "never" for c in conditions),
        "actions": actions, "action_names": [action_names[i].strip() if 0 <= i < len(action_names) else None
                                             for i in actions],
        "flags": flags, "single_random_action": bool(flags & 1), "key_moment": bool(flags & 2),
        "priority": priority,
    }


def decode_action(record: bytes, index: int, name: str, response_names: list[str]) -> dict:
    atype, probability = record[0], record[1]
    flags = struct.unpack_from("<I", record, 2)[0]
    responses = _index_list(record, 6, MAX_ACTION_RESPONSES)
    # ScriptAction ctor 0x10215e27: bit 0 becomes 0x4000 "play every response in order".
    effective = flags
    if flags & 1 and not flags & 0x1410 and atype != 0xFF:
        effective = (flags & ~1) | 0x4000
    return {
        "index": index, "name": name.strip(), "action_type": atype,
        "action_type_name": ACTION_TYPES.get(atype, f"type_{atype}"),
        "probability_percent": probability, "flags": flags, "effective_flags": effective,
        "all_responses_in_order": bool(effective & 0x4000), "immediate": bool(effective & 0x80),
        "responses": responses,
        "response_names": [response_names[i].strip() if 0 <= i < len(response_names) else None for i in responses],
    }


def decode_response(record: bytes, index: int, name: str) -> dict:
    rtype = record[0]
    entry = {"index": index, "name": name.strip(), "response_type": rtype,
             "response_type_name": RESPONSE_TYPES.get(rtype, f"type_{rtype}"),
             "header_flags": struct.unpack_from("<I", record, 1)[0]}
    if rtype != 13:
        entry["payload_hex"] = record[5:44].hex()
        if rtype == 9:
            entry["animation_id"] = record[5]
        entry["summary"] = f"{entry['response_type_name']}: {entry['name']}"
        return entry
    kind = record[5]
    command, = struct.unpack_from("<i", record, 6)
    x, y, z = struct.unpack_from("<3f", record, 10)
    path, start, flags, obj = struct.unpack_from("<4i", record, 22)
    duration_tenths = record[38]
    amount, = struct.unpack_from("<i", record, 39)
    extra = record[43]
    effective_flags = _u32(flags) | (1 if command == 0 else 0)  # CameraResponse ctor 0x102194e0
    cmd_name = CAMERA_COMMANDS.get(command, (f"command_{command}", ""))[0]
    entry.update({
        "kind": kind, "kind_name": CAMERA_RESPONSE_KINDS.get(kind, f"kind_{kind}"),
        "command": command, "command_name": cmd_name,
        "object_type": obj, "object_name": OBJECT_TYPES.get(obj, (f"object_{obj}",))[0],
        "offset_in": [x, y, z], "offset_ft": [round(x / 12, 4), round(y / 12, 4), round(z / 12, 4)],
        "path_type": path, "path_name": PATH_TYPES.get(path, f"path_{path}"),
        "start_mode": start, "start_mode_name": START_MODES.get(start, f"mode_{start}"),
        "flags": _u32(flags), "effective_flags": effective_flags,
        "flag_names": _flag_names(effective_flags, TRANSITION_FLAGS),
        "duration_s": duration_tenths / 10, "amount": amount, "extra_flags": extra,
        "extra_flag_names": _flag_names(extra, EXTRA_FLAGS),
    })
    if command == 6:
        z_factor = amount / 100
        entry["zoom_factor"] = z_factor
        entry["vertical_fov_deg"] = _vertical_fov_deg(z_factor)
    if command in (0, 1) and obj not in (-1, 0):
        entry["followed_by"] = {"command_name": "attachment_offset" if command == 0 else "target_offset",
                                "start_mode_name": "with_previous" if start else "immediate",
                                "offset_ft": entry["offset_ft"]}
    entry["summary"] = summarize_response(entry)
    return entry


def _vertical_fov_deg(zoom: float) -> float:
    """Camera::CalculateZoomFactor 0x10192f55 + Camera::NextFrame SetProjection."""
    effective = zoom * zoom if zoom <= 1 else zoom
    effective = min(max(effective, 0.0625), 256.0)
    return round(math.degrees(math.pi / 4 / effective), 3)


def summarize_response(r: dict) -> str:
    if r.get("response_type") != 13:
        return r["name"]
    if r["kind"] != 0:
        return f"{r['kind_name']} over {r['duration_s']:g}s"
    cmd, dur = r["command_name"], r["duration_s"]
    timing = "cut" if dur == 0 else f"over {dur:g}s"
    flags = ",".join(n for n in r["flag_names"] if n != "reset_view")
    tail = f" [{r['start_mode_name']}{',' + flags if flags else ''}]"
    if cmd in ("attach", "target") and r["object_type"] == 0:
        return f"{'freeze camera position' if cmd == 'attach' else 'freeze look-at point'} where it is now{tail}"
    if cmd in ("attach", "target"):
        verb = "move camera to" if cmd == "attach" else "look at"
        ox, oy, oz = r["offset_ft"]
        path = "" if r["path_name"] in ("straight", "none") or dur == 0 else f", {r['path_name']} path"
        mirror = ", mirrored for lefty" if r["extra_flags"] & 2 else ""
        return f"{verb} {r['object_name']} + ({ox:g}, {oy:g}, {oz:g}) ft, {timing}{path}{mirror}{tail}"
    if cmd == "zoom":
        return f"zoom {r['amount']}% (vertical FOV {r['vertical_fov_deg']:g} deg), {timing}{tail}"
    if cmd == "letterbox":
        return f"letterbox {r['amount']}%, {timing}{tail}"
    if cmd == "pause":
        return f"hold {dur:g}s{tail}"
    if cmd in ("pitch", "pan", "rotate_x", "rotate_y", "tilt"):
        return f"{cmd} {r['amount']} deg, {timing}{tail}"
    return f"{cmd} amount {r['amount']}, {timing}{tail}"


def decode_script(data: bytes, filename: str) -> dict:
    raw = parse_stn(data)
    responses = [decode_response(rec, i, n) for i, (rec, n) in
                 enumerate(zip(raw["responses"], raw["response_names"]))]
    actions = [decode_action(rec, i, n, raw["response_names"]) for i, (rec, n) in
               enumerate(zip(raw["actions"], raw["action_names"]))]
    situations = [decode_situation(rec, i, n, raw["action_names"]) for i, (rec, n) in
                  enumerate(zip(raw["situations"], raw["situation_names"]))]
    for situation in situations:
        for index in situation["actions"]:
            if not 0 <= index < len(actions):
                raise StnFormatError(f"Situation {situation['index']} references missing action {index}")
    for action in actions:
        if action["action_type"] == 12:
            continue  # link actions index another file
        for index in action["responses"]:
            if not 0 <= index < len(responses):
                raise StnFormatError(f"Action {action['index']} references missing response {index}")
    for situation in situations:
        situation["rule"] = summarize_situation(situation, actions, responses)
    used = {index for situation in situations for index in situation["actions"]}
    role = SCRIPT_FILES.get(filename, (None, None))
    return {
        "file": filename, "registry_key": f"Software\\EA SPORTS\\Tiger Woods PGA TOUR 2005\\Script\\{role[0]}"
        if role[0] else None, "role": role[0], "purpose": role[1],
        "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data),
        "version": hex(raw["version"]), "record_sizes": raw["record_sizes"], "offsets": raw["offsets"],
        "situations": situations, "actions": actions, "responses": responses,
        "unused_actions": [a["index"] for a in actions if a["index"] not in used],
        "never_matching_situations": [s["index"] for s in situations if s["never_matches"]],
    }


def summarize_situation(s: dict, actions: list[dict], responses: list[dict]) -> dict:
    when = [c["display"] for c in s["conditions"]]
    choice = "pick one at random (duplicates weight)" if s["single_random_action"] else "run every action"
    then = []
    for index in dict.fromkeys(s["actions"]):
        action = actions[index]
        weight = s["actions"].count(index)
        steps = [responses[i]["summary"] for i in action["responses"] if 0 <= i < len(responses)]
        then.append({"action": action["name"], "weight": weight,
                     "probability_percent": action["probability_percent"], "steps": steps})
    return {"event": s["event_name"], "priority": s["priority"], "when": when, "choice": choice, "then": then}


# ---------------------------------------------------------------------------
# Selection model (Script::FindSituationsMatching 0x1020bfe3,
# Script::DoSituationsMatching 0x1020c1df). Exposed for native ports/tests.
# ---------------------------------------------------------------------------
CAMERA_EVENT_MASK = 0x77FFFFFF


def condition_true(op: int, value: int, threshold: int) -> bool:
    value, threshold = _u32(value), _u32(threshold)
    return {0: True, 1: value == threshold, 2: value != threshold, 3: value > threshold,
            4: value < threshold, 5: (value & threshold) != 0, 6: value != 0 or threshold != 0,
            7: (~value & threshold & 0xFFFFFFFF) != 0, 8: (value & threshold) == 0}.get(op, False)


def situation_matches(s: dict, event: int, values: dict[int, int], event_mask: int = CAMERA_EVENT_MASK) -> bool:
    if not s["actions"] or (s["event"] not in (0, event)):
        return False
    mask = int(s["condition_mask"], 16)
    overlap = event_mask & mask
    full = overlap == (mask & 0x7FFFFFFF)
    if event_mask and not ((mask & 0x80000000 and full) or (overlap and not mask & 0x80000000)
                           or (not overlap and full)):
        return False
    return all(condition_true(c["operator_code"], values.get(c["bit"], 0), c["value"]) for c in s["conditions"])


def choose_situation(situations: list[dict], event: int, values: dict[int, int],
                     rng: random.Random | None = None) -> dict | None:
    """Lowest priority byte wins; ties prefer more conditions; then uniform random."""
    matches = [s for s in situations if situation_matches(s, event, values)]
    if not matches:
        return None
    best = min(s["priority"] for s in matches)
    matches = [s for s in matches if s["priority"] == best]
    most = max(s["condition_count"] for s in matches)
    matches = [s for s in matches if s["condition_count"] == most]
    return (rng or random).choice(matches)


# ---------------------------------------------------------------------------
# Tri-click swing meter (TriClickMeter 0x101a5fae.., ClickSwingControlC 0x10164xxx)
# ---------------------------------------------------------------------------
DIFFICULTIES = {
    # level: name, deg/s non-putter, deg/s putter, x-factor, bounce speed-up/ms, bounce slow-down/ms,
    # max slice deg, miss-hit rotation deg, magnet, power-shot penalty, putt exponent (mouse methods),
    # mouse ranges, backswing pixel limit, ability factor, power shot allowed
    0: dict(name="Novice", rate=200, putter_rate=170, x_factor=-100.0, speedup=0.985, slowdown=1.015,
            max_slice_deg=1.5, miss_hit_rotation_deg=1.25, magnet=0.8, power_shot_penalty=5.0,
            putt_power_exponent=1.0, mouse_ranges=[100.0, 220.0, 2000.0], backswing_pixel_limit=500,
            ability_factor=0.25, power_shot_and_high_spin_allowed=True),
    1: dict(name="Intermediate", rate=260, putter_rate=170, x_factor=-150.0, speedup=0.98, slowdown=1.02,
            max_slice_deg=3.5, miss_hit_rotation_deg=2.5, magnet=0.45, power_shot_penalty=3.0,
            putt_power_exponent=1.1, mouse_ranges=[30.0, 170.0, 230.0], backswing_pixel_limit=2000,
            ability_factor=0.6, power_shot_and_high_spin_allowed=True),
    2: dict(name="Advanced", rate=325, putter_rate=200, x_factor=-220.0, speedup=0.975, slowdown=1.025,
            max_slice_deg=5.0, miss_hit_rotation_deg=4.0, magnet=0.05, power_shot_penalty=2.0,
            putt_power_exponent=1.2, mouse_ranges=[25.0, 140.0, 180.0], backswing_pixel_limit=2000,
            ability_factor=0.9, power_shot_and_high_spin_allowed=True),
    3: dict(name="Expert", rate=355, putter_rate=200, x_factor=-300.0, speedup=0.97, slowdown=1.03,
            max_slice_deg=6.0, miss_hit_rotation_deg=5.0, magnet=0.0, power_shot_penalty=2.0,
            putt_power_exponent=1.2, mouse_ranges=[15.0, 120.0, 160.0], backswing_pixel_limit=2000,
            ability_factor=1.0, power_shot_and_high_spin_allowed=False),
}
PUTTER = 20
REST_ANGLE = 270.0
FULL_POWER_ANGLE = 90.0
POWER_SPAN = 180.0
MIN_ANGLE = 48.0
MAX_ANGLE = 311.0
EARLY_ACCURACY_CLAMP = 229.0
ACCURACY_SPAN = 41.0
SLOWDOWN_START_ANGLE = 63.0
SNAP_DEGREES = 3
PERIOD_START = 0x64000      # 16.16 fixed ms per degree (6.25 -> 160 deg/s)
PERIOD_SLOW = 0x320000      # 50.0 ms per degree (20 deg/s)


def _f32(value: float) -> float:
    return struct.unpack("<f", struct.pack("<f", value))[0]


def _trunc(value: float) -> int:
    return int(value)  # MSVCRT ftol truncates toward zero


def tri_click_rate(level: int, club: int) -> int:
    d = DIFFICULTIES[level]
    rate = (d["putter_rate"] if club == PUTTER else d["rate"])
    if 20 < club < 33 and level > 0:
        rate -= 30
    return rate


class TriClickMeter:
    """Reference port of the original tri-click meter state machine.

    Angles are degrees, 0 = 3 o'clock, counter-clockwise positive, so 270 is
    6 o'clock and 90 is 12 o'clock. ``step(dt_ms)`` applies one frame; call
    ``click()`` before the step of the frame in which the click is read.
    """

    def __init__(self, level: int = 1, club: int = 8, shot_style: int = 0, tempo_trait: float = 1.0,
                 two_click: bool = False, rng: random.Random | None = None):
        d = DIFFICULTIES[level]
        self.rng = rng or random.Random(0)
        self.two_click = two_click
        self.putter = club == PUTTER
        step = 0x3E80000 // tri_click_rate(level, club)
        floor = step
        if tempo_trait > 1.0:
            step, floor = _trunc(step / _f32(tempo_trait * tempo_trait)), _trunc(floor / _f32(tempo_trait * tempo_trait))
        if shot_style == 5:
            step, floor = _trunc(step / 1.25), _trunc(floor / 1.25)
        if shot_style in (4, 8, 9):
            step, floor = _trunc(step / _f32(1.15)), _trunc(floor / _f32(1.15))
        self.step_min, self.floor = step, floor
        self.slowdown, self.speedup = _f32(d["slowdown"]), _f32(d["speedup"])
        self.period = PERIOD_START
        self.state, self.direction, self.angle = 1, 1, REST_ANGLE
        self.power_angle = self.accuracy_angle = 0.0
        self.missed_power = self.missed_direction = False
        self.power_tick_color = self.accuracy_tick_color = None
        self._pending_click = False

    # SetStateAtMouseClick 0x101a654d
    def click(self) -> None:
        if self.state == 2 and self.angle <= REST_ANGLE:
            self.state = 6 if self.two_click else 3
            if abs(_trunc(self.angle - FULL_POWER_ANGLE)) < SNAP_DEGREES:
                self.angle = FULL_POWER_ANGLE
            self.power_angle = self.angle
            self.power_tick_color = ("green" if self.angle == FULL_POWER_ANGLE else
                                     "white" if self.angle > FULL_POWER_ANGLE else "red")
            if self.power_angle < FULL_POWER_ANGLE:
                over = FULL_POWER_ANGLE - self.power_angle
                self.floor = _trunc(self.floor * (1.0 - over / 150.0))
                self.power_angle = FULL_POWER_ANGLE - over * 0.2
        elif self.state == 4:
            self.state = 5
            if abs(_trunc(self.angle - REST_ANGLE)) < SNAP_DEGREES:
                self.angle = REST_ANGLE
            if self.angle <= EARLY_ACCURACY_CLAMP:
                self.angle = self.accuracy_angle = EARLY_ACCURACY_CLAMP
            else:
                self.accuracy_angle = self.angle
            self.accuracy_tick_color = "green" if self.accuracy_angle == REST_ANGLE else "white"

    # ComputeNewAngle 0x101a699c + NextFrame clamp 0x101a67dd
    def step(self, dt_ms: int) -> float:
        if self.state in (0, 6) or dt_ms <= 0:
            return self.angle
        dt = min(int(dt_ms), 0xB4)
        delta = min(_f32((dt * 0xB6 << 16) / self.period / 182.0), 16.0)
        direction = self.direction
        if self.state == 1:
            if self.period == PERIOD_SLOW:
                self.state = 2
            elif self.period < PERIOD_SLOW:
                self.period = min(_trunc(_f32(1.005) ** dt * self.period), PERIOD_SLOW)
            self.direction = 1
        elif self.state == 2:
            if self.angle > SLOWDOWN_START_ANGLE:
                if self.step_min < self.period:
                    self.period = max(_trunc(_f32(0.99) ** dt * self.period), self.floor)
            else:
                self.period = min(_trunc(self.slowdown ** dt * self.period), PERIOD_SLOW)
            if self.angle <= MIN_ANGLE:
                self.state = 6 if self.two_click else 3
                tick = 170.0 - self.rng.randrange(0x7FFF) % 20
                self.power_angle, self.missed_power, self.power_tick_color = tick, True, "white"
                if self.two_click:
                    self.angle = tick
                    return self.angle
                self.floor = _trunc(self.floor * (1.0 - 42.0 / 150.0))
            self.direction = -1
        elif self.state == 3:
            if self.period < PERIOD_SLOW:
                self.period = min(_trunc(self.slowdown ** dt * self.period), PERIOD_SLOW)
            else:
                self.state = 4
            self.direction = -1
        elif self.state in (4, 5):
            if self.angle < MAX_ANGLE:
                if self.floor < self.period:
                    self.period = max(_trunc(self.speedup ** dt * self.period), self.floor)
            else:
                if self.state == 4:
                    self.accuracy_angle, self.missed_direction = MAX_ANGLE, True
                    self.accuracy_tick_color = "white"
                self.state = 6
            self.direction = 1
        self.angle = min(max(direction * delta + self.angle, MIN_ANGLE), MAX_ANGLE)
        return self.angle

    @property
    def finished(self) -> bool:
        return self.state == 6

    @property
    def power(self) -> float:  # GetPowerPercent 0x101a6fe2
        return (REST_ANGLE - self.power_angle) / POWER_SPAN

    @property
    def direction_percent(self) -> float:  # GetDirectionPercent 0x101a7002
        if self.two_click:
            return 0.0
        value = (self.accuracy_angle - REST_ANGLE) / ACCURACY_SPAN
        return -value if self.putter else value


def click_lateral_offset(level: int, power: float, direction: float, missed_power: bool = False,
                         missed_direction: bool = False, mirrored: bool = False) -> int:
    """ClickSwingControlC 0x10164402: synthetic mouse X fed to the swing analyser."""
    signed = (1 if direction > 0 else -1) * direction * direction
    x = DIFFICULTIES[level]["x_factor"] * (-1 if mirrored else 1)
    if missed_direction:
        x *= 4.0
    if power > 1.0 or missed_power:
        if missed_power:
            power = _f32(1.2)
        x *= 2.0 * power * power
    return _trunc(x * signed + 0.5)


def simulate(level: int, click_times_ms: list[int], club: int = 8, shot_style: int = 0,
             two_click: bool = False, dt_ms: int = 10, limit_ms: int = 10000, seed: int = 0) -> dict:
    """Run the meter with clicks at the given times (ms after the swing starts)."""
    meter = TriClickMeter(level, club, shot_style, two_click=two_click, rng=random.Random(seed))
    clicks, t, trace = sorted(click_times_ms), 0, []
    while not meter.finished and t < limit_ms:
        while clicks and clicks[0] <= t:
            clicks.pop(0)
            meter.click()
        meter.step(dt_ms)
        t += dt_ms
        trace.append((t, round(meter.angle, 3), meter.state))
    return {"power": meter.power, "direction": meter.direction_percent, "power_angle": meter.power_angle,
            "accuracy_angle": meter.accuracy_angle, "missed_power": meter.missed_power,
            "missed_direction": meter.missed_direction, "finished_ms": t, "trace": trace,
            "lateral_offset_px": click_lateral_offset(level, meter.power, meter.direction_percent,
                                                      meter.missed_power, meter.missed_direction)}


# ---------------------------------------------------------------------------
# Engine.dll constants (verified against the original bytes when supplied)
# ---------------------------------------------------------------------------
ENGINE_CONSTANTS = [
    # (va, type, expected, meaning)
    (0x102D9330, "f32", 270.0, "Meter rest angle (6 o'clock); 0% power and perfect accuracy"),
    (0x102D6B54, "f32", 90.0, "100% power angle (12 o'clock)"),
    (0x102D5674, "f32", 180.0, "Power span in degrees (power = (270 - angle) / 180)"),
    (0x102D9344, "f32", 41.0, "Accuracy half-range in degrees (direction = (angle - 270) / 41)"),
    (0x102D9320, "f32", 229.0, "Early accuracy clamp (direction -1)"),
    (0x102D9334, "f32", 311.0, "Late accuracy limit / maximum angle (direction +1, missed)"),
    (0x102D77EC, "f32", 48.0, "Minimum angle; overswing stop (123.3% raw)"),
    (0x102D933C, "f32", 63.0, "Backswing starts decelerating at or above this overswing angle"),
    (0x102D9338, "f32", 170.0, "Missed-power tick base angle (tick = 170 - rand%20)"),
    (0x102D9340, "f32", 182.0, "Angle-step divisor paired with (dt*0xb6) << 16"),
    (0x102D62F4, "f32", 16.0, "Maximum degrees per frame"),
    (0x102D92FC, "f32", 1.005, "Lift phase period growth per ms"),
    (0x102D9300, "f32", 0.99, "Backswing period shrink per ms (acceleration)"),
    (0x102D8E1C, "f32", 150.0, "Overswing return-speed divisor (floor *= 1 - over/150)"),
    (0x102D9328, "f64", 0.2, "Overswing compression (stored angle = 90 - over*0.2)"),
    (0x102D8124, "f32", 1.25, "Flop (style 5) meter speed multiplier"),
    (0x102D82B0, "f32", 1.15, "Style 4/8/9 meter speed multiplier"),
    (0x102D812C, "f32", -100.0, "Tri-click x-factor, Novice"),
    (0x102D8128, "f32", -150.0, "Tri-click x-factor, Intermediate"),
    (0x102D8130, "f32", -220.0, "Tri-click x-factor, Advanced"),
    (0x102D8134, "f32", -300.0, "Tri-click x-factor, Expert"),
    (0x102D813C, "f32", 0.985, "Bounce speed-up ratio per ms, Novice"),
    (0x102D7080, "f32", 0.98, "Bounce speed-up ratio per ms, Intermediate"),
    (0x102D8138, "f32", 0.975, "Bounce speed-up ratio per ms, Advanced"),
    (0x102D71A0, "f32", 0.97, "Bounce speed-up ratio per ms, Expert"),
    (0x102D814C, "f32", 1.015, "Bounce slow-down ratio per ms, Novice"),
    (0x102D8140, "f32", 1.02, "Bounce slow-down ratio per ms, Intermediate"),
    (0x102D8148, "f32", 1.025, "Bounce slow-down ratio per ms, Advanced"),
    (0x102D8144, "f32", 1.03, "Bounce slow-down ratio per ms, Expert"),
    (0x102D59C8, "f32", 1.5, "Max slice angle (deg), Novice"),
    (0x102D811C, "f32", 3.5, "Max slice angle (deg), Intermediate"),
    (0x102D56AC, "f32", 5.0, "Max slice angle (deg), Advanced; also power-shot penalty Novice"),
    (0x102D5CD8, "f32", 6.0, "Max slice angle (deg), Expert"),
    (0x102D6C2C, "f32", 0.6, "Hook/slice exponent (face = sign*|x|^0.6*maxSlice)"),
    (0x102D6304, "f32", 4.0, "Missed-accuracy lateral multiplier"),
    (0x102D6300, "f32", 2.0, "Overswing lateral multiplier factor (x *= 2*p*p)"),
    (0x102D854C, "f32", 700.0, "Synthetic backswing duration ms per unit power"),
    (0x102D6C30, "f32", 0.8, "Putter power multiplier in ClickSwingControlC"),
    (0x102D6684, "f32", 1.1, "Click control power headroom (+0x48 = +0x50*1.1)"),
    (0x102D8E20, "f32", math.pi / 4, "Base vertical FOV (radians) divided by zoom"),
    (0x102D8E24, "f32", 0.0625, "Minimum zoom factor"),
    (0x102D8E28, "f32", 256.0, "Maximum zoom factor"),
    (0x102D8E2C, "f32", 75000.0, "Far clip plane (inches)"),
    (0x102D6C0C, "f32", 10000.0, "Camera timer scale (seconds/100 -> ms)"),
    (0x102D4D6C, "f32", 100.0, "Divisor for byte durations and percent amounts"),
    (0x102D56A4, "f32", 20.0, "Flight progress to flight index scale"),
    (0x102D60F8, "f32", 72.0, "Near-hole threshold (6 ft) halving the flight sample minimum"),
    (0x102D9A90, "f64", 0.65, "Wind direction flag threshold"),
    (0x10379158, "u32", 60, "Minimum flight samples before in-flight camera events"),
    (0x1037915C, "u32", 3, "Initial flight index"),
]
ENGINE_IMMEDIATES = [
    # (function VA, window, value, meaning)
    (0x101A5FAE, 0x120, 0x43870000, "Initial meter angle 270.0"),
    (0x101A5FAE, 0x120, 0x64000, "Initial period 6.25 ms/deg"),
    (0x101A61C5, 0x80, 0x3E80000, "Rate numerator 1000*65536"),
    (0x101A699C, 0x600, 0x320000, "Slow period 50 ms/deg (20 deg/s)"),
    (0x101A699C, 0x80, 0xB6, "Angle step: (dt*0xb6) << 16 / period / 182"),
    (0x101A654D, 0x200, 0x42B40000, "Power snap target 90.0"),
    (0x101A654D, 0x300, 0x43650000, "Accuracy early clamp 229.0"),
    (0x1013C516, 0x90, 200, "Tri-click rate Novice / putter Advanced+"),
    (0x1013C516, 0x90, 0x145, "Tri-click rate Advanced (325)"),
    (0x1013C516, 0x90, 0x163, "Tri-click rate Expert (355)"),
    (0x1013C516, 0x90, 0x104, "Tri-click rate Intermediate (260)"),
    (0x1013C516, 0x90, 0xAA, "Tri-click putter rate Novice/Intermediate (170)"),
]


class PEImage:
    def __init__(self, data: bytes):
        if data[:2] != b"MZ":
            raise ValueError("Not a PE image")
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        if data[pe:pe + 4] != b"PE\0\0":
            raise ValueError("Missing PE signature")
        sections, optional = struct.unpack_from("<H", data, pe + 6)[0], struct.unpack_from("<H", data, pe + 20)[0]
        self.data, self.base = data, struct.unpack_from("<I", data, pe + 24 + 28)[0]
        self.sections = []
        for i in range(sections):
            o = pe + 24 + optional + 40 * i
            vsize, va, rsize, raw = struct.unpack_from("<IIII", data, o + 8)
            self.sections.append((va, max(vsize, rsize), raw, rsize))

    def offset(self, va: int) -> int:
        rva = va - self.base
        for start, size, raw, rsize in self.sections:
            if start <= rva < start + size and rva - start < rsize:
                return raw + rva - start
        raise ValueError(f"Address {va:#x} not backed by file data")

    def read(self, va: int, kind: str):
        fmt = {"f32": "<f", "f64": "<d", "u32": "<I"}[kind]
        return struct.unpack_from(fmt, self.data, self.offset(va))[0]


def verify_engine(data: bytes) -> dict:
    digest = hashlib.sha256(data).hexdigest()
    result = {"sha256": digest, "matches_expected_build": digest == ENGINE_SHA256, "constants": [],
              "immediates": []}
    image = PEImage(data)
    for va, kind, expected, meaning in ENGINE_CONSTANTS:
        actual = image.read(va, kind)
        ok = math.isclose(actual, expected, rel_tol=1e-6, abs_tol=1e-9) if kind != "u32" else actual == expected
        result["constants"].append({"va": hex(va), "type": kind, "expected": expected, "actual": actual,
                                    "verified": ok, "meaning": meaning})
    for va, window, value, meaning in ENGINE_IMMEDIATES:
        start = image.offset(va)
        found = struct.pack("<I", value) in data[start:start + window]
        result["immediates"].append({"function": hex(va), "value": hex(value), "verified": found,
                                     "meaning": meaning})
    result["all_verified"] = all(c["verified"] for c in result["constants"] + result["immediates"])
    return result


def swing_document(engine: dict | None) -> dict:
    timeline = {}
    for level in DIFFICULTIES:
        meter = TriClickMeter(level, rng=random.Random(0))
        t, lift_end, full_speed = 0, None, None
        while meter.state != 6 and t < 5000:
            prev = meter.state
            meter.step(1)
            t += 1
            if prev == 1 and meter.state == 2:
                lift_end = (t, round(meter.angle, 2))
            if full_speed is None and meter.state == 2 and meter.period == meter.floor:
                full_speed = (t, round(meter.angle, 2))
            if meter.state == 2 and meter.angle <= FULL_POWER_ANGLE and "full" not in timeline.get(level, {}):
                timeline.setdefault(level, {})["full"] = t
        timeline.setdefault(level, {}).update({"lift_end_ms_angle": lift_end, "top_speed_ms_angle": full_speed})
    difficulties = []
    for level, d in DIFFICULTIES.items():
        entry = dict(level=level, **d)
        entry["max_speed_deg_per_s"] = d["rate"]
        entry["sim_ms_from_start_to_100pct_no_click"] = timeline[level].get("full")
        entry["sim_lift_end"] = timeline[level]["lift_end_ms_angle"]
        entry["sim_reaches_top_speed"] = timeline[level]["top_speed_ms_angle"]
        difficulties.append(entry)
    return {
        "schema_version": SCHEMA_VERSION,
        "generator": "Tools/decode_pga2005_cameras.py",
        "method": "Static Ghidra 12.1.2 decompilation and disassembly of Engine.dll; constants read from the "
                  "original bytes when Engine.dll is supplied. No game code was executed.",
        "engine_sha256": ENGINE_SHA256,
        "engine_verification": engine,
        "angle_convention": "Degrees, 0 = 3 o'clock, counter-clockwise positive (screen point = centre + r*(cos, -sin)). "
                            "270 = 6 o'clock, 180 = 9, 90 = 12.",
        "control_methods": {"0x100": "TrueSwingH", "0x200": "TrueSwingV", "0x400": "Tri-Click",
                            "0x800": "Two-Click"},
        "meter": {
            "rest_angle": REST_ANGLE, "full_power_angle": FULL_POWER_ANGLE, "power_span": POWER_SPAN,
            "min_angle": MIN_ANGLE, "max_angle": MAX_ANGLE, "early_accuracy_clamp": EARLY_ACCURACY_CLAMP,
            "accuracy_span": ACCURACY_SPAN, "snap_window_degrees": "|trunc(angle - target)| < 3",
            "power_percent": "(270 - power_angle) / 180",
            "direction_percent": "(accuracy_angle - 270) / 41, negated for the putter",
            "raw_overswing_max_percent": round((REST_ANGLE - MIN_ANGLE) / POWER_SPAN * 100, 2),
            "effective_overswing_max_percent": round((REST_ANGLE - (90 - 42 * 0.2)) / POWER_SPAN * 100, 2),
            "overswing_rule": "over = 90 - angle; stored angle = 90 - 0.2*over; return-speed floor *= (1 - over/150)",
            "missed_power_rule": "marker reaches 48 deg: power tick = 170 - rand(0..19) deg (55.6-66.1%), "
                                 "floor *= 0.72, and the click mapper treats power as 1.2 for lateral error",
            "missed_accuracy_rule": "marker reaches 311 deg: direction = +1 and lateral error x4",
            "speed_model": "deg per ms = 65536 / period; period is 16.16 fixed ms-per-degree. "
                           "Max speed (period floor) = rate deg/s. dt is capped at 180 ms and a frame moves at most 16 deg.",
            "states": {
                "1": "lift: moves counter-clockwise from 270 while period grows x1.005/ms from 6.25 to 50 (160 -> 20 deg/s)",
                "2": "backswing: clockwise; period x0.99/ms down to the floor (rate deg/s); at <=63 deg decelerate by "
                     "slow-down ratio; power click accepted only when angle <= 270",
                "3": "after power click: keeps going clockwise, decelerating by slow-down ratio until 20 deg/s",
                "4": "return: counter-clockwise, accelerating by speed-up ratio to the floor; accuracy click here",
                "5": "after accuracy click: continues to 311",
                "6": "finished",
            },
            "flop_speed_multiplier": 1.25, "style_4_8_9_speed_multiplier": 1.15,
            "tempo_trait": "PlayerTraits+0x344 > 1 divides the period by its square (meaning unknown)",
            "rate_adjustment": "clubs 21-32 at non-Novice levels: rate - 30 deg/s",
            "two_click": "control method 0x800: meter ends at the power click, direction = 0",
            "input": "left or right mouse button down, or a new Space key press (DIK 0x39), read once per frame",
        },
        "click_to_shot": {
            "source": "ClickSwingControlC vtable 0x102d86b4 (FUN_1016418f, FUN_10164621, FUN_10164402, FUN_10164344)",
            "lateral_offset_px": "trunc(x_factor * sign(d) * d^2 + 0.5); x_factor x4 if accuracy missed; "
                                 "x 2*p^2 if p > 1 or power missed (p = 1.2 then); sign flipped by two control flags",
            "synthetic_stroke": "power p' = max(p, 0.5); backswing lasts 700*p' ms; the meter result is replayed as a "
                                "mouse stroke into the TrueSwing analyser (SWINGINFO_MSG::AddPoint)",
            "shot_power": "p * base * CPlayer::GetShotHitFactor(style) (skipped for type 6) * 0.8 for the putter",
            "clubface": "FUN_101609dd ComputeClubfaceDirection: face = sign(x)*|x|^0.6 * maxSliceAngle",
            "hook_slice_side": "Not established statically; see open questions",
        },
        "difficulty_levels": difficulties,
        "shot_hit_factor_by_style": {"3": 0.6, "6": 0.4, "7": 0.7, "other": 1.0},
        "dial_geometry": {
            "frame_rect_default": [100, 200, 356, 456],
            "texture_ids": {"lit": "0x300c (drawn from 315 deg clockwise to the marker)", "unlit": "0x300d"},
            "pivot": "frame centre = texture centre (0.5, 0.5)",
            "lit_sector": "from 315 deg (about 4:30) clockwise to the current angle; four quadrant triangles "
                          "bottom/left/top/right plus a partial wedge",
            "tick_geometry": "radial quad from radius 76 to the circle of radius 96 centred (-2, +7) from "
                             "the pivot, in 255-unit frame space; 4 units wide",
            "tick_colors": {"power_exact_100": "0xff00ff00", "power_under": "0xffffffff",
                            "power_over": "0xffff0000", "accuracy_exact": "0xff00ff00",
                            "accuracy_other": "0xffffffff"},
        },
    }


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
def atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=path.parent, prefix=path.name, suffix=".tmp")
    try:
        with os.fdopen(handle, "w") as stream:
            stream.write(text)
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except BaseException:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise


def enums_document() -> dict:
    return {
        "camera_events": {str(k): {"name": v[0], "source": v[1]} for k, v in CAMERA_EVENTS.items()},
        "event_variables": {str(bit): {"name": v[0], "unit": v[1] if isinstance(v[1], str) else "flags",
                                       "flags": {hex(f): n for f, n in v[1].items()} if isinstance(v[1], dict) else None,
                                       "meaning": v[2], "confidence": v[3]}
                            for bit, v in EVENT_VARIABLES.items()},
        "operators": {str(k): {"name": v[0], "test": v[1]} for k, v in OPERATORS.items()},
        "camera_commands": {str(k): {"name": v[0], "meaning": v[1]} for k, v in CAMERA_COMMANDS.items()},
        "object_types": {str(k): {"name": v[0], "class": v[1]} for k, v in OBJECT_TYPES.items()},
        "path_types": {str(k): v for k, v in PATH_TYPES.items()},
        "start_modes": {str(k): v for k, v in START_MODES.items()},
        "transition_flags": {hex(k): v for k, v in TRANSITION_FLAGS.items()},
        "extra_flags": {hex(k): v for k, v in EXTRA_FLAGS.items()},
        "response_kinds": {str(k): v for k, v in CAMERA_RESPONSE_KINDS.items()},
        "action_types": {str(k): v for k, v in ACTION_TYPES.items()},
        "response_types": {str(k): v for k, v in RESPONSE_TYPES.items()},
        "situation_types": {str(k): v for k, v in SITUATION_TYPES.items()},
    }


def cameras_document(scripts: list[dict], missing: list[str]) -> dict:
    return {
        "schema_version": SCHEMA_VERSION,
        "generator": "Tools/decode_pga2005_cameras.py",
        "method": "Static decode of original .stn bytes using layouts recovered from Engine.dll "
                  f"(SHA-256 {ENGINE_SHA256}). No game code was executed.",
        "units": {"offset_in": "inches in a yaw-only frame: +z points from the attached object toward the "
                               "target object (or along the object's heading when they coincide), x right, y up; "
                               "rotated by Camera::AdjustPosition 0x101938e5 / UpdateEndTheta 0x10195400",
                  "camera_ground_clearance_in": 15,
                  "distances": "inches", "duration_s": "seconds (stored as tenths; 0 = cut)"},
        "selection": {
            "match": "situation type == event category, event id equal or 0, every condition true, at least one action",
            "choose": "lowest priority byte; ties prefer more conditions; then uniform random",
            "actions": "single_random_action: one action at random (duplicates weight it); otherwise all in order",
            "action_probability": "action runs if random(100)+1 <= probability",
            "camera_action": "every response in order; each queues one transition (two for attach/target with an object)",
            "dynamic_cameras_off": "CameraScriptType falls back to type 2 unless 2 or 3; "
                                   "with no dynamic animator every move is a cut",
            "camera_projection": "vertical FOV = 45 deg / zoom' (zoom' = z^2 if z <= 1 else z, clamped 0.0625..256); "
                                 "near 50 in (10 in when close), far 75000 in",
            "easing": "angular values (zoom, letterbox, pan...) use 0.5 + 0.5*sin(pi*t - pi/2)",
        },
        "enums": enums_document(),
        "scripts": scripts,
        "missing_files": missing,
    }


def find_script(source: Path, name: str) -> Path | None:
    for candidate in (source / "engine/Executable" / name, source / "install/Executable" / name, source / name):
        if candidate.is_file():
            return candidate
    return None


def find_engine(source: Path) -> Path | None:
    for candidate in (source / "engine/Executable/Engine.dll", source / "install/Executable/Engine.dll",
                      source / "Engine.dll"):
        if candidate.is_file():
            return candidate
    return None


def run(source: Path, output: Path, engine_path: Path | None = None, write_swing: bool = True) -> dict:
    scripts, missing = [], []
    for name in SCRIPT_FILES:
        path = find_script(source, name)
        if path is None:
            missing.append(name)
            continue
        script = decode_script(path.read_bytes(), name)
        script["source"] = str(path.relative_to(source)) if path.is_relative_to(source) else str(path)
        scripts.append(script)
    document = cameras_document(scripts, missing)
    atomic_write_text(output / "cameras.json", json.dumps(document, indent=2) + "\n")
    result = {"cameras": output / "cameras.json", "scripts": len(scripts), "missing": missing}
    if write_swing:
        engine_path = engine_path or find_engine(source)
        engine = verify_engine(engine_path.read_bytes()) if engine_path else None
        atomic_write_text(output / "swing.json", json.dumps(swing_document(engine), indent=2) + "\n")
        result["swing"] = output / "swing.json"
        result["engine_verified"] = None if engine is None else engine["all_verified"]
    return result


def markdown_rules(script: dict) -> str:
    lines = ["| # | Situation | Event | Prio | When | Then |", "|---|---|---|---|---|---|"]
    for s in script["situations"]:
        when = "; ".join(s["rule"]["when"]) or "always"
        then = " / ".join(f"{t['action']}" + (f" (x{t['weight']})" if t["weight"] > 1 else "")
                          for t in s["rule"]["then"])
        lines.append(f"| {s['index']} | {s['name']} | {s['event_name']} | {s['priority']} | {when} | {then} |")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source", type=Path, default=root / "Library/SourceMedia/pga2005",
                        help="Extracted media root (engine/Executable or install/Executable)")
    parser.add_argument("--output", type=Path, default=root / "Library/Imported/pga2005",
                        help="Directory for cameras.json and swing.json")
    parser.add_argument("--engine", type=Path, help="Engine.dll used to verify swing constants")
    parser.add_argument("--no-swing", action="store_true", help="Skip swing.json")
    parser.add_argument("--rules", metavar="FILE", help="Print a Markdown rule table for one script (e.g. s_camera.stn)")
    parser.add_argument("--simulate", nargs="+", type=int, metavar="MS",
                        help="Simulate the tri-click meter: LEVEL then click times in ms")
    args = parser.parse_args(argv)
    if args.simulate:
        level, clicks = args.simulate[0], args.simulate[1:]
        report = simulate(level, clicks, dt_ms=1)
        report.pop("trace")
        print(json.dumps(report, indent=2))
        return 0
    if args.rules:
        path = find_script(args.source, args.rules)
        if path is None:
            parser.error(f"{args.rules} not found under {args.source}")
        print(markdown_rules(decode_script(path.read_bytes(), args.rules)))
        return 0
    result = run(args.source, args.output, args.engine, not args.no_swing)
    print(json.dumps({k: str(v) if isinstance(v, Path) else v for k, v in result.items()}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
