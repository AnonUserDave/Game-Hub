#!/usr/bin/env python3
"""Import the lean set of original PGA Tour 2005 sounds for the native game.

Standard library only. Reads the extracted install tree (or any directory that
contains the same file names), the original situation scripts (*.stn) and the
per-course SND.INI/CLS.INI, then writes AVFoundation-ready audio plus an
``audio.json`` event table to ``Library/Imported/pga2005/audio``.

* PCM WAVs are copied unchanged when they are already canonical (fmt + data),
  otherwise rewritten as canonical 16-bit PCM WAV (extra chunks removed).
* MS-ADPCM (0x0002) and IMA/DVI-ADPCM (0x0011) WAVs are decoded to 16-bit PCM.
* MP3s are copied unchanged (AVFoundation plays MP3).

No original code is executed. Evidence for every rule is in
docs/research/PGA2005-AUDIO.md. Event semantics come from the decoded
basic.stn / gallery.stn / music.stn data, not from guesses, except where the
JSON explicitly says ``"inferred"``.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import struct
import sys
import wave

SCHEMA_VERSION = 1
ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE = ROOT / "Library/SourceMedia/pga2005/install"
DEFAULT_COURSE_DATA = ROOT / "Library/SourceMedia/pga2005/disc3/COURSES"
DEFAULT_IMAGE = ROOT / "Library/SourceMedia/pga2005/EA-TigerWoodsPGATour2005-CD3-CoursesDisc.B6I"
DEFAULT_OUTPUT = ROOT / "Library/Imported/pga2005/audio"
RULES_FILE = "audio-rules.json"
PRELOAD_LIMIT = 256 * 1024          # PCM bytes; larger files should be streamed
MAX_INPUT_BYTES = 64 * 1024 * 1024  # refuse absurd inputs

# --------------------------------------------------------------------------
# Engine facts (Engine.dll SHA-256 94aa30bb..., static analysis only)
# --------------------------------------------------------------------------
# SoundResponse::getVolume 0x102175de: response type -> CMachineSettings slider.
RESPONSE_CHANNELS = {
    2: "ambient", 8: "ambient",                      # AmbientVolume  +0x47
    3: "golfer", 4: "golfer", 5: "golfer", 6: "golfer",  # GolferVolume +0x4b
    7: "music",                                      # MusicVolume    +0x53
    10: "tv_announce", 11: "tv_announce",            # TVAnnounceVolume +0x57
    12: "crowd",                                     # CrowdVolume    +0x5b
    14: "caddie",                                    # CaddieVolume   +0x4f
    15: "user_init",                                 # UsrInitVolume  +0x5f
}
# SoundResponse::Init 0x102171bc: mode 2 = looping, mode 1 = static (preloaded).
RESPONSE_MODES = {0: "stream", 1: "static", 2: "loop"}
# Script::LoadSituations 0x10207d65 / ScriptSituation ctor 0x102158fd.
CONDITION_OPS = {0: "always", 1: "eq", 2: "ne", 3: "gt", 4: "lt", 5: "any_bits",
                 6: "either_nonzero", 7: "missing_bits", 8: "no_bits"}  # 0x10215b87
# Event value builders: bit -> meaning (vtable slot 1 of each SituationEvent).
EVENT_FIELDS = {
    1: {"name": "swing (ClubSwing 0x1006e370, builder 0x1021424d)", "confidence": "high",
        "bits": {0: "club_mask (0x1021038a: 1 driver,2 wood,4 iron/wedge,0x10 putter,0x20 wedge,0x40/0x80/0x100 long/mid/short iron)",
                 1: "swing_flags (0x102104f9: 1 first stroke/teed,0x10 toe,0x20 heel,0x10000/0x20000 slight toe/heel,0x400..0x8000 shot type)",
                 2: "lie_terrain_flags (0x1000 tee box, 0x8000 on tee, 0x2 rough, 0x8 bunker, 0x80000000 weed/pine)",
                 3: "distance_to_pin_inches", 5: "power_percent (swing+0x305 / 14.0 * 100)",
                 8: "strokes_this_hole", 12: "TrueSwing tempo flags (0x10214548: 1/2, 0 for click meters)",
                 14: "model_flags", 20: "sub_terrain_type", 21: "ball_terrain_flags", 27: "model_type"}},
    2: {"name": "shot (ShotEvent fill 0x102146cb): sub 1 in flight, 2 stopped, 19 before the shot, 11/27 club/turn",
        "confidence": "high (decompiled builder; see PGA2005-COMMENTARY.md)", "available_mask": "0x6fffffdf",
        "bits": {0: "club_mask (0x1021038a, from GetLastClub)",
                 1: "shot_flags (0x102104f9): 1 first stroke or ball on tee, style 0-2 0x400, 3 0x800, 4 punch 0x1000, "
                    "5 lob 0x2000, 6 putt 0x2, 7 chip 0x4, 8 pick 0x4000, 9 0x8000",
                 2: "terrain flags at the golfer's address", 3: "inches to pin: from the ball/predicted end when sub 2 or "
                 "that point is on green (flag 4), else CPlayer::GetDistanceFromHole(false)",
                 4: "inches golfer->ball/predicted end (start distance to pin if bit 1 value == 3)",
                 5: "not provided (reads bit 6)", 6: "hole number (CPlayer vt+0xdc)", 7: "par",
                 8: "strokes this hole before the shot (after it at sub 2)",
                 9: "score code 0x1021088a: stroke = round score to par (+ this hole once holed at sub 2); "
                    "match = 1 up, 2 down, 4 dormie, 8 won, 0x10 lost",
                 10: "miss vs ideal line 0x10212c19: 1 left, 2 right, 4 short, 8 long", 11: "lateral miss inches",
                 12: "flight index (0x3f3, set by the in-flight raisers; 0 otherwise)", 13: "wind speed (course+0x581)",
                 14: "model flags (1 male, 2 female)", 15: "same value as bit 3", 16: "wind vs aim: 1 L->R, 2 R->L, "
                 "4 head, 0x10 tail; vs ideal line 8/0x20", 17: "depth miss inches", 18: "putts this hole (CPlayer+0x15ff)",
                 19: "stroke: strokes behind the leader; match: holes left when dormie else |match score|",
                 20: "green slope/break flags when the point is on green (0x10212e7b), else sub-terrain type",
                 21: "terrain flags at ball/predicted end (0x4000 in hole)", 22: "same value as bit 4",
                 23: "|ideal elevation - ball elevation| (0x102135c1)", 24: "1 ideal higher or level, 2 lower",
                 25: "constant 18 (0x10212b9f)", 26: "game format (settings+0x13: 1 stroke, 2 match, 7 skins ...)",
                 27: "golfer model type (1 Tiger Woods)", 28: "not provided (reads bit 29)",
                 29: "game flags (0x102124e8)", 30: "same value as bit 29"}},
    3: {"name": "ball collision (CGolfBall::CheckForCollisionSound 0x10136ed0, builder 0x102137ad)", "confidence": "high",
        "bits": {2: "sound_id (TCL surface +0x2c / texture +0x23 / structure +0x2c / 804 for pin)",
                 5: "impact_percent = magnitude / 0.5 * 100", 21: "terrain_flags_at_impact (0x40 water)"}},
    5: {"name": "background tick (SituationCommand::BackgroundNoise 0x1006d5c3, builder 0x1021502f)", "confidence": "high",
        "bits": {6: "hole_number", 13: "wind_speed (course+0x581)", 14: "rain_state (0x10215093)"}},
    6: {"name": "music state (CSoundCommand::StartMusic 0x100707e5, ctor 0x102152b4)", "confidence": "high", "bits": {}},
}
# Script::ChooseUserResponse / 0x10216d78: pick uniformly among the variants
# with the lowest play count; ScriptAction exec 0x102160a5 increments it.
SELECTION = ("Uniform random among the response variants with the fewest plays so far "
             "(0x10216d78); action probability byte gates the whole action (random(100)+1 <= p, 0x102160a5); "
             "among matching situations the lowest priority byte wins, then the most conditions, "
             "then the least-fired, then random (Script::DoSituationsMatching 0x1020c1df).")

# Curated events -> original situation descriptions (record order in the .stn).
GAMEPLAY_EVENTS = [
    ("swing.driver.tee", "player hits driver off tee"),
    ("swing.driver.tee_25", "player hits driver off tee 25%"),
    ("swing.driver.tee_50", "player hits driver off tee 50%"),
    ("swing.driver.tee_75", "player hits driver off tee 75%"),
    ("swing.driver.tee_perfect", "player hits driver off tee perfect"),
    ("swing.driver.tee_heel", "player hits driver off tee heel"),
    ("swing.driver.tee_toe", "player hits driver off tee toe"),
    ("swing.driver.generic", "player hits driver (generic lie)"),
    ("swing.wood.generic", "player hits wood (generic lie)"),
    ("swing.wood.generic_perfect", "player hits wood perfect (generic lie)"),
    ("swing.wood.tee", "player hits wood off tee"),
    ("swing.wood.tee_perfect", "player hits wood off tee perfect"),
    ("swing.iron.generic", "player hits iron (generic lie)"),
    ("swing.iron.unknown_lie", "player hits from unknown terrain"),
    ("swing.iron.tee_generic", "player hits iron from tee (generic catch all)"),
    ("swing.iron.tee", "player hits iron off tee"),
    ("swing.iron.tee_25", "player hits iron off tee 25%"),
    ("swing.iron.tee_50", "player hits iron off tee 50%"),
    ("swing.iron.tee_75", "player hits iron off tee 75%"),
    ("swing.iron.tee_perfect", "player hits iron off tee perfect"),
    ("swing.iron.rough", "player hits iron from rough"),
    ("swing.iron.rough_hard", "player hits iron from rough hard"),
    ("swing.iron.pine_needles", "player hits iron from pine needles"),
    ("swing.iron.sand", "player hits iron from sand"),
    ("swing.putt.hard", "player hits putter hard"),
    ("swing.putt.soft", "player hits putter soft"),
    ("swing.flop", "Bug1053 FlopShot"),
    ("ball.cup", "ball falls in cup"),
    ("ball.hit.fairway", "ball hits fairway"),
    ("ball.hit.green_hard", "ball hits green hard"),
    ("ball.hit.green_soft", "ball hits green soft"),
    ("ball.hit.rough", "ball hits rough"),
    ("ball.hit.sand", "ball hits sand"),
    ("ball.hit.water", "ball hits water"),
    ("ball.hit.cartpath", "ball hits cartpath"),
    ("ball.hit.cement", "ball hits cement"),
    ("ball.hit.brush", "ball hits brush"),
    ("ball.hit.branches", "ball hits branches"),
    ("ball.hit.trunk", "ball hits tree trunk"),
    ("ball.hit.flag", "ball hits flag"),
    ("ball.hit.pin", "ball hits pin"),
    ("ball.hit.metal", "ball hits metal"),
    ("ball.hit.pipe", "ball hits pipe"),
    ("ball.hit.glass", "ball hits glass"),
    ("ball.hit.wood", "ball hits wood"),
    ("ball.hit.wooden_sign", "ball hits wooden sign"),
    ("camera.gamebreaker", "Bling Bling - camera transition sound"),
    ("weather.wind_strong", "Strong Wind"),
    ("weather.wind_gusty", "Gusty Wind"),
    ("weather.rain_light", "Light Rain"),
    ("weather.rain_heavy", "Heavy Rain"),
]
CROWD_EVENTS = [
    ("crowd.hole_out", "In Flight - Bling Bling - In Hole"),
    ("crowd.chip_in", "In Flight - Pitch - Chip in to hole"),
    ("crowd.putt_made", "In Flight - putt - Any 1 putt in hole"),
    ("crowd.putt_made_long", "In Flight - putt - 30+ft putt in hole"),
    ("crowd.putt_near_miss", "In Flight - putt - <15ft putt and <1ft from pin"),
    ("crowd.putt_big_miss", "In Flight - putt - Med/Big Miss"),
    ("crowd.approach_close", "In Flight - Approach <4ft to pin"),
    ("crowd.approach_good", "In Flight - Approach - Fairway to Green <20ft"),
    ("crowd.approach_green", "In Flight - Approach - Fairway to Green >20ft"),
    ("crowd.drive_long_fairway", "In Flight - Drive - 275+y in fairway"),
    ("crowd.drive_fairway", "In Flight - Drive - <275y in the fairway"),
    ("crowd.drive_bunker", "In Flight - Drive - into bunker "),
    ("crowd.drive_out_of_bounds", "In Flight - Drive - OB"),
    ("crowd.water", "In Flight - Water hazard"),
    ("crowd.mishit", "In Flight - Generic Mishit"),
    ("crowd.background_cheer", "Background - Random cheers from other holes"),
]
MUSIC_EVENTS = [("music.menu", "Intro music"), ("music.end_of_game", "End of game music")]

# --------------------------------------------------------------------------
# Commentary and shot-result scripts (docs/research/PGA2005-COMMENTARY.md)
# --------------------------------------------------------------------------
COMMENTARY_FILE = "commentary.json"            # runtime rule tables (announcer, analyst, gallery)
COMMENTARY_FILES_FILE = "commentary-files.json"  # per-file provenance, kept out of the runtime table
COMMENTARY_SCRIPTS = (("announcer", "announcer.stn", "sounds_-_commentary", "commentary"),
                      ("analyst", "analyst.stn", "sounds_-_commentary", "commentary"))
# SituationEvent+0x27d, the "available value" mask each constructor sets.
# Condition n compares value[popcount(mask & (bit - 1))] (FUN_10215b87 via
# FUN_10215dc7/0x10215da1: values start at +0x33f), so a condition on a bit
# the event does not provide reads the next provided value.
EVENT_MASKS = {
    1: (0x0830512F, "SwingEvent ctor 0x102141db; CommentatorSwingEvent 0x102157b3; fill 0x1021424d"),
    2: (0x6FFFFFDF, "ShotEvent ctor 0x10214632; CommentatorShotEvent 0x1021574f; fill 0x102146cb"),
    3: (0x00200024, "CollisionEvent ctor 0x1021373d; fill 0x102137ad"),
    4: (0x00000380, "ScoringEvent ctor 0x1021365d; fill 0x102136b3"),
    5: (0x00006040, "BackgroundEvent ctor 0x10214fd0; fill 0x1021502f"),
    7: (0x08005000, "DelayEvent ctor 0x10215346; fill 0x102153a6"),
    8: (0x6FFFFFDF, "ShotPrepEvent ctor 0x10214f9e (ShotEvent values, class 8)"),
    9: (0x778A62CA, "LocationEvent ctor 0x102150e8; CommentatorLocationEvent 0x10215781; fill 0x10215126"),
    10: (0x0C004005, "CommentatorUserEvent ctor 0x102157f2; fill 0x10215824 (plain UserEvent mask is 0)"),
    11: (0x77FFFFFF, "CameraEvent ctor 0x1021387a; fill 0x102138df"),
    12: (0x7C822246, "CommentatorIntroEvent ctor 0x102154a1; fill 0x102154d5"),
}
# Commentary event classes/subs and the ScriptCommand method that raises them
# (exported from Engine.dll; the callers live in the SafeDisc'd TW2005.exe).
COMMENTARY_EVENTS = {
    "1/3": "Swing (ScriptCommand::Swing 0x100609af, CommentatorSwingEvent)",
    "2/1": "ball in flight, once per new flight index (ScriptCommand::CommentatorBallInFlight 0x10062dc5)",
    "2/2": "ball stopped (ScriptCommand::EndShot 0x1005fe8d)",
    "2/19": "before the shot (ScriptCommand::BeginShot 0x10060634 / QueueBeginShotComment 0x100601e8)",
    "9/28": "hole start (ScriptCommand::BeginHole 0x1005f2fd)",
    "9/29": "hole end (ScriptCommand::EndHole 0x1005fc54)",
    "10/10": "club selection (ScriptCommand::OnClubSelectionComment 0x10060bf3)",
    "10/23": "shot setup (ScriptCommand::OnShotSetupComment 0x10061043)",
    "10/24": "aim (ScriptCommand::OnAimComment 0x10060e1b)",
    "12/5": "rough (ScriptCommand::RoughComment 0x1005eec5)",
    "12/6": "tournament/course intro (ScriptCommand::BeginTournament 0x1005e3c5)",
    "12/7": "round format (ScriptCommand::RoundFormatComment 0x1005ea70)",
    "12/8": "weather/course state (ScriptCommand::WeatherComment 0x1005e837)",
    "12/9": "greens (ScriptCommand::GreensComment 0x1005eca9)",
    "12/20": "wind (ScriptCommand::WindComment 0x1005e5fe)",
}
# Hard-coded interpreter rules shared by every commentary line (static analysis).
COMMENTARY_INTERPRETER = {
    "one_line_at_a_time": "action type 8 is dropped (not queued) while the last commentary sample from any script is "
                          "still playing; after 16 consecutive drops the handle is reset (FUN_102160a5, globals "
                          "0x1038c838/0x104503cc)",
    "no_repeat_ms": 20000,
    "no_repeat": "SoundResponse::Invoke 0x102173e2 skips a type 10/11 response whose file equals the previous "
                 "commentary file when the previous one started < 20000 ms ago (StampClock 0x10450298)",
    "frequency": "Script::IsIgnored 0x1020d17b: type 8 uses Script+0x86 = 3 when CMachineSettings flag 0x1000 "
                 "(commentary on, default) else 0 (off); 3 never ignores, 0 always ignores",
    "probability": "random(100)+1 <= action probability, skipped while ForceRandomActions is set (QueuedBeginShot)",
    "response_choice": "uniform among the action's responses with the fewest plays (FUN_10216d78); commentator "
                       "events return type filter 0 (all responses)",
    "sequence": "action file flag bit 0 becomes 0x4000: every response plays in order (ScriptAction ctor 0x10215e27)",
    "slider_default_percent": {"tv_announce": 35, "crowd": 47, "ambient": 100, "golfer": 80, "music": 35,
                               "source": "CMachineSettings::SuggestSound 0x102314f7"},
}
# CSoundCommand::Play(InterfaceSounds) 0x10070247: hard-coded table, response
# id 1000+n, type 2 (ambient slider), mode 1 (static).
INTERFACE_SOUNDS = [(1, "interface.select", "select.wav"), (2, "interface.accept", "accept.wav"),
                    (3, "interface.back", "back.wav"), (4, "interface.highlight", "highlight.wav"),
                    (5, "interface.click", "click.wav"), (6, "interface.scale", "scale.wav"),
                    (7, "interface.back_alt", "back.wav"), (8, "interface.kaching", "kaching.mp3")]
# Sample3D::SetDistances 0x100f1cad defaults and CSoundManager ctor 0x1007ecdd.
DISTANCE_MODEL = {
    "model": "inverse (Miles/DS3D): gain = min / (min + rolloff * (d - min)), clamped for d <= min and d >= max",
    "min_distance_inches": 150.0, "max_distance_inches": 10800.0, "rolloff_factor": 0.8,
    "distance_factor_meters_per_unit": 0.0254,
    "avaudio_environment": {"distanceAttenuationModel": "inverse", "referenceDistance_m": 3.81,
                            "maximumDistance_m": 274.32, "rolloffFactor": 0.8},
    "evidence": "Globals 0x1037e30c=150.0/0x1037e310=10800.0 (never written); AIL_set_3D_rolloff_factor(0.8 @0x1037a09c) "
                "and AIL_set_3D_distance_factor(0.0254) at 0x1007eceb/0x1007ed3a.",
    "positional_rule": "Responses with position (0,0,0) are 2D; others 3D at the event position (CreateSoundFile 0x1007fc5d).",
}


class FormatError(ValueError):
    pass


# --------------------------------------------------------------------------
# RIFF/WAVE reading and ADPCM decoding
# --------------------------------------------------------------------------
MS_ADAPTATION = (230, 230, 230, 230, 307, 409, 512, 614, 768, 614, 512, 409, 307, 230, 230, 230)
MS_DEFAULT_COEFS = ((256, 0), (512, -256), (0, 0), (192, 64), (240, 0), (460, -208), (392, -232))
IMA_INDEX = (-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8)
IMA_STEPS = (7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66,
             73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408,
             449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
             2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630,
             9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767)


def clamp16(value: int) -> int:
    return -32768 if value < -32768 else 32767 if value > 32767 else value


def read_riff(data: bytes) -> dict:
    """Parse a RIFF/WAVE file tolerantly (odd chunks, trailing junk, short data)."""
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise FormatError("Not a RIFF/WAVE file")
    position, chunks, fmt, payload, fact = 12, [], None, None, None
    while position + 8 <= len(data):
        cid = data[position:position + 4]
        size = struct.unpack_from("<I", data, position + 4)[0]
        start = position + 8
        end = min(start + size, len(data))
        chunks.append({"id": cid.decode("latin1"), "bytes": size, "truncated": end - start < size})
        if cid == b"fmt " and fmt is None:
            if end - start < 16:
                raise FormatError("Short fmt chunk")
            tag, channels, rate, byte_rate, align, bits = struct.unpack_from("<HHIIHH", data, start)
            fmt = {"tag": tag, "channels": channels, "rate": rate, "byte_rate": byte_rate,
                   "block_align": align, "bits": bits, "extra": data[start + 18:end] if end - start > 18 else b""}
        elif cid == b"fact" and fact is None and end - start >= 4:
            fact = struct.unpack_from("<I", data, start)[0]
        elif cid == b"data" and payload is None:
            payload = data[start:end]
        if cid == b"\0\0\0\0" and payload is not None:
            break  # observed zero-filled padding after the data chunk
        position = start + size + (size & 1)
    if fmt is None or payload is None:
        raise FormatError("WAVE without fmt or data chunk")
    if not 1 <= fmt["channels"] <= 2 or not 4000 <= fmt["rate"] <= 96000:
        raise FormatError(f"Unsupported channel count/rate {fmt['channels']}/{fmt['rate']}")
    return {"fmt": fmt, "data": payload, "fact": fact, "chunks": chunks}


def decode_ms_adpcm(payload: bytes, channels: int, block_align: int, extra: bytes,
                    total: int | None = None) -> list[int]:
    """Decode Microsoft ADPCM (WAVE_FORMAT_ADPCM 0x0002) to interleaved int16."""
    coefs = list(MS_DEFAULT_COEFS)
    if len(extra) >= 4:
        count = struct.unpack_from("<H", extra, 2)[0]
        if count and len(extra) >= 4 + 4 * count:
            coefs = [struct.unpack_from("<hh", extra, 4 + 4 * i) for i in range(count)]
    header = 7 * channels
    if block_align <= header:
        raise FormatError("MS-ADPCM block too small")
    out: list[int] = []
    for block_start in range(0, len(payload) - header + 1, block_align):
        block = payload[block_start:block_start + block_align]
        predictor = list(block[:channels])
        if any(p >= len(coefs) for p in predictor):
            raise FormatError("MS-ADPCM predictor index out of range")
        offset = channels
        delta = list(struct.unpack_from(f"<{channels}h", block, offset)); offset += 2 * channels
        sample1 = list(struct.unpack_from(f"<{channels}h", block, offset)); offset += 2 * channels
        sample2 = list(struct.unpack_from(f"<{channels}h", block, offset)); offset += 2 * channels
        out.extend(sample2)
        out.extend(sample1)
        channel = 0
        for byte in block[offset:]:
            for nibble in (byte >> 4, byte & 15):
                c1, c2 = coefs[predictor[channel]]
                guess = (sample1[channel] * c1 + sample2[channel] * c2) >> 8
                signed = nibble - 16 if nibble & 8 else nibble
                value = clamp16(guess + signed * delta[channel])
                sample2[channel], sample1[channel] = sample1[channel], value
                delta[channel] = max(16, (MS_ADAPTATION[nibble] * delta[channel]) >> 8)
                out.append(value)
                channel = (channel + 1) % channels
    if total is not None:
        out = out[:total * channels]
    return out


def decode_ima_adpcm(payload: bytes, channels: int, block_align: int,
                     total: int | None = None) -> list[int]:
    """Decode IMA/DVI ADPCM (WAVE_FORMAT_DVI_ADPCM 0x0011) to interleaved int16."""
    header = 4 * channels
    if block_align <= header or (block_align - header) % (4 * channels):
        raise FormatError("IMA-ADPCM block size is not supported")
    out: list[int] = []
    for block_start in range(0, len(payload) - header + 1, block_align):
        block = payload[block_start:block_start + block_align]
        predictor, index = [], []
        for c in range(channels):
            p, i = struct.unpack_from("<hB", block, 4 * c)
            if i > 88:
                raise FormatError("IMA-ADPCM step index out of range")
            predictor.append(p); index.append(i)
        frames = 1 + (len(block) - header) * 2 // channels
        planar = [[predictor[c]] for c in range(channels)]
        offset = header
        while offset + 4 * channels <= len(block):
            for c in range(channels):
                for byte in block[offset:offset + 4]:
                    for nibble in (byte & 15, byte >> 4):
                        step = IMA_STEPS[index[c]]
                        diff = step >> 3
                        if nibble & 1: diff += step >> 2
                        if nibble & 2: diff += step >> 1
                        if nibble & 4: diff += step
                        predictor[c] = clamp16(predictor[c] - diff if nibble & 8 else predictor[c] + diff)
                        index[c] = min(88, max(0, index[c] + IMA_INDEX[nibble]))
                        planar[c].append(predictor[c])
                offset += 4
        for f in range(min(frames, min(len(p) for p in planar))):
            out.extend(planar[c][f] for c in range(channels))
    if total is not None:
        out = out[:total * channels]
    return out


def pcm_samples(riff: dict) -> tuple[list[int] | None, str]:
    """Return interleaved int16 samples (or None if already PCM16) and codec name."""
    fmt, payload = riff["fmt"], riff["data"]
    tag = fmt["tag"]
    if tag == 0xFFFE and len(fmt["extra"]) >= 24:  # WAVE_FORMAT_EXTENSIBLE
        tag = struct.unpack_from("<H", fmt["extra"], 8)[0]
    if tag == 1 and fmt["bits"] == 16:
        return None, "pcm_s16le"
    if tag == 1 and fmt["bits"] == 8:
        return [(b - 128) << 8 for b in payload], "pcm_u8"
    if tag == 2:
        return decode_ms_adpcm(payload, fmt["channels"], fmt["block_align"], fmt["extra"], riff["fact"]), "ms_adpcm"
    if tag == 0x11:
        return decode_ima_adpcm(payload, fmt["channels"], fmt["block_align"], riff["fact"]), "ima_adpcm"
    raise FormatError(f"Unsupported WAVE format tag 0x{tag:04x}/{fmt['bits']} bits")


def write_pcm_wav(channels: int, rate: int, frames: bytes) -> bytes:
    stream = io.BytesIO()
    with wave.open(stream, "wb") as out:
        out.setnchannels(channels)
        out.setsampwidth(2)
        out.setframerate(rate)
        out.writeframes(frames)
    return stream.getvalue()


def is_canonical_pcm(data: bytes, riff: dict) -> bool:
    fmt = riff["fmt"]
    ids = [c["id"] for c in riff["chunks"]]
    return (fmt["tag"] == 1 and fmt["bits"] == 16 and ids == ["fmt ", "data"]
            and riff["chunks"][0]["bytes"] == 16 and not riff["chunks"][1]["truncated"]
            and len(riff["data"]) % (2 * fmt["channels"]) == 0
            and struct.unpack_from("<I", data, 4)[0] == len(data) - 8)


def convert_wav(data: bytes) -> tuple[bytes, dict]:
    """Return AVFoundation-ready WAV bytes and a description of the conversion."""
    riff = read_riff(data)
    fmt = riff["fmt"]
    samples, codec = pcm_samples(riff)
    info = {"source_codec": codec, "source_format_tag": fmt["tag"], "channels": fmt["channels"],
            "sample_rate": fmt["rate"], "source_chunks": [c["id"] for c in riff["chunks"]]}
    if samples is None:
        if is_canonical_pcm(data, riff):
            output, info["conversion"] = data, "copied"
        else:
            usable = len(riff["data"]) - len(riff["data"]) % (2 * fmt["channels"])
            output, info["conversion"] = write_pcm_wav(fmt["channels"], fmt["rate"], riff["data"][:usable]), "rewritten_canonical_pcm"
    else:
        frames = struct.pack(f"<{len(samples)}h", *samples)
        output, info["conversion"] = write_pcm_wav(fmt["channels"], fmt["rate"], frames), f"decoded_{codec}"
    frame_count = (len(output) - 44) // (2 * fmt["channels"])
    info["frames"] = frame_count
    info["duration_s"] = round(frame_count / fmt["rate"], 4)
    return output, info


MP3_RATES = {3: (44100, 48000, 32000), 2: (22050, 24000, 16000), 0: (11025, 12000, 8000)}


def mp3_info(data: bytes) -> dict:
    offset = 0
    if data[:3] == b"ID3" and len(data) >= 10:
        size = data[6:10]
        offset = 10 + ((size[0] & 127) << 21 | (size[1] & 127) << 14 | (size[2] & 127) << 7 | (size[3] & 127))
    for i in range(offset, min(len(data) - 4, offset + 65536)):
        if data[i] == 0xFF and data[i + 1] & 0xE0 == 0xE0:
            version, layer, rate = (data[i + 1] >> 3) & 3, (data[i + 1] >> 1) & 3, (data[i + 2] >> 2) & 3
            if version != 1 and layer == 1 and rate != 3:
                return {"source_codec": "mp3", "sample_rate": MP3_RATES[version][rate],
                        "channels": 1 if data[i + 3] >> 6 == 3 else 2, "conversion": "copied"}
    raise FormatError("No MPEG layer III frame header found")


# --------------------------------------------------------------------------
# Situation scripts (*.stn)
# --------------------------------------------------------------------------
def parse_stn(data: bytes) -> dict:
    """Decode an original situation script (Script::LoadSituationFile 0x10207822)."""
    if len(data) < 28:
        raise FormatError("STN header is truncated")
    version, n_sit, o_sit, n_act, o_act, n_resp, o_resp = struct.unpack_from("<7I", data, 0)
    sit_size = 0x5B if 0x10002 <= version <= 0x10005 else 0x56
    act_size = 0x57 if 0x10003 <= version <= 0x10005 else 0x42
    for count, offset, size in ((n_sit, o_sit, sit_size), (n_act, o_act, act_size), (n_resp, o_resp, 63)):
        if count > 10000 or offset + count * size > len(data):
            raise FormatError("STN table exceeds file")
    situations = []
    for i in range(n_sit):
        record = data[o_sit + i * sit_size:o_sit + (i + 1) * sit_size]
        mask = struct.unpack_from("<I", record, 2)[0]
        ops = struct.unpack_from("<10H", record, 6)
        values = struct.unpack_from("<10I", record, 0x1A)
        conditions, k = [], 0
        for bit in range(31):
            if mask >> bit & 1:
                if k >= 10:
                    raise FormatError("More than 10 STN conditions")
                conditions.append({"bit": bit, "op": CONDITION_OPS.get(ops[k], f"op{ops[k]}"), "value": values[k]})
                k += 1
        situations.append({"index": i, "event_class": record[0], "event_sub": record[1], "mask": mask,
                           "match_any_bit": bool(mask >> 31), "conditions": conditions,
                           "actions": [a for a in struct.unpack_from("<10H", record, 0x42) if a != 0xFFF0],
                           "single_action": bool(struct.unpack_from("<I", record, 0x56)[0] & 1) if sit_size == 0x5B else False,
                           # +0x56: bit 0 one random action, bit 1 key moment (Script::IsKeyMoment 0x1020d8a1)
                           "flags": struct.unpack_from("<I", record, 0x56)[0] if sit_size == 0x5B else 0,
                           "priority": record[0x5A] if sit_size == 0x5B else 100})
    actions = []
    for i in range(n_act):
        record = data[o_act + i * act_size:o_act + (i + 1) * act_size]
        actions.append({"index": i, "type": record[0], "probability": record[1],
                        "flags": struct.unpack_from("<I", record, 2)[0],
                        "responses": [r for r in struct.unpack_from("<30H", record, 6) if r != 0xFFF0]})
    responses = []
    for i in range(n_resp):
        record = data[o_resp + i * 63:o_resp + (i + 1) * 63]
        mode = struct.unpack_from("<I", record, 1)[0]
        response = {"index": i, "type": record[0], "mode": RESPONSE_MODES.get(mode, mode)}
        # Script::BuildResponseObject 0x10209157: 1/9/13 are non-audio
        # responses, 8 indexes the course SND.INI, 16 links another .stn;
        # every other type is a SoundResponse whose path starts at +5.
        if record[0] in (1, 9, 13):
            response |= {"kind": "command", "raw": record[5:].rstrip(b"\0").hex()}
        elif record[0] == 8:
            response |= {"kind": "course_ini_sound", "sound_index": struct.unpack_from("<I", record, 5)[0]}
        elif record[0] == 16:
            response |= {"kind": "link", "response_index": struct.unpack_from("<H", record, 5)[0],
                         "file": record[7:].split(b"\0", 1)[0].decode("latin1")}
        else:
            response |= {"kind": "sound", "file": record[5:].split(b"\0", 1)[0].decode("latin1"),
                         "channel": RESPONSE_CHANNELS.get(record[0], "default_100")}
        responses.append(response)
    # Editor descriptions follow the tables, NUL separated, in record order.
    strings = [s.decode("latin1") for s in data[o_resp + n_resp * 63:].split(b"\0") if s]
    total = n_sit + n_act + n_resp
    if len(strings) >= total:
        for table, start in ((situations, 0), (actions, n_sit), (responses, n_sit + n_act)):
            for item in table:
                item["description"] = strings[start + item["index"]]
    for situation in situations:
        if any(a >= n_act for a in situation["actions"]):
            raise FormatError("STN situation references a missing action")
    for action in actions:
        if action["type"] != 12 and any(r >= n_resp for r in action["responses"]):
            raise FormatError("STN action references a missing response")
    return {"version": version, "situations": situations, "actions": actions, "responses": responses}


def situation_files(stn: dict, situation: dict) -> list[list[str]]:
    """Return one response-file list per action of a situation."""
    groups = []
    for a in situation["actions"]:
        action = stn["actions"][a]
        groups.append([stn["responses"][r]["file"] for r in action["responses"]
                       if stn["responses"][r]["kind"] == "sound"])
    return groups


# --------------------------------------------------------------------------
# INI (Windows profile) files
# --------------------------------------------------------------------------
def parse_ini(text: str) -> list[tuple[str, list[tuple[str, str]]]]:
    """Ordered sections; duplicates preserved. Comments start with ' or ;."""
    sections: list[tuple[str, list[tuple[str, str]]]] = []
    current = None
    for line in text.splitlines():
        line = line.strip()
        if not line or line[0] in "';":
            continue
        if line.startswith("[") and "]" in line:
            current = (line[1:line.index("]")].strip(), [])
            sections.append(current)
        elif "=" in line and current is not None:
            key, value = line.split("=", 1)
            current[1].append((key.strip(), value.strip()))
    return sections


