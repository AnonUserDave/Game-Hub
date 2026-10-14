#!/usr/bin/env python3
"""Bounded offline readers for the owned THPS2/THUG media.

PKR2 stored entries, PRE3/PRX LZSS and THUG collision v9 are decoded without
executing original code. Geometry remains in original coordinates and units.
See docs/research/OTHER-WINDOWS.md for observations and format references.
"""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
import hashlib
import math
import struct

from inspect_pga2005 import safe_name

MAX_ENTRIES = 100_000
MAX_ASSET = 64 * 1024**2
MAX_VERTICES = 2_000_000
MAX_FACES = 4_000_000


def region(data, offset, count):
    if offset < 0 or count < 0 or offset + count > len(data):
        raise ValueError("Asset extent outside its source")
    return memoryview(data)[offset:offset + count]


def text_name(raw):
    raw = bytes(raw)
    if b"\0" not in raw:
        raise ValueError("Unterminated asset name")
    name = raw.split(b"\0", 1)[0].decode("ascii")
    if not name:
        raise ValueError("Empty asset name")
    return str(safe_name(name))


@dataclass(frozen=True)
class Asset:
    path: str
    offset: int
    size: int
    stored_size: int
    compression: str
    name_crc: int | None = None

    def read(self, source):
        stored = region(source, self.offset, self.stored_size)
        if self.size > MAX_ASSET:
            raise ValueError("Expanded asset exceeds 64 MiB")
        if self.compression == "stored":
            if self.size != self.stored_size:
                raise ValueError("Stored asset size mismatch")
            return bytes(stored)
        if self.compression == "lzss":
            return lzss(stored, self.size)
        raise ValueError(f"Unsupported compression {self.compression}")


def unique(entries):
    seen = set()
    for e in entries:
        key = e.path.casefold()
        if key in seen:
            raise ValueError(f"Duplicate asset path: {e.path}")
        seen.add(key)
    return entries


def pkr2(data):
    """Read PKR2 directory/file tables; refuse methods absent from this disc."""
    magic, version, dirs, files = struct.unpack("<4sIII", region(data, 0, 16))
    if magic != b"PKR2" or version != 1:
        raise ValueError("Unsupported PKR2 header")
    if dirs > MAX_ENTRIES or files > MAX_ENTRIES:
        raise ValueError("PKR2 table limit exceeded")
    table_start = 16 + dirs * 40
    table_end = table_start + files * 48
    region(data, 0, table_end)
    entries, visited = [], set()
    for i in range(dirs):
        raw, first, count = struct.unpack("<32sII", region(data, 16 + i * 40, 40))
        directory = text_name(raw)
        if first < table_start or (first - table_start) % 48 or first + count * 48 > table_end:
            raise ValueError("PKR2 directory points outside file table")
        for j in range(count):
            pos = first + j * 48
            if pos in visited:
                raise ValueError("PKR2 directories overlap")
            visited.add(pos)
            raw, method, start, expanded, stored = struct.unpack("<32siIII", region(data, pos, 48))
            name = text_name(raw)
            if "/" in name:
                raise ValueError("PKR2 filename contains a path")
            if method != -2 or stored != expanded:
                raise ValueError(f"Unsupported PKR2 compression {method}")
            if start < table_end:
                raise ValueError("PKR2 asset overlaps tables")
            region(data, start, stored)
            entries.append(Asset(str(safe_name(directory + "/" + name)), start,
                                 expanded, stored, "stored"))
    if len(visited) != files:
        raise ValueError("PKR2 has orphan file records")
    return unique(entries)


def pre3(data):
    declared, version, count = struct.unpack("<III", region(data, 0, 12))
    if declared != len(data) or version != 0xABCD0003 or count > MAX_ENTRIES:
        raise ValueError("Unsupported or incomplete PRE3 archive")
    entries, pos = [], 12
    for _ in range(count):
        expanded, compressed, length, crc = struct.unpack("<IIII", region(data, pos, 16))
        if not 0 < length <= 4096 or length % 4:
            raise ValueError("Invalid PRE3 name span")
        pos += 16
        name = text_name(region(data, pos, length))
        pos += length
        stored = compressed or expanded
        if expanded > MAX_ASSET:
            raise ValueError("PRE3 asset exceeds 64 MiB")
        region(data, pos, stored)
        entries.append(Asset(name, pos, expanded, stored,
                             "lzss" if compressed else "stored", crc))
        pos = (pos + stored + 3) & ~3
    if pos != len(data):
        raise ValueError("PRE3 archive has unexplained trailing bytes")
    return unique(entries)


def lzss(data, expected):
    """PRE3's 4 KiB ring, LSB-first flags and 3–18 byte absolute matches."""
    if not 0 <= expected <= MAX_ASSET:
        raise ValueError("LZSS output limit exceeded")
    ring = bytearray(4096)
    cursor, pos, out = 4096 - 18, 0, bytearray()
    while pos < len(data):
        flags = data[pos]
        pos += 1
        for bit in range(8):
            if pos == len(data):
                break
            if flags & (1 << bit):
                values = (data[pos],)
                pos += 1
                for value in values:
                    if len(out) == expected:
                        raise ValueError("LZSS exceeds declared output")
                    out.append(value)
                    ring[cursor] = value
                    cursor = (cursor + 1) & 4095
            else:
                if pos + 2 > len(data):
                    raise ValueError("Truncated LZSS match")
                first, second = data[pos], data[pos + 1]
                pos += 2
                start = first | ((second & 0xF0) << 4)
                length = (second & 15) + 3
                if len(out) + length > expected:
                    raise ValueError("LZSS exceeds declared output")
                for n in range(length):
                    value = ring[(start + n) & 4095]
                    out.append(value)
                    ring[cursor] = value
                    cursor = (cursor + 1) & 4095
    if len(out) != expected:
        raise ValueError(f"LZSS size mismatch: {len(out)} != {expected}")
    return bytes(out)


