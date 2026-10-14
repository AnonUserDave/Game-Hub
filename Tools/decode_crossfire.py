#!/usr/bin/env python3
"""Decode verified Crossfire tables and seven-phase HGR sprites, without execution.

Original pixels stay in ignored Library/Imported/crossfire. The evidence record
contains identities, offsets and interpretations only, not sprite bytes.
"""
import argparse
import hashlib
import json
from pathlib import Path

from analyze_crossfire_ghidra import SOURCE_SHA256, address_image

SPRITES = {"player": 0x6800, "enemy-0": 0x7AC0, "enemy-1": 0x7800,
           "enemy-2": 0x7BC0, "enemy-3": 0x7980, "explosion-0": 0x7E80,
           "explosion-1": 0x6900, "explosion-2": 0x7F80, "ammo": 0x7D00,
           "projectile": 0x6F00, "bonus-0": 0x8100, "bonus-1": 0x8200,
           "bonus-2": 0x8300, "bonus-3": 0x8400, "bonus-idle": 0x6300}


def sprite_rows(image: bytes, address: int, phase: int = 0) -> list[list[int]]:
    if not 0 <= phase < 7 or address < 0x300 or address + 2 > len(image) + 0x300:
        raise ValueError("Invalid sprite address or horizontal phase")
    start = address - 0x300
    width, height = image[start:start + 2]
    if not 1 <= width <= 8 or not 1 <= height <= 32 or start + 2 + width * height * 7 > len(image):
        raise ValueError("Invalid sprite dimensions or truncated seven-phase data")
    rows = []
    for y in range(height):
        offset = start + 2 + y * width * 7 + phase * width
        rows.append([(image[offset + x // 7] >> (x % 7)) & 1 for x in range(width * 7)])
    return rows


def bonus_sprite_usage(image: bytes) -> dict:
    """Read the selected draw routine's anchors and kind-indexed sprite table.

    Address images come from the source-identity gate; this inspects operands
    and table words statically rather than executing the original CPU.
    """
    def immediate(address, opcode):
        offset = address - 0x300
        if image[offset] != opcode:
            raise ValueError(f"Unexpected bonus drawing instruction at ${address:04X}")
        return image[offset + 1]
    offset_x, offset_y = image[0x4C14 - 0x300:0x4C16 - 0x300]
    subtract_x = immediate(0x57A1, 0xE9)
    subtract_y = immediate(0x57B1, 0xE9)
    collected_x = immediate(0x5793, 0xA9)
    collected_y = immediate(0x5798, 0xA9)
    table = image[0x57D5 - 0x300:0x57E1 - 0x300]
    pointers = [int.from_bytes(table[i:i + 2], "little") for i in range(0, 12, 2)]
    if pointers[:5] != [SPRITES["bonus-idle"], *[SPRITES[f"bonus-{i}"] for i in range(4)]] or pointers[5] != 0:
        raise ValueError("Selected Crossfire bonus sprite table differs")
    idle_width, idle_height = image[pointers[0] - 0x300:pointers[0] - 0x300 + 2]
    return {"drawRoutine": 0x5780, "pointerTable": 0x57D5,
            "idle": {"kind": 0, "name": "bonus-idle", "address": pointers[0],
                     "anchorDelta": [offset_x - subtract_x, offset_y - subtract_y], "width": idle_width * 7, "height": idle_height},
            "collected": {"kinds": [1, 2, 3, 4], "names": [f"bonus-{i}" for i in range(4)],
                          "anchorDelta": [offset_x - subtract_x - collected_x, offset_y - subtract_y + collected_y]},
            "expiredKind": 5, "expiredPointer": pointers[5]}


def decode(root: Path, evidence_path: Path | None = None) -> dict:
    source_path = root / "Library/SourceMedia/retro/crossfire-apple-ii/program-01.bin"
    source = source_path.read_bytes()
    image = address_image(source)  # verifies exact selected revision before decoding
    bonus_usage = bonus_sprite_usage(image)
    media = json.loads(source_path.with_name("media.json").read_text())
    out = root / "Library/Imported/crossfire"
    out.mkdir(parents=True, exist_ok=True)
    from PIL import Image
    artifacts = []
    for name, address in SPRITES.items():
        rows = sprite_rows(image, address)
        png = Image.new("RGBA", (len(rows[0]), len(rows)))
        png.putdata([(255, 255, 255, 255) if p else (0, 0, 0, 0) for row in rows for p in row])
        path = out / (name + ".png")
        png.save(path)
        artifacts.append({"name": name, "address": address, "sourceFileOffset": address - 0x2000,
                          "path": path.name, "width": png.width, "height": png.height,
                          "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    groups = []
    for i in range(3):
        address = 0x5BB5 + i * 7
        values = image[address - 0x300:address - 0x300 + 7]
        signed = lambda v: v - 256 if v >= 128 else v
        groups.append({"address": address, "sourceFileOffset": address - 0x2000,
                       "x": values[0], "y": values[1], "spacingX": signed(values[2]),
                       "spacingY": signed(values[3]), "dx": signed(values[4]),
                       "dy": signed(values[5]), "count": values[6]})
    metadata = {"schemaVersion": 1, "sourceIdentity": SOURCE_SHA256,
                "mode": "Static native reconstruction; monochrome source sprite view",
                "sprites": artifacts, "enemyGroups": groups, "bonusSprites": bonus_usage,
                "limitations": ["HGR artifact colors are not reconstructed; phase-zero bits become white pixels.",
                                "No game, Apple II hardware, emulator or compatibility runtime is executed."]}
    (out / "crossfire.json").write_text(json.dumps(metadata, indent=2) + "\n")
    evidence = {"schemaVersion": 1, "sourceArchive": media["archive"],
                "archiveSHA256": media["archiveSHA256"], "selectedPayload": media["selectedPayload"],
                "program": {"sha256": SOURCE_SHA256, "bytes": len(source), "loadAddress": 0x2000},
                "method": "Direct Ghidra and first-party static decoding, not REA Evidence",
                "targetExecution": False, "enemyGroups": groups, "bonusSprites": bonus_usage,
                "spriteLocations": [{k: v for k, v in a.items() if k != "path"} for a in artifacts],
                "claims": [
                    {"addresses": ["$5000-$509F", "$0400-$042A (copied from $2400)"],
                     "finding": "I/J/K/L move up/left/down/right; Space stops; E/S/D/F shoot up/left/down/right."},
                    {"addresses": ["$4447-$44BD", "$45CC-$45DA"],
                     "finding": "Player step is 2; coordinates X32..192,Y32..160; axis changes only on 32-unit intersections."},
                    {"addresses": ["$4054-$40A5", "$4200-$438F"],
                     "finding": "Round-robin projectile update each loop, actor update every8 loops, player every32, resupply blink128."},
                    {"addresses": ["$4399-$439C", "$5255-$526B", "$4900-$49C3"],
                     "finding": "Enemy kill stages award 10/20/40/80; respawn until fourth kill. Middle-byte BCD carry plus a 4-to-5 thousands transition award an extra life every 5000 points."},
                    {"addresses": ["$5999-$59EC", "$5BB5-$5BC9", "$5AC9", "$5D5F-$5D6C"],
                     "finding": "Seven-by-six 16x16 obstacle blocks; eleven source enemy spawns; 35 initial ammo decreasing by 5 per wave to 15."},
                    {"addresses": ["$5780-$57D4", "$57D5-$57E0", "$6300"],
                     "finding": "Bonus kind0 is the collectible 21x9 sprite at$6300, anchored x+4/y+3. Kinds1..4 display score art at$8100/$8200/$8300/$8400, anchored x+1/y+4; expired kind5 has a zero sprite pointer."}],
                "unresolved": ["Loader's final $0800 transfer appears to reach graphics data; the observed $4000 game startup is statically valid, but loader completion is not established.",
                               "Original CPU-loop-to-wall-clock timing, HGR artifact colors, sound waveform and original runtime comparison are unresolved.",
                               "M1 Air acceptance and physical Fusion Pro controls have not been tested."]}
    if evidence_path:
        evidence_path.parent.mkdir(parents=True, exist_ok=True)
        evidence_path.write_text(json.dumps(evidence, indent=2) + "\n")
    return metadata


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    p.add_argument("--evidence", type=Path)
    args = p.parse_args()
    result = decode(args.root.resolve(), args.evidence)
    print(f"Crossfire: {len(result['sprites'])} sprites, {sum(g['count'] for g in result['enemyGroups'])} enemy spawns")


if __name__ == "__main__":
    main()