def first_section(sections, name: str) -> dict | None:
    """Win32 GetPrivateProfile semantics: the first matching section wins."""
    for section, items in sections:
        if section.lower() == name.lower():
            values = {}
            for key, value in items:
                values.setdefault(key.lower(), value)
            return values
    return None


def parse_snd_ini(text: str, origin: tuple[float, float, float] | None = None) -> dict:
    """Decode SND.INI as Script::BuildLookupFromIniData 0x1020a045 does."""
    sections = parse_ini(text)
    folders, emitters = {}, []
    for name, items in sections:
        values = {}
        for key, value in items:
            values.setdefault(key.lower(), value)
        if "folder" not in values:
            continue
        folder = values["folder"]
        settings = first_section(sections, folder) or {}
        folders.setdefault(folder, {
            "frequency_percent": int(settings.get("frequency", 100)),
            "volume_percent": int(settings.get("volume", 100)),
            "loop": int(settings.get("loop", 0)) != 0,
            "defined": bool(settings)})
        kind = int(values.get("type", 0))
        points, missing = [], []
        for i in range(int(values.get("points", 0))):
            raw = values.get(f"point{i}")
            if raw is None:
                # ProfileC::GetPosition (Utils.dll 0x10011db0) zeroes x/y/z
                # before lookup, so an absent key reads as (0,0,0).
                missing.append(i)
                points.append([0.0, 0.0, 0.0])
                continue
            parts = [float(v) for v in raw.split(",")]
            if len(parts) != 3:
                raise FormatError(f"{name}: point{i} is not x,y,z")
            points.append(parts)
        files = [values[f"file{i}"] for i in range(int(values.get("files", 0))) if f"file{i}" in values]
        emitter = {"section": name, "hole": int(values.get("hole", 0)), "type": kind, "folder": folder,
                   "files": files, "points_ini": points}
        if missing:
            emitter["missing_points"] = missing
        if kind == 4 and len(points) >= 2:
            emitter["center_ini_feet"] = points[0]
            emitter["radius_inches"] = points[1][0]  # last point is not world-converted
            if any(points[0]) and not all(points[0]):
                raise FormatError(f"{name}: partially zero emitter centre is not modelled")
            if not any(points[0]):
                # BuildLookupFromIniData converts only points with non-zero
                # x, y and z; GetCourseIniSoundPosition then skips the radius
                # test and the (0,0,0) position makes CreateSoundFile 2D: a
                # hole-wide ambience bed that always plays.
                emitter["global_2d"] = True
            elif emitter["radius_inches"] <= 0:
                # GetCourseIniSoundPosition 0x1020ef78 plays only if the
                # listener is within the radius: a zero radius is silent.
                emitter["effectively_silent"] = True
            if origin is not None and not emitter.get("global_2d"):
                x, y, z = points[0]
                emitter["center_world_inches"] = [round(x * 12 - origin[0], 3), round(y * 12, 3),
                                                  round(z * 12 - origin[2], 3)]
        emitters.append(emitter)
    counts: dict[str, int] = {}
    for name, _ in sections:
        counts[name.lower()] = counts.get(name.lower(), 0) + 1
    duplicates = sorted({name for name, _ in sections if counts[name.lower()] > 1})
    return {"folders": folders, "emitters": emitters, "duplicate_sections": duplicates}


