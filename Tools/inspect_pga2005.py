#!/usr/bin/env python3
"""Inspect owned PGA Tour 2005 media without mounting discs or running installers.

Standard-library only. Extracts selected disc images from the supplied ZIP,
reads ISO9660 (including raw MODE1 B6I sectors), hashes files, and can copy
selected disc files. It does not execute, patch, or emulate game code.
"""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
from fnmatch import fnmatch
import hashlib
import json
from pathlib import Path, PurePosixPath
import stat
import struct
import sys
import zipfile


BLOCK = 2048
CHUNK = 4 * 1024 * 1024
MAX_MEDIA_BYTES = 8 * 1024**3


def digest_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(CHUNK):
            h.update(chunk)
    return h.hexdigest()


def safe_name(value: str) -> PurePosixPath:
    name = PurePosixPath(value.replace("\\", "/"))
    if name.is_absolute() or any(p in ("..", "") for p in name.parts):
        raise ValueError(f"Unsafe relative path: {value!r}")
    if any(":" in p or "\x00" in p for p in name.parts):
        raise ValueError(f"Unsafe relative path: {value!r}")
    return name


def safe_target(root: Path, name: str) -> Path:
    relative = safe_name(name)
    target = root.joinpath(*relative.parts)
    if not target.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"Path escapes destination: {name!r}")
    return target


def extract_media(archive: Path, destination: Path) -> list[dict]:
    destination.mkdir(parents=True, exist_ok=True)
    members = []
    with zipfile.ZipFile(archive) as zipped:
        selected = [i for i in zipped.infolist()
                    if not i.is_dir() and Path(i.filename).suffix.lower()
                    in (".iso", ".b6i", ".b6t")]
        if sum(i.file_size for i in selected) > MAX_MEDIA_BYTES:
            raise ValueError("Unexpected media expansion exceeds 8 GiB")
        basenames = set()
        for entry in selected:
            name = safe_name(entry.filename).name
            if name.casefold() in basenames:
                raise ValueError(f"Duplicate media basename: {name}")
            basenames.add(name.casefold())
            if stat.S_ISLNK(entry.external_attr >> 16):
                raise ValueError("Symlinks are not accepted in source media")
            target = safe_target(destination, name)
            if target.exists():
                if not target.is_file() or target.stat().st_size != entry.file_size:
                    raise ValueError(f"Existing media has wrong size: {target}")
                # Read to EOF to validate ZIP CRC and compare existing bytes.
                existing_hash = digest_file(target)
                h = hashlib.sha256()
                with zipped.open(entry) as stream:
                    while chunk := stream.read(CHUNK):
                        h.update(chunk)
                if h.hexdigest() != existing_hash:
                    raise ValueError(f"Existing media hash mismatch: {target}")
            else:
                partial = target.with_name(target.name + ".partial")
                try:
                    with zipped.open(entry) as source, partial.open("xb") as out:
                        while chunk := source.read(CHUNK):
                            out.write(chunk)
                    if partial.stat().st_size != entry.file_size:
                        raise ValueError(f"Incomplete extraction: {name}")
                    partial.replace(target)
                finally:
                    if partial.exists():
                        partial.unlink()
            members.append({"zip_path": entry.filename, "file": name,
                            "bytes": entry.file_size, "zip_crc32": f"{entry.CRC:08x}",
                            "sha256": digest_file(target)})
            print(f"Verified media: {name}", file=sys.stderr, flush=True)
    return members


@dataclass(frozen=True)
class Layout:
    physical_sector_bytes: int
    payload_offset: int
    image_data_offset: int


