#!/usr/bin/env python3
"""Prepare selected Atari 8-bit Asteroids tables, without executing original code.

All copied tables and masks stay in ignored Library/Prepared. The committed
receipt contains locations, sizes and hashes, never their contents.
"""
import argparse
import hashlib
import json
from pathlib import Path

from prepare_asteroids import REFERENCES, parse_xex, read_reference

SOURCE_SHA256 = REFERENCES[2].payload_sha256
CODE_SHA256 = "e24b9792d19d4a8fdeb443bb7201b64b27ab283ec308dc067affea86e12dbf5f"
TABLE_SHA256 = "de5c7d6d9e0933f2f6b06a9d8854de47e4e57fbb5ccdaea46d712edab9c41c7a"
WINDOWS = {
    "waveCounts": (0x668D, 7), "initialX": (0x656C, 4), "initialY": (0x6570, 4),
    "projectileOffsetX": (0x69CE, 18), "projectileOffsetY": (0x69E0, 18),
    "extents": (0x709B, 4), "explosionOffsets": (0x709E, 4),
    "sine": (0x719A, 65), "colors": (0x64BB, 11),
    "shipRows": (0x70C5, 95), "smallRows": (0x70A2, 4),
    "mediumRows": (0x70A6, 7), "largeRows": (0x70AD, 24),
    "explosionRows": (0x7124, 42), "explosionBits": (0x714E, 42),
    "soundRequests": (0x7208, 27), "soundSequences": (0x7223, 137),
}


def decode(payload: bytes) -> tuple[dict, dict]:
    if hashlib.sha256(payload).hexdigest() != SOURCE_SHA256:
        raise ValueError("Selected Atari 8-bit XEX SHA-256 mismatch")
    records = parse_xex(payload)
    if [(x["start"], x["end"]) for x in records] != [(0x5500, 0x7700), (0x02E0, 0x02E1)]:
        raise ValueError("Unexpected selected XEX layout")
    record = records[0]
    code = payload[record["file_offset"]:record["file_offset"] + record["bytes"]]
    if hashlib.sha256(code).hexdigest() != CODE_SHA256:
        raise ValueError("Selected code identity mismatch")
    resources = {"schema": 1, "sourceSHA256": SOURCE_SHA256, "codeSHA256": CODE_SHA256}
    windows = []
    for name, (address, count) in WINDOWS.items():
        offset = address - record["start"]
        data = code[offset:offset + count]
        if len(data) != count:
            raise ValueError("Source table outside load record")
        resources[name] = list(data)
        windows.append({"name": name, "address": f"${address:04X}",
                        "payload_file_offset": record["file_offset"] + offset,
                        "bytes": count, "sha256": hashlib.sha256(data).hexdigest()})
    table_digest = hashlib.sha256(bytes(v for name in WINDOWS for v in resources[name])).hexdigest()
    if table_digest != TABLE_SHA256:
        raise ValueError("Decoded table identity mismatch")
    resources["tableSHA256"] = table_digest
    routines = [("scheduler", 0x62BF, 0xB5), ("wave", 0x664C, 0x40),
                ("ships", 0x6713, 0x300), ("collisions", 0x6A71, 0x225),
                ("ufo", 0x6D05, 0x113), ("vbi", 0x6F2F, 0x2D),
                ("foreground-vbi-service", 0x6F5C, 0x4D), ("sound-callback", 0x72D7, 0x63),
                ("mode-selection", 0x740B, 0x10F)]
    for name, address, count in routines:
        data = code[address - 0x5500:address - 0x5500 + count]
        windows.append({"name": name, "address": f"${address:04X}",
                        "payload_file_offset": 6 + address - 0x5500, "bytes": count,
                        "sha256": hashlib.sha256(data).hexdigest()})
    return resources, {"schema": 1, "source_sha256": SOURCE_SHA256,
                       "code_sha256": CODE_SHA256, "table_sha256": TABLE_SHA256,
                       "method": "direct static byte/table reconstruction; no target execution",
                       "windows": windows,
                       "limits": ["POKEY RANDOM samples and startup fractional coordinates remain external inputs.",
                                  "Source OS callbacks, ROM font and GTIA/ANTIC color conversion are not reconstructed.",
                                  "No original-game or M1 acceptance is asserted."]}


def prepare(root: Path) -> dict:
    resources, receipt = decode(read_reference(root, REFERENCES[2]))
    output = root / "Library/Prepared/asteroids8bit"
    output.mkdir(parents=True, exist_ok=True)
    (output / "asteroids8bit.json").write_text(json.dumps(resources, separators=(",", ":")) + "\n")
    return receipt


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    receipt = prepare(args.root.resolve())
    if args.receipt:
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Prepared Atari 8-bit tables and masks: {len(receipt['windows'])} fenced windows")


if __name__ == "__main__":
    main()