def parse_cls_ini(text: str) -> list[dict]:
    """Course Life System sound sections (ActorSound::InitFromIniFile 0x1008ad17)."""
    sounds = []
    sections = parse_ini(text)
    users = {}
    for name, items in sections:
        values = {k.lower(): v for k, v in items}
        if "sound" in values:
            users.setdefault(values["sound"].lower(), []).append(name)
    for name, items in sections:
        values = {k.lower(): v for k, v in items}
        if values.get("type", "").lower() != "sound" or "file" not in values:
            continue
        path = PureWindowsPathLike(values["file"])
        sounds.append({"section": name, "source_file": values["file"], "folder": path[-2] if len(path) > 1 else "",
                       "file": path[-1], "volume": float(values.get("volume", 1.0) or 1.0),
                       "repeat_ms": [int(values.get("repeatlow", 0)), int(values.get("repeathigh", 0))],
                       "distance_feet": [float(values.get("distancelow", 0)), float(values.get("distancehigh", 0))],
                       "distance_inches": [float(values.get("distancelow", 0)) * 12, float(values.get("distancehigh", 0)) * 12],
                       "actors": users.get(name.lower(), [])})
    return sounds


def PureWindowsPathLike(value: str) -> list[str]:
    return [p for p in re.split(r"[\\/]+", value) if p and p not in (".", "..")]