def collision_v9(data):
    return _collision(data, 9)


def collision_v10(data):
    return _collision(data, 10)


def _collision(data, accepted_version):
    """Decode original collision triangles into compact native GHSC v1 data.

    BSP data is retained in the source only. This exports geometry, face flags,
    terrain types and object checksums, not original collision behavior.
    """
    if len(data) > MAX_ASSET:
        raise ValueError("Collision source exceeds 64 MiB")
    version, objects, verts, large_faces, small_faces, large_verts, small_verts, pad = \
        struct.unpack("<8I", region(data, 0, 32))
    if version != accepted_version:
        raise ValueError(f"Only observed collision v{accepted_version} is supported: {version}")
    if objects > MAX_ENTRIES or verts > MAX_VERTICES or large_faces + small_faces > MAX_FACES:
        raise ValueError("Collision count limit exceeded")
    if large_verts + small_verts != verts:
        raise ValueError("Collision vertex totals disagree")
    if 20 + objects * 24 + verts * 12 + (large_faces + small_faces) * 16 > MAX_ASSET:
        raise ValueError("Native collision expansion exceeds 64 MiB")
    vbase = (32 + objects * 64 + 15) & ~15
    ibase = vbase + large_verts * 12 + small_verts * 6
    fbase = (ibase + verts + 3) & ~3
    region(data, vbase, fbase - vbase)
    face_bytes = large_faces * 10 + small_faces * 8
    region(data, fbase, face_bytes)
    points, faces, records = bytearray(), bytearray(), []
    terrain, flags_hist = Counter(), Counter()
    total_v = total_f = 0
    for i in range(objects):
        rec = region(data, 32 + i * 64, 64)
        checksum, flags, nv, nf, small, fixed, face_offset = struct.unpack_from("<IHHHBBI", rec)
        bounds = struct.unpack_from("<8f", rec, 16)
        voff, bsp, intensity, padding = struct.unpack_from("<4I", rec, 48)
        # Source spans may overlap. Reject cumulative object counts before
        # expanding them, so repeated spans cannot bypass the header-based
        # native allocation bound while waiting for the final totals check.
        if total_v + nv > verts:
            raise ValueError("Collision object vertex total exceeds header")
        if total_f + nf > large_faces + small_faces:
            raise ValueError("Collision object face total exceeds header")
        if small not in (0, 1) or fixed not in (0, 1):
            raise ValueError("Invalid collision encoding flags")
        if not all(math.isfinite(v) for v in bounds):
            raise ValueError("Nonfinite collision bounds")
        stride = 6 if fixed else 12
        source = region(data, vbase + voff, nv * stride)
        if vbase + voff + nv * stride > ibase:
            raise ValueError("Collision vertex extent overlaps intensities")
        region(data, ibase + intensity, nv)
        if intensity + nv > verts:
            raise ValueError("Collision intensity extent overlaps faces")
        for j in range(nv):
            values = struct.unpack_from("<3H" if fixed else "<3f", source, j * stride)
            xyz = tuple(bounds[k] + values[k] / 16 for k in range(3)) if fixed else values
            if not all(math.isfinite(v) for v in xyz):
                raise ValueError("Nonfinite collision vertex")
            points.extend(struct.pack("<3f", *xyz))
        fstride = 8 if small else 10
        if face_offset + nf * fstride > face_bytes:
            raise ValueError("Collision face extent overlaps BSP data")
        source = region(data, fbase + face_offset, nf * fstride)
        for j in range(nf):
            flag, kind = struct.unpack_from("<HH", source, j * fstride)
            indices = struct.unpack_from("<3B" if small else "<3H", source, j * fstride + 4)
            if any(index >= nv for index in indices):
                raise ValueError("Collision face index outside object vertices")
            faces.extend(struct.pack("<3IHH", *(total_v + index for index in indices), flag, kind))
            terrain[str(kind)] += 1
            flags_hist[f"0x{flag:04x}"] += 1
        records.append(struct.pack("<6I", checksum, flags, total_v, nv, total_f, nf))
        total_v += nv
        total_f += nf
    if total_v != verts or total_f != large_faces + small_faces:
        raise ValueError("Collision object totals disagree with header")
    output = struct.pack("<4s4I", b"GHSC", 1, objects, total_v, total_f) + b"".join(records) + points + faces
    report = {"format": f"collision-v{version}", "source_sha256": hashlib.sha256(data).hexdigest(),
              "source_bytes": len(data), "objects": objects, "vertices": total_v,
              "triangles": total_f, "terrain_types": dict(terrain), "face_flags": dict(flags_hist),
              "native_bytes": len(output), "native_sha256": hashlib.sha256(output).hexdigest(),
              "limitations": ["Original raw coordinates and units; no axis conversion",
                              "BSP traversal, moving geometry and collision behavior are not implemented"]}
    return output, report
