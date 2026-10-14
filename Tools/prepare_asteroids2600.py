#!/usr/bin/env python3
"""Decode the selected Asteroids A26 into bounded native tables and original masks.

Offline data preparation only. No CPU, TIA, game execution or emulation is present.
The original arrays are emitted beneath ignored Library/Prepared, never in source.
"""
import argparse
import hashlib
import json
from pathlib import Path

from prepare_asteroids import REFERENCES, read_reference, sha256

SOURCE_SHA256 = REFERENCES[0].payload_sha256
TABLES = {
    "horizontalIncreasing": (0, 0xD700, 256),
    "horizontalDecreasing": (0, 0xD800, 256),
    "projectileLifetime": (1, 0xFEDE, 16),
    "speedMasks": (1, 0xFEE6, 16),
    "horizontalSubtract": (1, 0xFEF4, 16),
    "horizontalAdd": (1, 0xFEFF, 16),
    "randomHorizontalLow": (1, 0xFF0D, 8),
    "horizontalHigh": (1, 0xFF15, 16),
    "horizontalLow": (1, 0xFF25, 16),
    "verticalExtent": (1, 0xFF33, 11),
    "horizontalExtent": (1, 0xFF3E, 11),
    "scoreLowBCD": (1, 0xFF49, 7),
    "scoreHighBCD": (1, 0xFF50, 7),
    "topRemoval": (1, 0xFF57, 4),
    "bottomDuplicate": (1, 0xFF5B, 4),
    "selectionEnd": (1, 0xFF5F, 4),
    "selectionStart": (1, 0xFF63, 4),
    "thrust": (1, 0xFF67, 16),
    "projectileVertical": (1, 0xFF77, 16),
    "projectileHorizontal": (1, 0xFF87, 16),
    "asteroidColor": (0, 0xDE75, 8),
}


def content_digest(data: dict) -> str:
    """Canonical decoded content, shared with the bounded Swift loader."""
    canonical = bytearray(b"GameHub.Asteroids2600.resources.v1\0")
    for name, values in sorted(data["tables"].items()):
        canonical += name.encode("ascii") + b"\0"
        canonical += len(values).to_bytes(4, "little") + bytes(values)
    for mask in sorted(data["masks"], key=lambda mask: mask["name"]):
        canonical += mask["name"].encode("ascii") + b"\0"
        canonical += bytes((mask["width"], len(mask["rows"]))) + bytes(mask["rows"])
        canonical += mask["sourceAddress"].encode("ascii") + b"\0"
    return hashlib.sha256(canonical).hexdigest()


def window(rom: bytes, bank: int, address: int, count: int) -> bytes:
    base = 0xD000 if bank == 0 else 0xF000
    start = address - base
    if len(rom) != 8192 or bank not in (0, 1) or start < 0 or count < 1 or start + count > 4096:
        raise ValueError("Invalid selected-cartridge source window")
    return rom[bank * 4096 + start:bank * 4096 + start + count]


def decode(rom: bytes) -> tuple[dict, dict]:
    if len(rom) != 8192 or sha256(rom) != SOURCE_SHA256:
        raise ValueError("Selected Atari 2600 Asteroids ROM identity mismatch")
    tables, windows = {}, []
    for name, (bank, address, count) in TABLES.items():
        data = window(rom, bank, address, count)
        tables[name] = list(data)
        windows.append({"name": name, "bank": bank, "address": f"${address:04X}",
                        "rom_offset": bank * 4096 + (address & 0xFFF), "bytes": count,
                        "sha256": sha256(data)})
    masks = []
    def mask(name: str, address: int, count: int, width: int = 8, reverse: bool = False):
        data = window(rom, 0, address, count)
        rows = [value >> 5 for value in data] if width == 3 else list(data)
        if reverse:
            rows.reverse()
        masks.append({"name": name, "width": width, "rows": rows,
                      "sourceAddress": f"${address:04X}"})
        windows.append({"name": name, "bank": 0, "address": f"${address:04X}",
                        "rom_offset": address & 0xFFF, "bytes": count, "sha256": sha256(data)})
    for heading in range(9):
        address = 0xDF74 + heading * 6
        if window(rom, 0, address + 5, 1) != b"\xff":
            raise ValueError("Ship graphic stream terminator changed")
        mask(f"ship-{heading}", address, 5)
    for frame in range(3):
        mask(f"explosion-{frame}", 0xDFAA + frame * 6, 5)
    mask("shield", 0xDFBC, 5)
    mask("saucer-small", 0xDFC2, 3)
    mask("saucer-large", 0xDFC6, 5)
    for kind, count in enumerate((15, 15, 7, 4)):
        mask(f"asteroid-{kind}", 0xDF00 + kind * 16, count)
    for digit in range(10):
        mask(f"digit-{digit}", 0xDD00 + digit * 5, 5, 3, True)
    result = {"schema": 1, "sourceSHA256": SOURCE_SHA256, "tables": tables, "masks": masks}
    result["contentSHA256"] = content_digest(result)
    evidence = {"method": "Selected bytes decoded as data; no original execution or emulation",
                "source_sha256": SOURCE_SHA256, "content_sha256": result["contentSHA256"], "windows": windows,
                "limitations": ["Original masks are recovered; TIA intraline positioning, repeated pixels and RGB remain unqualified.",
                                "Source audio registers and cadence require original comparison."]}
    return result, evidence


def prepare(root: Path) -> dict:
    # Archive and ROM validation precede all output mutations.
    rom = read_reference(root, REFERENCES[0])
    result, evidence = decode(rom)
    output = root / "Library/Prepared/asteroids2600"
    output.mkdir(parents=True, exist_ok=True)
    (output / "asteroids2600.json").write_text(json.dumps(result, separators=(",", ":")) + "\n")
    (output / "provenance.json").write_text(json.dumps(evidence, indent=2) + "\n")
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    result = prepare(args.root.resolve())
    print(f"Prepared Asteroids 2600 original tables/masks; {len(result['windows'])} hash-fenced windows")


if __name__ == "__main__":
    main()