# --------------------------------------------------------------------------
# Source discovery
# --------------------------------------------------------------------------
class SourceIndex:
    """Case-insensitive file lookup over an install tree or a flat directory."""

    def __init__(self, root: Path):
        self.root = root
        self.by_name: dict[str, list[Path]] = {}
        self.by_folder: dict[str, Path] = {}
        for directory, _, names in os.walk(root):
            for name in names:
                path = Path(directory) / name
                self.by_name.setdefault(name.lower(), []).append(path)
                self.by_folder[f"{Path(directory).name}/{name}".lower()] = path

    def find(self, name: str, folder: str | None = None, prefer: str | None = None) -> Path | None:
        candidates = self.by_name.get(name.lower(), [])
        if folder:
            hit = self.by_folder.get(f"{folder}/{name}".lower())
            if hit:
                return hit
            # A same-named file in another folder may be different audio
            # (e.g. amb_gen_06.wav exists in three folders): only accept a
            # unique name, as in a flat provided directory.
            return candidates[0] if len(candidates) == 1 else None
        if prefer:
            preferred = [p for p in candidates if prefer.lower() in str(p.relative_to(self.root)).lower()]
            candidates = preferred or candidates
        return sorted(candidates)[0] if candidates else None

    def relative(self, path: Path) -> str:
        return str(PurePosixPath(*path.relative_to(self.root).parts))


