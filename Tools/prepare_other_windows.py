#!/usr/bin/env python3
"""Prepare supplied Windows game data offline; never run installers/game code.

Outputs and original bytes stay in ignored Library directories. Small receipt
summaries may be committed: they contain identities/counts, never original data.
The decoded collision data is research infrastructure, not a completed rewrite.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import mmap
from pathlib import Path
import re
import stat
import struct
import subprocess
import zipfile

from import_pga2005 import atomic_write
from inspect_pga2005 import ISO9660, digest_file, safe_name, safe_target
from installshield_cab import Cabinet
from neversoft_assets import pre3, pkr2, collision_v9, collision_v10, MAX_ASSET

TITLES = {
    "pga2004": "Tiger_Woods_PGA_Tour_2004_Disc1_Win_ISO_EN.zip",
    "thps2": "Tony_Hawks_Pro_Skater_2_Win_ISO_EN.zip",
    "thug": "THUG_Win_ROM_EN.zip",
    "thug2": "THUG2_Win_ROM_EN.zip",
}
BLOCK = 4 * 1024**2
MAX_ZIP = 8 * 1024**3


def save_json(path, value):
    atomic_write(path, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode())


def file_record(path, label):
    return {"path": label, "bytes": path.stat().st_size, "sha256": digest_file(path)}


def zip_copy(zipped, entry, target):
    if stat.S_ISLNK(entry.external_attr >> 16):
        raise ValueError("Archive symlinks are refused")
    if target.is_symlink():
        raise ValueError("Existing source symlinks are refused")
    partial = target.with_name(target.name + ".partial")
    target.parent.mkdir(parents=True, exist_ok=True)
    if partial.exists():
        raise ValueError(f"Unfinished extraction present: {partial}")
    try:
        hasher = hashlib.sha256()
        with zipped.open(entry) as source, partial.open("xb") as output:
            written = 0
            while chunk := source.read(BLOCK):
                written += len(chunk)
                if written > entry.file_size:
                    raise ValueError("ZIP member exceeds its declared size")
                output.write(chunk)
                hasher.update(chunk)
        if partial.stat().st_size != entry.file_size:
            raise ValueError("Incomplete ZIP extraction")
        if target.exists():
            if not target.is_file() or digest_file(target) != hasher.hexdigest():
                raise ValueError(f"Existing source differs from archive: {target}")
            partial.unlink()
        else:
            partial.replace(target)
    finally:
        if partial.exists():
            partial.unlink()
    return {"zip_path": entry.filename, "file": target.name, "bytes": entry.file_size,
            "zip_crc32": f"{entry.CRC:08x}", "sha256": hasher.hexdigest()}


def extract_selected(archive, title, destination):
    records = []
    with zipfile.ZipFile(archive) as zipped:
        if sum(e.file_size for e in zipped.infolist()) > MAX_ZIP:
            raise ValueError("ZIP expansion exceeds 8 GiB")
        selected = []
        for e in zipped.infolist():
            if e.is_dir():
                continue
            name = safe_name(e.filename)
            if title == "thug":
                if "/Game/Data/pre/" in e.filename and name.suffix.lower() == ".pre" and "_NET" not in name.name:
                    if name.name.lower().endswith(("col.pre", "scn.pre")) or name.name == "qb.pre":
                        selected.append((e, "pre/" + name.name))
                elif e.filename.endswith("/Game/THUG.exe"):
                    selected.append((e, "engine/THUG.exe"))
            elif name.suffix.lower() in (".iso", ".bin", ".cue"):
                selected.append((e, name.name))
        keys = [n.casefold() for _, n in selected]
        if len(set(keys)) != len(keys):
            raise ValueError("Selected ZIP members collide")
        for entry, relative in selected:
            records.append(zip_copy(zipped, entry, safe_target(destination, relative)))
    return records


def iso_inventory(paths):
    records = []
    for path in paths:
        iso = ISO9660(path)
        try:
            records.append({"image": path.name, "volume_id": iso.volume_id,
                            "sector_bytes": iso.layout.physical_sector_bytes,
                            "payload_offset": iso.layout.payload_offset,
                            "files": iso.files()})
        finally:
            iso.close()
    return records


def extract_disc_files(paths, wanted, destination):
    records = []
    for path in paths:
        iso = ISO9660(path)
        try:
            for e in iso.files():
                if e["path"] in wanted:
                    target = safe_target(destination, e["path"])
                    hasher = hashlib.sha256()
                    for chunk in iso.chunks(e):
                        hasher.update(chunk)
                    if target.exists():
                        if not target.is_file() or digest_file(target) != hasher.hexdigest():
                            raise ValueError("Existing disc file does not match source")
                    else:
                        iso.extract(e, destination)
                    records.append({"image": path.name, **file_record(target, e["path"])})
        finally:
            iso.close()
    return records


def prepare_pga2004(source, paths):
    with Cabinet.from_isos(paths) as cabinet:
        entries = list(cabinet.files())
        groups = [{"name": g.name, "first": g.first_file, "last": g.last_file}
                  for g in cabinet.groups()]
        records = []
        for e in entries:
            lower = e.path.lower()
            if (e.group == "Executable" and e.name in ("Engine.dll", "CourseData.dll") or
                    lower in {f"{c}/{c}.{ext}" for c in ("pbl", "saw", "sta") for ext in ("tcr", "tcl", "ini")}):
                cabinet.extract(e, source / "install", layout="directory")
                target = safe_target(source / "install", str(e.relative_path("directory")))
                records.append({"cabinet_index": e.index, "volume": e.volume,
                                **file_record(target, e.path)})
        versions = {c: struct.unpack_from("<H", (source / "install" / c / f"{c.lower()}.tcr").read_bytes(), 0)[0]
                    for c in ("PBL", "SAW", "STA")}
        available = set()
        for path in paths:
            iso = ISO9660(path)
            try:
                for entry in iso.files():
                    match = re.fullmatch(r"DATA(\d+)\.CAB", safe_name(entry["path"]).name, re.IGNORECASE)
                    if match:
                        available.add(int(match.group(1)))
            finally:
                iso.close()
        required = {e.volume for e in entries}
        return {"cabinet_version": cabinet.major_version, "files": len(entries),
                "header_file_slots": cabinet.file_count,
                "groups": groups, "required_volumes": sorted({e.volume for e in entries}),
                "available_volumes": sorted(available), "missing_volumes": sorted(required - available),
                "selected_files": records, "tcr_versions": versions,
                "limitations": ["Only disc1 supplied; cabinet volume3 unavailable",
                                "PGA2004 TCR v4 is not supported by the PGA2005 v7 terrain decoder",
                                "No PGA2004 runtime or behavior reconstruction yet"]}


def unpack_pre(path, output):
    if path.stat().st_size > 128 * 1024**2:
        raise ValueError("PRE3 source exceeds offline mapping limit")
    records, collisions, unsupported = [], [], []
    with path.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as mapped:
        entries = pre3(mapped)
        for e in entries:
            # Scene, textures, scripts and collision are retained for static
            # work; sound and movie PREs are outside this preparation scope.
            lower = e.path.lower()
            if not lower.endswith((".col.xbx", ".col", ".scn.xbx", ".tex.xbx", ".qb")):
                continue
            raw = e.read(mapped)
            digest = hashlib.sha256(raw).hexdigest()
            original_path = "original-by-sha/" + digest + "/" + safe_name(e.path).name
            target = safe_target(output, original_path)
            atomic_write(target, raw)
            records.append({"path": e.path, "bytes": len(raw),
                            "sha256": digest, "compression": e.compression, "original_path": original_path})
            if lower.endswith((".col.xbx", ".col")):
                version = struct.unpack_from("<I", raw, 0)[0]
                if version not in (9, 10):
                    unsupported.append({"path": e.path, "collision_version": version})
                    continue
                native, report = (collision_v9 if version == 9 else collision_v10)(raw)
                relative = "collision/" + digest + ".ghsc"
                atomic_write(safe_target(output, relative), native)
                save_json(safe_target(output, relative + ".json"), report)
                collisions.append({"path": e.path, "native_path": relative, "collision_version": version,
                                   **{k: report[k] for k in ("source_sha256", "objects", "vertices", "triangles", "native_bytes", "native_sha256")}})
    return {"archive": path.name, "entries": len(entries), "selected": records,
            "collisions": collisions, "unsupported_collisions": unsupported}


def prepare_thps2(source, output):
    pack = source / "disc-files/SETUP/DATA/ALL.PKR"
    pack_hash = digest_file(pack)
    with pack.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as mapped:
        entries = pkr2(mapped)
        counts = Counter(e.path.rsplit(".", 1)[-1].lower() for e in entries)
        records = []
        for e in entries:
            raw = e.read(mapped)
            atomic_write(safe_target(output / "original" / pack_hash, e.path), raw)
            records.append({"path": e.path, "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()})
    save_json(output / "pkr-inventory.json", records)
    return {"format": "PKR2", "entries": len(entries), "extensions": dict(counts),
            "pack_sha256": pack_hash, "original_base": "original/" + pack_hash,
            "inventory_sha256": digest_file(output / "pkr-inventory.json"),
            "limitations": ["Original pack decoded; level PSX mesh/material and TRG behavior loaders unfinished",
                            "No THPS2 native gameplay implementation yet"]}


def microsoft_cab_inventory(path):
    """Preflight Microsoft CAB filenames and expanded sizes before libarchive."""
    with path.open("rb") as stream:
        header = stream.read(36)
        if len(header) != 36:
            raise ValueError("Truncated Microsoft CAB header")
        magic, r1, size, r2, first, r3, minor, major, folders, count, flags, set_id, volume = \
            struct.unpack("<4s5IBB5H", header)
        if magic != b"MSCF" or major != 1 or minor != 3 or size != path.stat().st_size:
            raise ValueError("Unsupported or incomplete Microsoft CAB")
        if flags & ~7 or first < 36 or first + count * 17 > size:
            raise ValueError("Invalid Microsoft CAB file table")
        stream.seek(first)
        records, keys, total = [], set(), 0
        for _ in range(count):
            raw = stream.read(16)
            if len(raw) != 16:
                raise ValueError("Truncated Microsoft CAB file record")
            expanded, offset, folder, date, time, attributes = struct.unpack("<II4H", raw)
            if folder >= folders:
                raise ValueError("Spanned Microsoft CAB member unsupported")
            if expanded > MAX_ASSET:
                raise ValueError("CAB member expansion exceeds 64 MiB")
            name = bytearray()
            while True:
                byte = stream.read(1)
                if not byte or len(name) >= 4096:
                    raise ValueError("Truncated or oversized Microsoft CAB name")
                if byte == b"\0":
                    break
                name += byte
            if not name:
                raise ValueError("Empty Microsoft CAB member name")
            # UTF-8 CAB filenames carry the 0x80 attribute. Other names in
            # these supplied cabinets are ASCII MSI identity keys.
            relative = str(safe_name(name.decode("utf-8" if attributes & 0x80 else "ascii")))
            if relative.casefold() in keys:
                raise ValueError("Microsoft CAB path collision")
            keys.add(relative.casefold())
            total += expanded
            if total > MAX_ZIP:
                raise ValueError("CAB expansion exceeds 8 GiB")
            records.append({"path": relative, "bytes": expanded})
    return records


def unpack_microsoft_cab(path, destination):
    # macOS's existing libarchive reader understands the original Microsoft
    # CAB compression. Validate the complete member list before extraction.
    expected = microsoft_cab_inventory(path)
    result = subprocess.run(["/usr/bin/bsdtar", "-tf", str(path)], check=True,
                            capture_output=True, text=True)
    names = result.stdout.splitlines()
    if len(names) > 100_000 or len(set(n.casefold() for n in names)) != len(names):
        raise ValueError("CAB member count or path collision")
    for name in names:
        safe_target(destination, name)
    if names != [entry["path"] for entry in expected]:
        raise ValueError("CAB listing disagrees with source file table")
    if destination.is_symlink():
        raise ValueError("Existing CAB destination is a symlink")
    destination.mkdir(parents=True, exist_ok=True)
    for name in names:
        target = safe_target(destination, name)
        if target.is_symlink():
            raise ValueError("Existing CAB member is a symlink")
    subprocess.run(["/usr/bin/bsdtar", "-xf", str(path), "-C", str(destination)], check=True)
    files = []
    for entry in expected:
        name = entry["path"]
        target = safe_target(destination, name)
        if target.is_symlink() or not target.is_file() or target.stat().st_size != entry["bytes"]:
            raise ValueError("CAB extraction did not produce a regular file")
        files.append(target)
    if sum(p.stat().st_size for p in files) > MAX_ZIP:
        raise ValueError("CAB output exceeds 8 GiB")
    return files


def prepare(title, root):
    archive = root / TITLES[title]
    source = root / "Library/SourceMedia" / title
    output = root / "Library/Imported" / title
    source.mkdir(parents=True, exist_ok=True)
    report = {"title": title, "archive": file_record(archive, archive.name),
              "scope": "offline-content-preparation", "hardware": "M5 Pro development; M1 unverified",
              "media": extract_selected(archive, title, source)}
    if title != "thug":
        paths = sorted([p for p in source.iterdir() if p.suffix.lower() in (".iso", ".bin")])
        report["disc_inventory"] = iso_inventory(paths)
    if title == "pga2004":
        report["preparation"] = prepare_pga2004(source, paths)
    elif title == "thps2":
        report["disc_files"] = extract_disc_files(paths, {"SETUP/DATA/ALL.PKR", "SETUP/DATA/THAWK2.EXE"}, source / "disc-files")
        report["preparation"] = prepare_thps2(source, output)
    elif title == "thug":
        report["preparation"] = [unpack_pre(p, output) for p in sorted((source / "pre").glob("*.pre"))]
    else:
        wanted = {"LEVELS.CAB", "PRE.CAB", "ALLOTH~1.CAB"}
        report["disc_files"] = extract_disc_files(paths, wanted, source / "disc-files")
        prepared = []
        for name in sorted(wanted):
            cabinet = source / "disc-files" / name
            files = unpack_microsoft_cab(cabinet, source / "cabinet-files" / cabinet.stem)
            records = []
            for path in files:
                with path.open("rb") as stream:
                    head = stream.read(12)
                if len(head) >= 12 and struct.unpack_from("<I", head, 4)[0] == 0xABCD0003:
                    record = unpack_pre(path, output)
                    records.append(record)
            prepared.append({"cabinet": name, "members": len(files), "pre_archives": records})
        report["preparation"] = prepared
        report["limitations"] = ["All three discs readable; complete installed-game coverage unverified",
                                 "Only selected CABs prepared; MSI name mapping and other CAB groups unfinished",
                                 "No THUG2 native gameplay implementation yet"]
    save_json(output / "preparation-receipt.json", report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--titles", nargs="+", choices=list(TITLES), default=list(TITLES))
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    for title in args.titles:
        report = prepare(title, root)
        print(f"{title}: source hash {report['archive']['sha256']}; receipt Library/Imported/{title}/preparation-receipt.json", flush=True)


if __name__ == "__main__":
    main()
