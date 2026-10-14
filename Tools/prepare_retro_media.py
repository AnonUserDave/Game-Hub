#!/usr/bin/env python3
"""Recover selected retro reference files without executing their programs.

Only the exact revisions selected below are accepted. Outputs (including BASIC
listings) are proprietary reference material and belong in ignored Library/.
This is an offline container decoder, not a CPU or operating-system emulator.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
from pathlib import Path
import struct
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
LIMIT = 1024 * 1024
SELECTIONS = {
    "apple-panic-apple-ii": "Apple Panic (1981)(Broderbund)[cr Sledge Hammer].do",
    "conflict-2500-apple-ii": "Conflict 2500 (1981)(Avalon Hill).do",
    "crossfire-apple-ii": "Crossfire (1981)(On-Line Systems).do",
    "dig-dug-c64": "DIGDUG.T64",
    "night-driver-c64": "NIGHTDRI.T64",
    "nfl-football-intellivision": "NFL Football (1978)(Mattel).bin",
    "preppie-atari-8-bit": "Preppie! (1982)(Adventure International)(US).xex",
}

# Applesoft II token names, $80..$EA. Format reference: Apple II ROM
# token table $D0D0, https://6502disassembly.com/a2-rom/Applesoft.html .
TOKENS = (
    "END FOR NEXT DATA INPUT DEL DIM READ GR TEXT PR# IN# CALL PLOT HLIN "
    "VLIN HGR2 HGR HCOLOR= HPLOT DRAW XDRAW HTAB HOME ROT= SCALE= SHLOAD "
    "TRACE NOTRACE NORMAL INVERSE FLASH COLOR= POP VTAB HIMEM: LOMEM: "
    "ONERR RESUME RECALL STORE SPEED= LET GOTO RUN IF RESTORE & GOSUB "
    "RETURN REM STOP ON WAIT LOAD SAVE DEF POKE PRINT CONT LIST CLEAR GET "
    "NEW TAB( TO FN SPC( THEN AT NOT STEP + - * / ^ AND OR > = < SGN INT "
    "ABS USR FRE SCRN( PDL POS SQR RND LOG EXP COS SIN TAN ATN PEEK LEN "
    "STR$ VAL ASC CHR$ LEFT$ RIGHT$ MID$"
).split()


class MediaError(ValueError):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def selected_payload(archive: Path, record: dict, filename: str) -> tuple[bytes, dict]:
    """Follow only the indexed member chain, checking identity at every level."""
    if archive.stat().st_size != record["archiveBytes"]:
        raise MediaError("Archive size differs from the selected reference")
    archive_data = archive.read_bytes()
    if sha256(archive_data) != record["archiveSHA256"]:
        raise MediaError("Archive SHA-256 differs from the selected reference")

    def find(entries, chain=()):
        for entry in entries:
            path = entry["path"]
            if Path(path).name == filename:
                yield chain + (entry,)
            yield from find(entry.get("entries", []), chain + (entry,))

    chains = list(find(record["entries"]))
    if len(chains) != 1:
        raise MediaError("Selected member is missing or ambiguous in the reference index")
    data = archive_data
    for entry in chains[0]:
        if entry["size"] > LIMIT:
            raise MediaError("Selected member exceeds the retro media bound")
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            matches = [i for i in z.infolist() if i.filename == entry["path"]]
            if len(matches) != 1 or matches[0].file_size != entry["size"]:
                raise MediaError("Member identity or size is ambiguous")
            data = z.read(matches[0])
        if len(data) != entry["size"] or sha256(data) != entry["sha256"]:
            raise MediaError("Member SHA-256 differs from the selected reference")
    return data, {"memberChain": [e["path"] for e in chains[0]],
                  "sha256": sha256(data), "bytes": len(data)}


def dos33_files(disk: bytes) -> list[dict]:
    """Decode a DOS-order 35-track, 16-sector Apple II DOS 3.3 filesystem."""
    if len(disk) != 35 * 16 * 256:
        raise MediaError("Expected a 143360-byte DOS-order disk")

    def sector(track, number):
        if not 0 <= track < 35 or not 0 <= number < 16:
            raise MediaError("Track/sector outside the disk")
        offset = (track * 16 + number) * 256
        return disk[offset:offset + 256]

    vtoc = sector(17, 0)
    if vtoc[0x34:0x38] != bytes([35, 16, 0, 1]) or vtoc[3] != 3:
        raise MediaError("Unsupported DOS disk geometry/version")
    track, number = vtoc[1:3]
    seen = set()
    files = []
    while track:
        if (track, number) in seen:
            raise MediaError("Cyclic catalog chain")
        seen.add((track, number))
        catalog = sector(track, number)
        for index in range(7):
            entry = catalog[0x0B + 35 * index:0x0B + 35 * (index + 1)]
            if entry[0] in (0, 255):
                continue
            name = "".join(chr(c & 127) for c in entry[3:33]).rstrip()
            list_track, list_sector = entry[:2]
            lists = set()
            blocks = {}
            while list_track:
                if (list_track, list_sector) in lists:
                    raise MediaError("Cyclic track/sector list")
                lists.add((list_track, list_sector))
                ts = sector(list_track, list_sector)
                base = u16(ts, 5)
                if base + 122 > 35 * 16:
                    raise MediaError("File sector offset exceeds the disk bound")
                for i in range(122):
                    t, s = ts[12 + i * 2:14 + i * 2]
                    if t == s == 0:
                        continue
                    offset = base + i
                    if offset in blocks:
                        raise MediaError("Overlapping track/sector lists")
                    blocks[offset] = sector(t, s)
                list_track, list_sector = ts[1:3]
            raw = b"".join(blocks.get(i, bytes(256)) for i in range(max(blocks, default=-1) + 1))
            kind = entry[2] & 127
            info = {"name": name, "type": kind, "locked": bool(entry[2] & 128),
                    "catalogSectors": u16(entry, 33), "trackSectorLists": len(lists)}
            if kind in (1, 2, 4):
                header = 4 if kind == 4 else 2
                if len(raw) < header:
                    raise MediaError("Truncated DOS file header")
                length = u16(raw, header - 2)
                if header + length > len(raw):
                    raise MediaError("DOS file length exceeds its sectors")
                if kind == 4:
                    info["loadAddress"] = u16(raw, 0)
                info["data"] = raw[header:header + length]
            else:
                info["data"] = raw
            files.append(info)
        track, number = catalog[1:3]
    return files


def applesoft_listing(data: bytes) -> str:
    """Detokenize program bytes. Never interpret or execute BASIC statements."""
    offset = 0
    previous = -1
    lines = []
    base_address = None
    while True:
        if offset + 2 > len(data):
            raise MediaError("Missing BASIC end marker")
        link = u16(data, offset)
        if link == 0:
            return "\n".join(lines) + "\n"
        if offset + 4 > len(data):
            raise MediaError("Truncated BASIC line")
        number = u16(data, offset + 2)
        if number <= previous:
            raise MediaError("Non-increasing BASIC line numbers")
        previous = number
        end = data.find(b"\x00", offset + 4)
        if end < 0:
            raise MediaError("Unterminated BASIC line")
        inferred_base = link - end - 1
        if base_address is None:
            base_address = inferred_base
        if base_address != inferred_base:
            raise MediaError("Inconsistent BASIC next-line pointers")
        text, quoted, remark, literal_data = [], False, False, False
        for b in data[offset + 4:end]:
            if b == 34 and not remark:
                quoted = not quoted
            if b == 58 and not quoted and not remark:
                literal_data = False
            if b >= 128 and not quoted and not remark and not literal_data:
                if b - 128 >= len(TOKENS):
                    raise MediaError("Unknown Applesoft token")
                text.append(" " + TOKENS[b - 128] + " ")
                remark = b == 0xB2
                literal_data = b == 0x83
            else:
                text.append(chr(b) if b >= 32 else f"\\x{b:02x}")
        lines.append(str(number) + " " + "".join(text).strip())
        offset = end + 1


def t64_files(data: bytes) -> list[dict]:
    if len(data) < 64 or not data[:32].startswith((b"C64 tape image file", b"C64S tape image file", b"C64 tape file")):
        raise MediaError("Invalid T64 header")
    capacity, used = u16(data, 34), u16(data, 36)
    if used > capacity or capacity > 1024 or 64 + capacity * 32 > len(data):
        raise MediaError("Invalid T64 entry table")
    files = []
    ranges = []
    for i in range(capacity):
        entry = data[64 + i * 32:96 + i * 32]
        if entry[0] == 0:
            continue
        if entry[0] != 1:
            raise MediaError("Unsupported T64 entry type")
        start, end = u16(entry, 2), u16(entry, 4)
        offset = struct.unpack_from("<I", entry, 8)[0]
        length = end - start
        if length <= 0 or offset < 64 + capacity * 32 or offset + length > len(data):
            raise MediaError("T64 program range exceeds container")
        if any(offset < other_end and other_start < offset + length for other_start, other_end in ranges):
            raise MediaError("Overlapping T64 program ranges")
        ranges.append((offset, offset + length))
        files.append({"name": entry[16:32].decode("ascii", errors="replace").rstrip(),
                      "loadAddress": start, "endAddressExclusive": end,
                      "data": data[offset:offset + length]})
    # Several historical T64 writers leave the used-count at zero. Record it;
    # the populated entries are authoritative, but a nonzero mismatch is bad.
    if used not in (0, len(files)):
        raise MediaError("T64 used entry count disagrees with populated entries")
    return files


def xex_segments(data: bytes) -> list[dict]:
    if not data.startswith(b"\xff\xff"):
        raise MediaError("Missing Atari XEX marker")
    offset = 2
    segments = []
    while offset < len(data):
        if offset + 2 <= len(data) and data[offset:offset + 2] == b"\xff\xff":
            offset += 2
            if offset == len(data):
                raise MediaError("Trailing XEX marker without a segment")
            continue
        if offset + 4 > len(data):
            raise MediaError("Truncated XEX segment header")
        start, end = struct.unpack_from("<HH", data, offset)
        length = end - start + 1
        offset += 4
        if length <= 0 or offset + length > len(data):
            raise MediaError("Truncated or reversed XEX segment")
        # Ordered overlap is legal: loaders and initialization vectors can be
        # replaced. Preserve segment order; do not flatten away that evidence.
        segments.append({"loadAddress": start, "endAddressInclusive": end,
                         "data": data[offset:offset + length]})
        offset += length
    return segments


def prepare(game_id: str, root: Path) -> dict:
    index = json.loads((ROOT / "docs/research/evidence/retro-inventory.json").read_text())
    record = next(r for r in index["archives"] if r["id"] == game_id)
    filename = SELECTIONS[game_id]
    payload, identity = selected_payload(root / record["archive"], record, filename)
    output = root / "Library/SourceMedia/retro" / game_id
    # Only our own numeric output names are used; never use archive/catalog names
    # as filesystem paths. Resolve the destination to reject a redirected cache.
    if not output.resolve().is_relative_to(root.resolve()):
        raise MediaError("Output symlink leaves the library root")
    output.mkdir(parents=True, exist_ok=True)
    report = {"schemaVersion": 1, "id": game_id, "archive": record["archive"],
              "archiveSHA256": record["archiveSHA256"], "selectedPayload": identity,
              "execution": "none; static container decoding only", "files": []}

    def write(name, data):
        destination = output / name
        if destination.is_symlink():
            raise MediaError("Output file is a symlink")
        with tempfile.NamedTemporaryFile(dir=output, delete=False) as stream:
            stream.write(data)
            temporary = Path(stream.name)
        temporary.replace(destination)
        return {"path": name, "bytes": len(data), "sha256": sha256(data)}

    write("reference-media.bin", payload)
    if filename.lower().endswith(".do"):
        files = dos33_files(payload)
    elif filename.lower().endswith(".t64"):
        files = t64_files(payload)
    elif filename.lower().endswith(".xex"):
        files = xex_segments(payload)
    else:
        files = [{"name": filename, "data": payload,
                  "limitation": "Intellivision word mapping and EXEC/GROM dependencies are not decoded"}]
    for i, file in enumerate(files):
        data = file.pop("data")
        metadata = {**file, **write(f"program-{i:02}.bin", data)}
        if file.get("type") == 2:
            listing = applesoft_listing(data).encode()
            metadata["basicListing"] = write(f"program-{i:02}.bas.txt", listing)
            if game_id == "conflict-2500-apple-ii" and file["name"] == "CONFLICT":
                shapes = []
                for number in (950, 960, 970, 980, 990):
                    match = re.search(rf"^{number} DATA\s+([^\n]+)$", listing.decode(), re.M)
                    if match is None:
                        raise MediaError("Conflict tactical shape DATA line missing")
                    coordinates = [int(v.strip()) for v in match[1].split(",")]
                    if len(coordinates) != 20:
                        raise MediaError("Unexpected Conflict tactical shape size")
                    shapes.append([coordinates[j:j + 2] for j in range(0, 20, 2)])
                metadata["nativeContent"] = write("conflict-content.json", (json.dumps({
                    "schemaVersion": 1, "sourceSHA256": sha256(data), "shapes": shapes,
                    "sourceLines": [950, 960, 970, 980, 990],
                }, indent=2) + "\n").encode())
        report["files"].append(metadata)
    write("media.json", (json.dumps(report, indent=2) + "\n").encode())
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--games", nargs="+", choices=sorted(SELECTIONS), default=sorted(SELECTIONS))
    args = parser.parse_args()
    for game_id in args.games:
        report = prepare(game_id, args.root)
        print(f"{game_id}: decoded {len(report['files'])} reference file(s); no execution")


if __name__ == "__main__":
    main()