def find_with_engine_fallback(index: SourceIndex, name: str, folder: str | None, prefer: str) -> tuple[Path | None, str | None]:
    """SoundResponse::SetAbsolutePath 0x10217277 retries .wav as .mp3."""
    hit = index.find(name, folder, prefer)
    if hit:
        return hit, None
    if name.lower().endswith(".wav"):
        alt = name[:-4] + ".mp3"
        hit = index.find(alt, folder, prefer)
        if hit:
            return hit, "engine .wav->.mp3 fallback (SetAbsolutePath 0x10217277)"
    return None, None


class CourseSource:
    """Reads SND.INI/CLS.INI/TCR origin from a directory or the read-only B6I image."""

    def __init__(self, directory: Path | None, image: Path | None):
        self.directory = directory if directory and directory.is_dir() else None
        self.image = image if image and image.is_file() else None
        self._iso = None
        self._entries = None

    def _image_entries(self):
        if self._entries is None:
            sys.path.insert(0, str(Path(__file__).resolve().parent))
            from inspect_pga2005 import ISO9660  # read-only ISO9660/B6I reader
            self._iso = ISO9660(self.image)
            self._entries = {e["path"].upper(): e for e in self._iso.files()}
        return self._entries

    def close(self):
        if self._iso is not None:
            self._iso.close()

    def read(self, code: str, relative: str, limit: int | None = None) -> tuple[bytes, str] | None:
        if self.directory:
            path = self.directory
            for part in [code, *relative.split("/")]:
                match = [p for p in path.iterdir() if p.name.lower() == part.lower()] if path.is_dir() else []
                if not match:
                    path = None
                    break
                path = match[0]
            if path and path.is_file():
                with path.open("rb") as stream:
                    return stream.read(limit if limit else MAX_INPUT_BYTES), str(path)
        if self.image:
            entry = self._image_entries().get(f"COURSES/{code}/{relative}".upper())
            if entry:
                size = min(entry["bytes"], limit or entry["bytes"])
                if size > MAX_INPUT_BYTES:
                    raise FormatError("Course file too large")
                return self._iso.read(entry["logical_sector"] * 2048, size), f"{self.image.name}:{entry['path']}"
        return None