class ISO9660:
    def __init__(self, path: Path):
        self.path = path
        self.stream = path.open("rb")
        self.size = path.stat().st_size
        self.layout, self.pvd = self._detect()
        self.volume_id = self.pvd[40:72].decode("ascii", errors="replace").strip()
        self.volume_blocks = struct.unpack_from("<I", self.pvd, 80)[0]
        self.root_lba, self.root_bytes = self._record(self.pvd[156:190])[1:3]

    def close(self):
        self.stream.close()

    def _detect(self) -> tuple[Layout, bytes]:
        self.stream.seek(0)
        sample = self.stream.read(min(self.size, CHUNK))
        position = 0
        while (position := sample.find(b"CD001", position)) >= 0:
            pvd_start = position - 1
            position += 5
            if pvd_start < 0 or sample[pvd_start] != 1:
                continue
            pvd = sample[pvd_start:pvd_start + BLOCK]
            if len(pvd) != BLOCK or pvd[6] != 1:
                continue
            if struct.unpack_from("<H", pvd, 128)[0] != BLOCK:
                continue
            root_lba = struct.unpack_from("<I", pvd, 158)[0]
            for physical, payload in ((2048, 0), (2352, 16), (2352, 24),
                                      (2448, 16), (2448, 24)):
                base = pvd_start - 16 * physical - payload
                if base < 0:
                    continue
                candidate = Layout(physical, payload, base)
                # ISO descriptors continue in the next sector; root begins
                # with a directory record whose identifier is the self dot.
                next_offset = base + 17 * physical + payload
                self.stream.seek(next_offset)
                next_descriptor = self.stream.read(7)
                self.stream.seek(base + root_lba * physical + payload)
                root = self.stream.read(34)
                if (next_descriptor[1:6] == b"CD001" and len(root) == 34
                        and root[0] >= 34 and root[25] & 2
                        and root[32:34] == b"\x01\x00"):
                    return candidate, pvd
        raise ValueError(f"No supported ISO9660 volume in {self.path.name}")

    @staticmethod
    def _record(record: bytes):
        if len(record) < 34 or record[0] > len(record):
            raise ValueError("Truncated ISO9660 directory record")
        name_bytes = record[33:33 + record[32]]
        name = name_bytes.decode("ascii", errors="replace").split(";", 1)[0]
        return (name, struct.unpack_from("<I", record, 2)[0],
                struct.unpack_from("<I", record, 10)[0], record[25], name_bytes)

    def read(self, logical_offset: int, size: int) -> bytes:
        if logical_offset < 0 or size < 0:
            raise ValueError("Negative ISO extent")
        logical_max = self.volume_blocks * BLOCK
        if logical_offset + size > logical_max:
            raise ValueError("ISO extent extends beyond its declared volume")
        l = self.layout
        if l.physical_sector_bytes == BLOCK:
            self.stream.seek(l.image_data_offset + logical_offset)
            result = self.stream.read(size)
        else:
            first, skip = divmod(logical_offset, BLOCK)
            sectors = (skip + size + BLOCK - 1) // BLOCK
            self.stream.seek(l.image_data_offset + first * l.physical_sector_bytes)
            raw = self.stream.read(sectors * l.physical_sector_bytes)
            result = b"".join(raw[i * l.physical_sector_bytes + l.payload_offset:
                                  i * l.physical_sector_bytes + l.payload_offset + BLOCK]
                              for i in range(sectors))[skip:skip + size]
        if len(result) != size:
            raise ValueError(f"Truncated ISO data in {self.path.name}")
        return result

    def files(self) -> list[dict]:
        found = []
        visited = set()

        def walk(lba: int, size: int, prefix: str, depth: int):
            if depth > 32 or len(found) > 100000:
                raise ValueError("ISO directory limits exceeded")
            if (lba, size) in visited:
                return
            visited.add((lba, size))
            if size > 32 * 1024**2:
                raise ValueError("Unreasonable ISO directory size")
            data = self.read(lba * BLOCK, size)
            offset = 0
            while offset < size:
                length = data[offset]
                if not length:
                    offset = ((offset // BLOCK) + 1) * BLOCK
                    continue
                if length < 34 or offset + length > size:
                    raise ValueError("Malformed ISO directory record")
                name, child_lba, child_size, flags, identifier = self._record(
                    data[offset:offset + length])
                offset += length
                if identifier in (b"\x00", b"\x01"):
                    continue
                safe_name(name)
                path = f"{prefix}/{name}" if prefix else name
                if flags & 0x80:
                    raise ValueError("Multi-extent ISO files are not supported")
                if flags & 2:
                    walk(child_lba, child_size, path, depth + 1)
                else:
                    found.append({"path": path, "bytes": child_size,
                                  "logical_sector": child_lba})

        walk(self.root_lba, self.root_bytes, "", 0)
        return sorted(found, key=lambda entry: entry["path"])

    def chunks(self, entry: dict):
        offset = entry["logical_sector"] * BLOCK
        remaining = entry["bytes"]
        while remaining:
            amount = min(CHUNK, remaining)
            yield self.read(offset, amount)
            offset += amount
            remaining -= amount

    def inspect_file(self, entry: dict, include_hash: bool):
        head = self.read(entry["logical_sector"] * BLOCK, min(entry["bytes"], 64))
        entry["header_hex"] = head[:32].hex()
        entry["header_ascii"] = "".join(chr(x) if 32 <= x <= 126 else "."
                                        for x in head[:32])
        if head.startswith(b"MSCF"):
            entry["detected_format"] = "Microsoft Cabinet"
        elif head.startswith(b"ISc("):
            entry["detected_format"] = "InstallShield Cabinet/header"
        elif head.startswith(b"MZ"):
            entry["detected_format"] = "DOS/Windows executable (not executed)"
        elif head[:4] in (b"BIGF", b"BIG4"):
            entry["detected_format"] = "EA BIG archive"
        elif head.startswith(b"PK\x03\x04"):
            entry["detected_format"] = "ZIP archive"
        if include_hash:
            h = hashlib.sha256()
            for chunk in self.chunks(entry):
                h.update(chunk)
            entry["sha256"] = h.hexdigest()

    def extract(self, entry: dict, destination: Path):
        target = safe_target(destination, entry["path"])
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            if not target.is_file() or target.stat().st_size != entry["bytes"]:
                raise ValueError(f"Existing disc file differs: {target}")
            if "sha256" not in entry or digest_file(target) != entry["sha256"]:
                raise ValueError(f"Existing disc file hash unverified: {target}")
            return
        partial = target.with_name(target.name + ".partial")
        try:
            with partial.open("xb") as out:
                for chunk in self.chunks(entry):
                    out.write(chunk)
            partial.replace(target)
        finally:
            if partial.exists():
                partial.unlink()


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path,
                        default=root / "Tiger_Woods_PGA_Tour_2005_Win_ISO_EN.zip")
    parser.add_argument("--media-dir", type=Path,
                        default=root / "Library/SourceMedia/pga2005")
    parser.add_argument("--report", type=Path,
                        default=root / "Library/Research/pga2005-assets.json")
    parser.add_argument("--skip-zip", action="store_true",
                        help="Inspect already extracted images only")
    parser.add_argument("--no-file-hashes", action="store_true")
    parser.add_argument("--extract", action="append", default=[], metavar="GLOB",
                        help="Copy matching disc files under media-dir/discN")
    args = parser.parse_args()
    archive_members = [] if args.skip_zip else extract_media(args.archive, args.media_dir)
    report = {
        "schema_version": 1,
        "game": "Tiger Woods PGA Tour 2005 (Windows source media)",
        "method": "Pure Python ZIP and ISO9660 reads; no installer or game execution",
        "archive": {"file": args.archive.name, "bytes": args.archive.stat().st_size,
                    "sha256": digest_file(args.archive)},
        "media": archive_members,
        "discs": [],
        "limitations": [
            "Inventory and hashes establish available data, not engine behavior or gameplay fidelity.",
            "Asset and installer formats are identified by observed headers; not all are decoded.",
            "No original engine source or native playable PGA2005 build has been established.",
        ],
    }
    images = sorted(p for p in args.media_dir.iterdir()
                    if p.is_file() and p.suffix.lower() in (".iso", ".b6i"))
    if not images:
        raise ValueError("No source disc images found")
    for number, path in enumerate(images, 1):
        iso = ISO9660(path)
        try:
            entries = iso.files()
            for entry in entries:
                iso.inspect_file(entry, not args.no_file_hashes or bool(args.extract))
                if any(fnmatch(entry["path"].casefold(), pattern.casefold())
                       for pattern in args.extract):
                    iso.extract(entry, args.media_dir / f"disc{number}")
            extensions = Counter(Path(e["path"]).suffix.lower() or "(none)"
                                 for e in entries)
            disc = {"media_file": path.name, "bytes": path.stat().st_size,
                    "sha256": digest_file(path), "volume_id": iso.volume_id,
                    "volume_logical_blocks": iso.volume_blocks,
                    "layout": vars(iso.layout), "file_count": len(entries),
                    "extension_counts": dict(sorted(extensions.items())),
                    "files": entries}
            report["discs"].append(disc)
            print(f"Inspected {iso.volume_id}: {len(entries)} files", file=sys.stderr,
                  flush=True)
        finally:
            iso.close()
    args.report.parent.mkdir(parents=True, exist_ok=True)
    partial = args.report.with_suffix(args.report.suffix + ".partial")
    partial.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    partial.replace(args.report)
    print(args.report)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        print(f"Inspection failed: {error}", file=sys.stderr)
        raise SystemExit(1)
