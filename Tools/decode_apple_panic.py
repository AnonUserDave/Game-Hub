#!/usr/bin/env python3
"""Prepare source-owned Apple Panic tables and pixel masks, without executing 6502.

This decoder accepts only the supplied DOS payload. Prepared media stay in Library.
The optional annotated reference is an analysis aid, never a shipped dependency.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import re
from pathlib import Path

SOURCE_SHA256 = "ce05dc96aa47b5da90e55d49124bdd7f2fc3ec135f43b06d7f96ad95dba53abb"
BASE, LENGTH = 0x3B80, 23168
WINDOWS = {
    "initialization": (0x7465, 0x74A2),
    "bonus_countdown": (0x731C, 0x737F),
    "layout_selector": (0x7552, 0x757C),
    "enemy_level_setup": (0x758B, 0x761D),
    "extra_life": (0x763B, 0x7655),
    "input_and_movement": (0x7A8C, 0x7BD5),
    "ladder_collision": (0x7CD9, 0x7D19),
    "player_fall": (0x803E, 0x80C1),
    "dig_validation": (0x80D3, 0x817F),
    "dig_animation": (0x8272, 0x8311),
    "hourglass_countdown": (0x83C6, 0x8402),
    "fill_animation": (0x8402, 0x848E),
    "enemy_movement": (0x860E, 0x8702),
    "enemy_direction_selection": (0x890B, 0x8A36),
    "enemy_hole_entry_and_escape": (0x8B76, 0x8D63),
    "enemy_round_robin": (0x8E23, 0x8E4B),
    "enemy_speed": (0x751A, 0x753C),
    "enemy_drop_and_scoring": (0x8E61, 0x9109),
    "level_progression": (0x9300, 0x9332),
    "supplied_keyboard_patch": (0x8D80, 0x8D9F),
    "dispatcher": (0x4400, 0x4434),
    "enemy_collision": (0x8702, 0x87C4),
}
# Official 6502 encodings used only to compare a static annotated listing.
OPCODES = {}
for name, modes, values in [
    ("ORA", "ix zp imm abs iy zpx absy absx", "01 05 09 0D 11 15 19 1D"),
    ("AND", "ix zp imm abs iy zpx absy absx", "21 25 29 2D 31 35 39 3D"),
    ("EOR", "ix zp imm abs iy zpx absy absx", "41 45 49 4D 51 55 59 5D"),
    ("ADC", "ix zp imm abs iy zpx absy absx", "61 65 69 6D 71 75 79 7D"),
    ("STA", "ix zp abs iy zpx absy absx", "81 85 8D 91 95 99 9D"),
    ("LDA", "ix zp imm abs iy zpx absy absx", "A1 A5 A9 AD B1 B5 B9 BD"),
    ("CMP", "ix zp imm abs iy zpx absy absx", "C1 C5 C9 CD D1 D5 D9 DD"),
    ("SBC", "ix zp imm abs iy zpx absy absx", "E1 E5 E9 ED F1 F5 F9 FD"),
    ("ASL", "zp imp abs zpx absx", "06 0A 0E 16 1E"),
    ("ROL", "zp imp abs zpx absx", "26 2A 2E 36 3E"),
    ("LSR", "zp imp abs zpx absx", "46 4A 4E 56 5E"),
    ("ROR", "zp imp abs zpx absx", "66 6A 6E 76 7E"),
    ("STX", "zp abs zpy", "86 8E 96"), ("LDX", "imm zp abs zpy absy", "A2 A6 AE B6 BE"),
    ("STY", "zp abs zpx", "84 8C 94"), ("LDY", "imm zp abs zpx absx", "A0 A4 AC B4 BC"),
    ("DEC", "zp abs zpx absx", "C6 CE D6 DE"), ("INC", "zp abs zpx absx", "E6 EE F6 FE"),
    ("BIT", "zp abs", "24 2C"), ("CPX", "imm zp abs", "E0 E4 EC"),
    ("CPY", "imm zp abs", "C0 C4 CC"), ("JMP", "abs ind", "4C 6C"), ("JSR", "abs", "20"),
]:
    for mode, value in zip(modes.split(), values.split()): OPCODES[name, mode] = int(value, 16)
for name, value in zip("BRK PHP CLC PLP SEC RTI PHA CLI RTS PLA SEI DEY TXA TYA TXS TAY TAX CLV TSX INY DEX CLD INX NOP SED".split(),
                       "00 08 18 28 38 40 48 58 60 68 78 88 8A 98 9A A8 AA B8 BA C8 CA D8 E8 EA F8".split()):
    OPCODES[name, "imp"] = int(value, 16)
for name, value in zip("BPL BMI BVC BVS BCC BCS BNE BEQ".split(), "10 30 50 70 90 B0 D0 F0".split()):
    OPCODES[name, "rel"] = int(value, 16)

# Missing/duplicate names in the external annotated file; numeric operands were
# independently read from supplied instructions, then checked across all uses.
REFERENCE_ALIASES = {"FONT_DRAW_TMP": 0x70CE, "PLAYER_Y": 0x7A0D, "BG_PAT_INDEX": 0x7551,
                     "SPRITE_Y_ROW": 0x7A05, "SPRITE_X_COL": 0x7A06, "PLR_SPR_PTRS": 0x7A22,
                     "SUB_7EE0": 0x7EE0, "DIG_ANIM_CTR": 0x826F, "ENEMY_FALL_DEPTH": 0x85E5}

def mode_for(op: str, arg: str) -> str:
    if (op, "rel") in OPCODES: return "rel"
    if not arg: return "imp"
    if arg.startswith("#"): return "imm"
    if arg.startswith("("): return "ind" if op == "JMP" else "ix" if arg.endswith(",X)") else "iy"
    short = bool(re.match(r"^\$[0-9A-F]{1,2}(,|$)", arg))
    return ("zp" if short else "abs") + (arg[-1].lower() if arg.endswith((",X", ",Y")) else "")

def reference_comparison(text: str, source: bytes) -> dict:
    """Re-encode a listing offline and report byte matches, patches and omissions."""
    labels, rows, address = {}, [], 0
    for number, line in enumerate(text.splitlines(), 1):
        token = line.split(";", 1)[0].strip()
        if not token: continue
        words = token.split(None, 1)
        if not line.startswith(" "):
            if len(words) == 2 and words[1].startswith("EQU"):
                labels[words[0]] = int(words[1].split()[1].replace("$", ""), 16)
            else:
                labels[words[0]] = address
                if re.fullmatch(r"L_[0-9A-F]{4}", words[0]) and address != int(words[0][2:], 16):
                    raise ValueError(f"Reference address drift at line {number}")
            continue
        op, arg = words[0], words[1] if len(words) > 1 else ""
        if op == "ORG": address = int(arg[1:], 16); continue
        if op == "HEX": size = len(bytes.fromhex(arg))
        elif op == "DS": size = int(arg.split(",")[0])
        elif op == "DFB": size = len(arg.split(","))
        else:
            mode = mode_for(op, arg)
            size = 1 if mode == "imp" else 3 if mode in ("abs", "absx", "absy", "ind") else 2
        rows.append((address, size, op, arg)); address += size
    labels.update(REFERENCE_ALIASES)
    def value(expression):
        expression = expression.removeprefix("#").strip("()")
        if expression.startswith("$"): return int(expression[1:], 16)
        if re.fullmatch(r"L_[0-9A-F]{4}", expression): return int(expression[2:], 16)
        if "+" in expression:
            name, delta = expression.split("+"); return labels[name] + int(delta)
        return labels[expression]
    mismatches, omitted, compared, matches = [], [], 0, 0
    for address, size, op, arg in rows:
        if not 0x7000 <= address or address + size > BASE + len(source): continue
        try:
            if op == "HEX": encoded = bytes.fromhex(arg)
            elif op == "DS": encoded = bytes([value(arg.split(",")[1])]) * size
            elif op == "DFB": encoded = bytes(value(x) for x in arg.split(","))
            else:
                mode = mode_for(op, arg); encoded = bytes([OPCODES[op, mode]])
                if mode != "imp":
                    operand = arg.replace(",X", "").replace(",Y", "").strip("()")
                    if operand == "ENEMY_TRAPPED": operand = "$8CA1" if op == "JSR" else "$85C7"
                    n = value(operand)
                    if mode == "rel": n = (n - address - 2) & 255
                    encoded += (n & (255 if size == 2 else 65535)).to_bytes(size - 1, "little")
        except (KeyError, ValueError) as error:
            omitted.append({"address": hex(address), "reason": str(error)}); continue
        actual = source[address - BASE:address - BASE + size]
        compared += size
        if encoded == actual: matches += size
        else: mismatches.append({"address": hex(address), "size": size, "reference_sha256": hashlib.sha256(encoded).hexdigest(), "supplied_sha256": hashlib.sha256(actual).hexdigest()})
    return {"range": ["0x7000", hex(BASE + len(source))], "compared_bytes": compared,
            "matching_bytes": matches, "mismatches": mismatches, "omitted": omitted,
            "aliases_from_supplied_operands": {k: hex(v) for k, v in REFERENCE_ALIASES.items()}}


def decode(source: bytes) -> dict:
    if len(source) != LENGTH or hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
        raise ValueError("Apple Panic source identity differs; re-analyze before preparing media")
    def read(address, count):
        if address < BASE or address + count > BASE + LENGTH: raise ValueError("Read outside selected DOS payload")
        return source[address - BASE:address - BASE + count]
    def rows(address, height):
        raw = read(address, height * 3)
        return [sum((raw[y * 3 + x] & 127) << (x * 7) for x in range(3)) for y in range(height)]
    layouts = []
    for index in range(4):
        raw = read(0x4C00 + 48 * index, 48)
        ladders = []
        for slot in range(16):
            if raw[slot] == 0: break
            ladders.append({"x": raw[slot], "top": raw[16 + slot], "bottom": raw[32 + slot]})
        layouts.append(ladders)
    spawns = [[{"x": raw[i], "y": raw[i + 1]} for i in range(0, 16, 2)]
              for raw in [read(0x4E00 + index * 16, 16) for index in range(4)]]
    pointer_names = ["digLeft0", "digRight0", "digLeft1", "digRight1", "walkRight0", "walkLeft0", "climb0", "walkRight1", "walkLeft1", "climb1"]
    sprites = {}
    for index, name in enumerate(pointer_names):
        pointer = int.from_bytes(read(0x7A22 + index * 2, 2), "little")
        sprites[name] = {"width": 21, "height": 16, "rows": rows(pointer, 16), "address": hex(pointer)}
    for kind in range(3):
        for frame in range(2):
            address = 0x5000 + kind * 0x200 + frame * 0x100
            sprites[f"enemy{kind}Frame{frame}"] = {"width": 21, "height": 10, "rows": rows(address, 10), "address": hex(address)}
    return {"schema": 1, "sourceSHA256": SOURCE_SHA256, "layouts": layouts, "spawns": spawns,
            "enemyCounts": list(read(0x761A, 3)), "enemyTypes": [list(read(0x7780 + row * 8, 8)) for row in range(16)],
            "initialBackgroundIndex": read(0x7551, 1)[0], "sprites": sprites,
            "sourceControls": {name: chr(read(0x7A12 + index, 1)[0]) for name, index in [("right", 1), ("left", 2), ("up", 3), ("down", 4), ("dig", 6), ("fill", 8)]}}


def evidence(source: bytes, reference: str | None = None) -> dict:
    result = {"schema": 1, "source": {"sha256": hashlib.sha256(source).hexdigest(), "bytes": len(source), "load_address": hex(BASE), "exclusive_end": hex(BASE + len(source))},
              "method": "Static byte/table decoder and optional reference instruction re-encoding; no CPU emulation or original execution; not REA Evidence",
              "windows": {name: {"start": hex(a), "exclusive_end": hex(z), "sha256": hashlib.sha256(source[a - BASE:z - BASE]).hexdigest()} for name, (a, z) in WINDOWS.items()},
              "limits": ["Payload ends at $95FF; no identity claim for reference $9600..$A7FF", "ROM $F800 pseudo-random stream absent", "Original CPU delay timing and HGR artifact color not reproduced", "M1 acceptance unverified"]}
    if reference is not None: result["reference_comparison"] = reference_comparison(reference, source)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("Library/SourceMedia/retro/apple-panic-apple-ii/program-01.bin"))
    parser.add_argument("--output", type=Path, default=Path("Library/Prepared/apple-panic/apple-panic.json"))
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--reference-asm", type=Path)
    args = parser.parse_args()
    source = args.source.read_bytes(); data = decode(source)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(data, indent=2) + "\n")
    if args.evidence:
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(json.dumps(evidence(source, args.reference_asm.read_text() if args.reference_asm else None), indent=2) + "\n")
    print(f"Prepared {len(data['layouts'])} layouts, {len(data['enemyTypes'])} type rows and {len(data['sprites'])} sprite masks from identity-fenced source")

if __name__ == "__main__": main()