# --------------------------------------------------------------------------
# Import
# --------------------------------------------------------------------------
def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def atomic_write(path: Path, data: bytes):
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_name(path.name + ".partial")
    partial.write_bytes(data)
    partial.replace(path)


class Importer:
    def __init__(self, source: Path, output: Path, courses: list[str], course_source: CourseSource,
                 music: bool = False, dry_run: bool = False, materials_root: Path | None = None,
                 commentary: bool = True):
        self.materials_root = materials_root
        self.commentary = commentary
        # Commentary MP3s (about 3,290 files) are listed separately so that
        # audio.json stays small; see COMMENTARY_FILES_FILE.
        self.commentary_files: dict[str, dict] = {}
        self.index = SourceIndex(source)
        self.output = output
        self.courses = courses
        self.course_source = course_source
        self.music = music
        self.dry_run = dry_run
        self.files: dict[str, dict] = {}
        self.warnings: list[str] = []
        self.missing: list[dict] = []
        self.by_source: dict[Path, str] = {}

    def add(self, source: Path, category: str, folder: str | None = None) -> str:
        if source in self.by_source:
            return self.by_source[source]
        relative = PurePosixPath(category, *(folder,) if folder else (), source.name)
        if source.stat().st_size > MAX_INPUT_BYTES:
            raise FormatError(f"{source} is too large")
        data = source.read_bytes()
        suffix = source.suffix.lower()
        if suffix == ".wav":
            output, info = convert_wav(data)
        elif suffix == ".mp3":
            output, info = data, mp3_info(data)
        else:
            raise FormatError(f"Unsupported audio file {source.name}")
        key = str(relative)
        table = self.commentary_files if category == "commentary" else self.files
        if key in table:
            raise FormatError(f"Two different sources map to {key}")
        if not self.dry_run:
            atomic_write(self.output / relative, output)
        info.update({"path": key, "bytes": len(output), "sha256": sha256(output),
                     "preload": suffix == ".wav" and len(output) <= PRELOAD_LIMIT,
                     "source": {"path": self.index.relative(source), "bytes": len(data), "sha256": sha256(data)}})
        table[key] = info
        self.by_source[source] = key
        return key

    def resolve(self, names, category, prefer, folder=None, context=""):
        keys = []
        for name in names:
            path, note = find_with_engine_fallback(self.index, name, folder, prefer)
            if path is None:
                self.missing.append({"file": name, "folder": folder, "context": context})
                continue
            key = self.add(path, category, folder)
            if note:
                table = self.commentary_files if category == "commentary" else self.files
                notes = table[key].setdefault("notes", [])
                if f"referenced as {name}: {note}" not in notes:
                    notes.append(f"referenced as {name}: {note}")
            keys.append(key)
        return keys

    def stn(self, name: str) -> tuple[dict, dict]:
        path = self.index.find(name)
        if path is None:
            raise FileNotFoundError(f"{name} not found under {self.index.root}")
        data = path.read_bytes()
        return parse_stn(data), {"path": self.index.relative(path), "sha256": sha256(data)}

    def curated(self, stn: dict, table, category, prefer, script, unresolved, events):
        by_description = {}
        for s in stn["situations"]:
            by_description.setdefault(s.get("description", ""), s)
        for event, description in table:
            situation = by_description.get(description)
            if situation is None:
                unresolved.append({"event": event, "script": script, "description": description})
                continue
            groups = situation_files(stn, situation)
            names = sorted({n for g in groups for n in g})
            keys = self.resolve(names, category, prefer, context=f"{script} situation {situation['index']}")
            responses = [stn["responses"][r] for a in situation["actions"] for r in stn["actions"][a]["responses"]
                         if stn["responses"][r]["kind"] == "sound"]
            actions = [stn["actions"][a] for a in situation["actions"]]
            modes = {r["mode"] for r in responses}
            channels = {r["channel"] for r in responses}
            events[event] = {
                "files": keys,
                "action_groups": [[k for k in keys if PurePosixPath(k).name.lower() in {n.lower() for n in g}] for g in groups],
                "gain": 1.0,
                "channel": channels.pop() if len(channels) == 1 else sorted(channels),
                "loop": modes == {"loop"},
                "preload": modes == {"static"},
                "random": "least_played_uniform" if max((len(g) for g in groups), default=0) > 1 else "single",
                "play_all_actions": not situation["single_action"],
                "probability_percent": [a["probability"] for a in actions],
                "conditions": {"event_class": situation["event_class"], "event_sub": situation["event_sub"],
                               "all": situation["conditions"], "priority": situation["priority"]},
                "rule": {"script": script, "situation": situation["index"], "description": description},
            }

    def run(self) -> dict:
        events, unresolved, rules, sources = {}, [], {}, {}
        basic, sources["basic.stn"] = self.stn("basic.stn")
        rules["basic"] = basic
        self.curated(basic, GAMEPLAY_EVENTS, "gameplay", "sounds_-_basic", "basic.stn", unresolved, events)
        for name, event in events.items():
            # Swing/collision events carry the player/impact position (3D);
            # weather and camera events are listener-relative.
            event["positional"] = name.startswith(("swing.", "ball."))
        gallery, sources["gallery.stn"] = self.stn("gallery.stn")
        rules["gallery"] = gallery
        self.curated(gallery, CROWD_EVENTS, "crowd", "sounds_-_gallery", "gallery.stn", unresolved, events)
        for name, event in events.items():
            if name.startswith("crowd."):
                # Action flag 0x10 places the sound 750-3000 units from the
                # event (0x102160a5 case 9); otherwise it is 2D.
                flags = [gallery["actions"][a]["flags"] for a in gallery["situations"][event["rule"]["situation"]]["actions"]]
                event["positional"] = any(f & 0x10 for f in flags)
        # Every crowd file the original gallery rules can play (lean but complete).
        crowd_names = sorted({gallery["responses"][r]["file"] for a in gallery["actions"]
                              for r in a["responses"] if gallery["responses"][r]["kind"] == "sound"})
        self.resolve(crowd_names, "crowd", "sounds_-_gallery", context="gallery.stn responses")
        for number, event, name in INTERFACE_SOUNDS:
            keys = self.resolve([name], "interface", "sounds_-_interface", context="CSoundCommand::Play 0x10070247")
            events[event] = {"files": keys, "gain": 1.0, "channel": "ambient", "loop": False, "preload": True,
                             "random": "single", "positional": False,
                             "rule": {"engine": "CSoundCommand::Play(InterfaceSounds) 0x10070247", "enum": number}}
        if self.music:
            music, sources["music.stn"] = self.stn("music.stn")
            rules["music"] = music
            self.curated(music, MUSIC_EVENTS, "music", "sounds_-_music", "music.stn", unresolved, events)
            for name in ("music.menu", "music.end_of_game"):
                if name in events:
                    events[name]["positional"] = False
        commentary = self.commentary_tables(gallery, sources)
        courses = {}
        for code in self.courses:
            courses[code] = self.course(code)
        self.missing.sort(key=lambda m: (m["context"], m["file"]))
        surface = surface_table(basic, events)
        totals = {}
        for info in self.files.values():
            category = info["path"].split("/", 1)[0]
            totals[category] = totals.get(category, 0) + info["bytes"]
        return {
            "schema_version": SCHEMA_VERSION,
            "generator": "Tools/import_pga2005_audio.py",
            "method": "Static decoding of original data files; no original code executed. See docs/research/PGA2005-AUDIO.md.",
            "units": {"world": "inches (AIL_set_3D_distance_factor 0.0254)", "ini_coordinates": "feet; world = (x*12-origin.x, y*12, z*12-origin.z)"},
            "playback_model": {
                "volume": "gain = clamp(channel_slider_percent * response_volume_scale / 100, 0, 1) (SoundResponse::getVolume 0x102175de)",
                "channels": sorted(set(RESPONSE_CHANNELS.values())),
                "selection": SELECTION,
                "impact_gate": "collision sounds are skipped when impact magnitude < 0.1; magnitude does not scale volume (SoundResponse::Invoke 0x102173e2)",
                "distance": DISTANCE_MODEL,
            },
            "event_fields": EVENT_FIELDS,
            "events": dict(sorted(events.items())),
            "surface_sound_ids": surface,
            "courses": courses,
            "files": dict(sorted(self.files.items())),
            "commentary_files": self.commentary_files,  # moved to COMMENTARY_FILES_FILE by write_outputs()
            "commentary_bytes": sum(f["bytes"] for f in self.commentary_files.values()),
            "totals_bytes": dict(sorted(totals.items())) | {"all": sum(totals.values())},
            "missing_sources": self.missing,
            "unresolved_events": unresolved,
            "warnings": self.warnings,
            "provenance": {"source_root": str(self.index.root), "scripts": sources},
            "rules_file": RULES_FILE,
            "commentary_file": COMMENTARY_FILE,
            "rules": rules,  # moved to RULES_FILE by write_outputs()
            "commentary": commentary,  # moved to COMMENTARY_FILE by write_outputs()
        }

    def script_table(self, stn: dict, script: str, category: str, prefer: str, classes=None) -> dict:
        """Runtime form of one decoded situation script: every situation of the
        selected event classes with its literal conditions, all actions and all
        responses (resolved to imported paths; None is silence: an absent file
        or an editor placeholder such as "no commentary")."""
        situations = [s for s in stn["situations"] if classes is None or s["event_class"] in classes]
        responses, silent, missing = [], 0, []
        for response in stn["responses"]:
            entry = {"t": response["type"]}
            if response["kind"] == "sound":
                name = response["file"]
                path, note = find_with_engine_fallback(self.index, name, None, prefer)
                if path is None:
                    entry["f"], entry["n"] = None, name
                    if name.lower().endswith((".wav", ".mp3")):
                        missing.append(name)
                    else:
                        silent += 1
                else:
                    entry["f"] = self.resolve([name], category, prefer, context=f"{script} response {response['index']}")[0]
            else:
                entry["f"], entry["n"] = None, response.get("kind", "")
            responses.append(entry)
        table = {
            "source": script,
            "situations": [{"i": s["index"], "c": s["event_class"], "s": s["event_sub"], "p": s["priority"],
                            "one": s["single_action"], "key": bool(s["flags"] & 2), "any": s["match_any_bit"],
                            "if": [[c["bit"], c["op"], c["value"]] for c in s["conditions"]],
                            "do": s["actions"], "d": s.get("description", "")} for s in situations],
            "actions": [{"t": a["type"], "p": a["probability"], "fl": a["flags"],
                         # File flag bit 0 becomes 0x4000 "play every response in order" unless the
                         # action is positional (0x10/0x400/0x1000) or type 0xff (ctor 0x10215e27).
                         "seq": bool(a["flags"] & 1) and not (a["flags"] & 0x1410) and a["type"] != 0xFF,
                         "r": a["responses"]} for a in stn["actions"]],
            "responses": responses,
        }
        summary = {"situations": len(table["situations"]), "actions": len(stn["actions"]), "responses": len(responses),
                   "files": len({r["f"] for r in responses if r["f"]}), "silent_placeholders": silent,
                   "missing_files": sorted(set(missing)),
                   "event_class_subs": sorted({f"{s['c']}/{s['s']}" for s in table["situations"]},
                                              key=lambda k: tuple(map(int, k.split("/"))))}
        return table, summary

    def commentary_tables(self, gallery: dict, sources: dict) -> dict:
        """announcer.stn and analyst.stn (TV commentary) plus the gallery's
        class-2 shot rules, all driven by the same shot-event values."""
        scripts, summary, warnings = {}, {}, []
        table, info = self.script_table(gallery, "gallery.stn", "crowd", "sounds_-_gallery", classes={2})
        scripts["gallery"], summary["gallery"] = table, info
        if self.commentary:
            for name, filename, prefer, category in COMMENTARY_SCRIPTS:
                try:
                    stn, sources[filename] = self.stn(filename)
                except FileNotFoundError:
                    warnings.append(f"{filename} not found; {name} commentary not imported")
                    continue
                scripts[name], summary[name] = self.script_table(stn, filename, category, prefer)
        self.warnings.extend(warnings)
        return {
            "schema_version": SCHEMA_VERSION,
            "generator": "Tools/import_pga2005_audio.py",
            "method": "Static decoding of announcer.stn, analyst.stn and gallery.stn; no original code executed. "
                      "See docs/research/PGA2005-COMMENTARY.md.",
            "event_masks": {str(k): v[0] for k, v in sorted(EVENT_MASKS.items())},
            "event_mask_evidence": {str(k): v[1] for k, v in sorted(EVENT_MASKS.items())},
            "event_fields": {str(k): v for k, v in EVENT_FIELDS.items() if k in (1, 2)},
            "commentary_events": COMMENTARY_EVENTS,
            "interpreter": COMMENTARY_INTERPRETER,
            "selection": SELECTION,
            "scripts": scripts,
            "summary": summary,
        }

    def course(self, code: str) -> dict:
        result = {"ambient_folders": {}, "emitters": [], "course_life_sounds": [], "provenance": {}}
        if self.materials_root:
            materials = self.materials_root / code / "materials.json"
            if materials.is_file():
                result["surface_sound_ids"] = material_sound_ids(json.loads(materials.read_text()))
                result["provenance"]["materials"] = {"source": str(materials), "sha256": sha256(materials.read_bytes())}
        tcr = self.course_source.read(code, f"{code}.TCR", limit=0x324)
        origin = None
        if tcr and len(tcr[0]) >= 0x324:
            origin = struct.unpack_from("<3f", tcr[0], 0x318)
            result["world_origin"] = [round(v, 4) for v in origin]
            result["provenance"]["origin"] = {"source": tcr[1], "offset": "0x318"}
        snd = self.course_source.read(code, "SND.INI")
        if snd is None:
            self.warnings.append(f"{code}: SND.INI not found; no ambient emitters imported")
        else:
            text = snd[0].decode("latin1")
            parsed = parse_snd_ini(text, origin)
            result["provenance"]["snd_ini"] = {"source": snd[1], "sha256": sha256(snd[0])}
            if parsed["duplicate_sections"]:
                self.warnings.append(f"{code}: duplicate SND.INI sections {parsed['duplicate_sections']}; first occurrence used")
            for folder, settings in parsed["folders"].items():
                result["ambient_folders"][folder] = settings | {
                    "gain": settings["volume_percent"] / 100.0,
                    "trigger": "per background tick: random(100)+1 <= frequency_percent (action probability)"}
            for emitter in parsed["emitters"]:
                # Emitter files are stored by name; the imported path is
                # ambient/<folder>/<name> (see ambient_folders[folder].files).
                if not emitter.get("effectively_silent"):
                    keys = self.resolve(emitter["files"], "ambient", "courses_-_generic",
                                        folder=emitter["folder"], context=f"{code} SND.INI {emitter['section']}")
                    pool = result["ambient_folders"][emitter["folder"]].setdefault("files", [])
                    pool.extend(k for k in keys if k not in pool)
                    emitter["files"] = [PurePosixPath(k).name for k in keys]
                if emitter["type"] == 4 and "missing_points" not in emitter:
                    emitter.pop("points_ini")
                result["emitters"].append(emitter)
            for settings in result["ambient_folders"].values():
                settings["files"] = sorted(settings.get("files", []))
            silent = [e["section"] for e in result["emitters"] if e.get("effectively_silent")]
            if silent:
                self.warnings.append(f"{code}: {len(silent)} SND.INI emitters lack a radius point and are silent in the original: {silent}")
        cls = self.course_source.read(code, "CLS/CLS.INI")
        if cls is not None:
            result["provenance"]["cls_ini"] = {"source": cls[1], "sha256": sha256(cls[0])}
            for sound in parse_cls_ini(cls[0].decode("latin1")):
                sound["files"] = self.resolve([sound["file"]], "ambient", "courses_-_generic",
                                              folder=sound["folder"], context=f"{code} CLS.INI {sound['section']}")
                sound["trigger"] = ("when not playing, cooldown random(RepeatLow..RepeatHigh) ms elapsed, actor within "
                                    "DistanceHigh and visible: 1/512 chance per frame (CourseLifeManager::UpdateActorSounds 0x10097c8e)")
                result["course_life_sounds"].append(sound)
        return result


