#!/usr/bin/env python3
"""Verify and extract the three owner-supplied Asteroids references for static research.

This prepares offline analysis inputs. It neither executes nor emulates a game.
Original bytes are written only to the ignored Library/SourceMedia directory.
"""
import argparse
from dataclasses import dataclass
import hashlib
import io
import json
from pathlib import Path
import struct
import zipfile


@dataclass(frozen=True)
class Reference:
    edition: str
    archive: str
    archive_sha256: str
    member: str
    payload_sha256: str
    output: str
    nested_member: str | None = None


REFERENCES = (
    Reference("Atari 2600", "Asteroids_Atari-2600_ROM_EN.zip",
              "abe1676c4ae35515d8a48335535d311ea71ae7b6002507d9e493fbdb5656bbe9",
              "Asteroids_Atari-2600_ROM_EN/Game Files/Asteroids.A26",
              "d1a6e808412b4535c7e54fc25414943a9418b1095b4d4969dc33290f7eaa72a4", "atari2600.a26"),
    Reference("Atari 7800", "Asteroids_Atari-7800_ROM_EN.zip",
              "a16d828e56aad75fc099aaa1523a2e6fff3cf1335fca2bda6a9f24543a9883e6",
              "Asteroids_Atari-7800_ROM_EN/Game Files/Asteroids.A78",
              "ec6ef6179644041a9fb77fc6b7c917387219fc388dd5a0fbf8236677f279402e", "atari7800.a78"),
    Reference("Atari 8-bit", "Asteroids_Atari-8-bit_ROM_EN.zip",
              "d60e45e03deb6764f00fdaa99846be8c5b15ac7f6b73f25ad5b040a63b2defcd",
              "Asteroids_Atari-8-bit_ROM_EN/Game Files/Asteroids (1981)(Atari)(US).zip",
              "1cf45090b216c2363131bac2e4db9101a3c162e31686d7fe30474eaba5b7f97f", "atari8bit.xex",
              "Asteroids (1981)(Atari)(US).xex"),
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def parse_a78(data: bytes) -> dict:
    """Decode the selected revision's fixed 128-byte carrier header, without guessing a mapper."""
    if len(data) < 128 or data[1:17] != b"ATARI7800       ":
        raise ValueError("Invalid A78 identifier or truncated header")
    size = int.from_bytes(data[49:53], "big")
    if size != len(data) - 128:
        raise ValueError("A78 declared ROM length does not match carrier length")
    if data[100:128] != b"ACTUAL CART DATA STARTS HERE":
        raise ValueError("Missing A78 terminal header marker")
    return {"header_version": data[0], "title": data[17:49].decode("ascii").rstrip(),
            "header_bytes": 128, "rom_bytes": size, "rom_sha256": sha256(data[128:]),
            "cartridge_flags": int.from_bytes(data[53:55], "big"),
            "controller_1": data[55], "controller_2": data[56], "region": data[57]}


def parse_xex(data: bytes) -> list[dict]:
    """Return ordered XEX load records; no machine or OS behavior is inferred."""
    if not data.startswith(b"\xff\xff"):
        raise ValueError("Missing XEX marker")
    offset, records = 2, []
    while offset < len(data):
        if offset + 2 > len(data):
            raise ValueError("Truncated XEX segment header")
        if data[offset:offset + 2] == b"\xff\xff":
            offset += 2
            if offset == len(data):
                raise ValueError("Trailing XEX marker without segment")
            continue
        if offset + 4 > len(data):
            raise ValueError("Truncated XEX segment header")
        start, end = struct.unpack_from("<HH", data, offset)
        offset += 4
        if end < start:
            raise ValueError("Reversed XEX load range")
        count = end - start + 1
        if offset + count > len(data):
            raise ValueError("Truncated XEX segment payload")
        records.append({"start": start, "end": end, "file_offset": offset, "bytes": count,
                        "sha256": sha256(data[offset:offset + count])})
        offset += count
    if not records:
        raise ValueError("Empty XEX")
    return records


def read_reference(root: Path, ref: Reference) -> bytes:
    archive_bytes = (root / ref.archive).read_bytes()
    if sha256(archive_bytes) != ref.archive_sha256:
        raise ValueError(f"Source archive hash mismatch: {ref.archive}")
    with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
        if archive.namelist().count(ref.member) != 1:
            raise ValueError("Missing or duplicate selected archive member")
        payload = archive.read(ref.member)
    if ref.nested_member:
        with zipfile.ZipFile(io.BytesIO(payload)) as nested:
            if nested.namelist().count(ref.nested_member) != 1:
                raise ValueError("Missing or duplicate selected nested member")
            payload = nested.read(ref.nested_member)
    if sha256(payload) != ref.payload_sha256:
        raise ValueError(f"Selected payload hash mismatch: {ref.edition}")
    return payload


def prepare(root: Path) -> dict:
    # Validate every input before producing any output. Never extract arbitrary archive paths.
    payloads = [read_reference(root, ref) for ref in REFERENCES]
    if len(payloads[0]) != 8192:
        raise ValueError("Selected 2600 cartridge must have two 4096-byte banks")
    a78 = parse_a78(payloads[1])
    xex = parse_xex(payloads[2])
    if [(x["start"], x["end"]) for x in xex] != [(0x5500, 0x7700), (0x02E0, 0x02E1)]:
        raise ValueError("Selected XEX load layout changed")
    out = root / "Library/SourceMedia/asteroids"
    out.mkdir(parents=True, exist_ok=True)
    for ref, payload in zip(REFERENCES, payloads):
        (out / ref.output).write_bytes(payload)
    for bank in range(2):
        (out / f"2600-bank{bank}.bin").write_bytes(payloads[0][bank * 4096:(bank + 1) * 4096])
    (out / "7800-code.bin").write_bytes(payloads[1][128:])
    code = xex[0]
    (out / "8bit-code.bin").write_bytes(payloads[2][code["file_offset"]:code["file_offset"] + code["bytes"]])
    metadata = {"method": "offline byte verification and container parsing; no execution or emulation",
                "references": [{"edition": ref.edition, "archive": ref.archive,
                                "archive_sha256": ref.archive_sha256, "member": ref.member,
                                "nested_member": ref.nested_member,
                                "payload_sha256": ref.payload_sha256, "payload_bytes": len(data)}
                               for ref, data in zip(REFERENCES, payloads)],
                "atari7800": a78, "atari8bit_load_records": xex,
                "atari8bit_run_address": int.from_bytes(payloads[2][-2:], "little")}
    (out / "provenance.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    result = prepare(args.root.resolve())
    for ref in result["references"]:
        print(f'{ref["edition"]}: verified {ref["payload_bytes"]} bytes, SHA-256 {ref["payload_sha256"]}')


if __name__ == "__main__":
    main()