def material_sound_ids(materials: dict) -> dict:
    """Effective sound id per surface: TCL record +0x2c, else texture section +0x23
    (CourseDataManager::GetTerrainSound, CourseData.dll 0x10009a20)."""
    table: dict[str, dict] = {}
    for material in materials.get("materials", []):
        raw = bytes.fromhex(material.get("provenance", {}).get("texture_section", {}).get("raw_hex", ""))
        fallback = struct.unpack_from("<h", raw, 0x23)[0] if len(raw) >= 0x25 else -1
        for surface in material.get("surface_types", []):
            sound_id = surface.get("sound_id", -1)
            effective = sound_id if sound_id != -1 else fallback
            entry = table.setdefault(str(effective), {"surfaces": set(), "textures": set(), "material_ids": set()})
            entry["surfaces"].add(surface.get("name") or "(unnamed)")
            entry["textures"].add(material.get("name", ""))
            entry["material_ids"].add(material.get("id"))
    return {k: {"surfaces": sorted(v["surfaces"]), "material_ids": sorted(i for i in v["material_ids"] if i is not None),
                "textures": sorted(v["textures"])[:12], "texture_count": len(v["textures"])}
            for k, v in sorted(table.items(), key=lambda kv: int(kv[0]))}


def surface_table(basic: dict, events: dict) -> dict:
    """Map TCL sound ids to impact events from the class-3 collision rules."""
    by_situation = {e["rule"]["situation"]: name for name, e in events.items() if e["rule"].get("script") == "basic.stn"}
    table = {}
    for s in basic["situations"]:
        if s["event_class"] != 3:
            continue
        ids = [c["value"] for c in s["conditions"] if c["bit"] == 2 and c["op"] == "eq"]
        extra = [c for c in s["conditions"] if c["bit"] != 2]
        for sound_id in ids:
            table.setdefault(str(sound_id), []).append({"event": by_situation.get(s["index"]), "requires": extra,
                                                         "priority": s["priority"]})
    table["*"] = [{"event": by_situation.get(s["index"]), "requires": s["conditions"], "priority": s["priority"]}
                  for s in basic["situations"] if s["event_class"] == 3 and not any(c["bit"] == 2 for c in s["conditions"])]
    return dict(sorted(table.items()))


def write_outputs(output: Path, result: dict):
    """audio.json is the runtime table; the full decoded rule tables (large,
    needed only for a faithful rule engine) go to a separate file."""
    result = dict(result)
    rules = result.pop("rules")
    commentary = result.pop("commentary", None)
    commentary_files = result.pop("commentary_files", {})
    if commentary is not None:
        atomic_write(output / COMMENTARY_FILE, (json.dumps(commentary, separators=(",", ":")) + "\n").encode())
        atomic_write(output / COMMENTARY_FILES_FILE, (json.dumps({
            "schema_version": SCHEMA_VERSION, "generator": "Tools/import_pga2005_audio.py",
            "note": "Commentary MP3s are byte-identical copies of the original files.",
            "files": dict(sorted(commentary_files.items()))}, indent=1) + "\n").encode())
    atomic_write(output / RULES_FILE, (json.dumps({
        "schema_version": SCHEMA_VERSION, "generator": "Tools/import_pga2005_audio.py",
        "condition_ops": CONDITION_OPS, "event_fields": EVENT_FIELDS, "selection": SELECTION,
        "scripts": result["provenance"]["scripts"], "rules": rules}, separators=(",", ":")) + "\n").encode())
    text = json.dumps(result, indent=1)
    # Keep numeric vectors on one line so the table stays readable and small.
    text = re.sub(r"\[\s+(-?[\d.e+-]+(?:,\s+-?[\d.e+-]+)*)\s+\]",
                  lambda m: "[" + ", ".join(v.strip() for v in m.group(1).split(",")) + "]", text)
    atomic_write(output / "audio.json", (text + "\n").encode())


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE, help="Extracted install tree or a directory with the same file names")
    parser.add_argument("--course-data", type=Path, default=DEFAULT_COURSE_DATA, help="Directory with <CODE>/SND.INI, CLS/CLS.INI, <CODE>.TCR")
    parser.add_argument("--courses-image", type=Path, default=DEFAULT_IMAGE, help="Courses disc B6I, read-only fallback for course files")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--materials-root", type=Path, default=ROOT / "Library/Imported/pga2005",
                        help="Optional <CODE>/materials.json (from prepare_pga2005.py) for the surface -> sound id table")
    parser.add_argument("--courses", nargs="*", default=["PBL", "TUR"])
    parser.add_argument("--music", action="store_true", help="Also import the menu/end-of-game MP3s")
    parser.add_argument("--no-commentary", action="store_true",
                        help="Skip the TV commentary MP3s (about 163 MB); the gallery shot rules are still written")
    parser.add_argument("--dry-run", action="store_true", help="Decode and report without writing files")
    parser.add_argument("--strict", action="store_true", help="Fail on unresolved events or missing course data")
    args = parser.parse_args(argv)
    if not args.source.is_dir():
        parser.error(f"source directory not found: {args.source}")
    course_source = CourseSource(args.course_data, args.courses_image)
    try:
        result = Importer(args.source, args.output, [c.upper() for c in args.courses], course_source,
                          music=args.music, dry_run=args.dry_run, materials_root=args.materials_root,
                          commentary=not args.no_commentary).run()
    finally:
        course_source.close()
    missing_course_data = [w for w in result["warnings"] if "not found" in w]
    if args.strict and (result["unresolved_events"] or missing_course_data):
        print(json.dumps({"unresolved": result["unresolved_events"], "warnings": missing_course_data}, indent=2))
        return 1
    if not args.dry_run:
        write_outputs(args.output, result)
    totals = result["totals_bytes"]
    print(f"Imported {len(result['files'])} files ({totals['all'] / 1e6:.2f} MB), {len(result['events'])} events.")
    for category, size in totals.items():
        if category != "all":
            print(f"  {category:10s} {size / 1e6:7.2f} MB")
    commentary = result["commentary"]["summary"]
    if result["commentary_files"]:
        print(f"  commentary {result['commentary_bytes'] / 1e6:7.2f} MB in {len(result['commentary_files'])} MP3s "
              f"(copied unchanged; {COMMENTARY_FILES_FILE})")
    for name, info in commentary.items():
        print(f"  {name}: {info['situations']} situations, {info['actions']} actions, {info['responses']} responses, "
              f"{info['files']} files, {info['silent_placeholders']} silent placeholders, "
              f"{len(info['missing_files'])} missing files")
    if result["missing_sources"]:
        print(f"  {len(result['missing_sources'])} referenced files are absent from the original media (listed in audio.json).")
    for warning in result["warnings"]:
        print(f"  warning: {warning}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
