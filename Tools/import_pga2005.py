#!/usr/bin/env python3
"""Import original course metadata and images from the user's local PGA 2005 disc.

No game code is run. No terrain mesh or gameplay equivalence is claimed. Output
belongs in ignored Library/Imported, not in the source repository. Standard
library only; supports the observed TGA and legacy DDS/DXT image formats.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import zlib

from inspect_pga2005 import ISO9660, digest_file, safe_target

MAX_PIXELS = 16 * 1024 * 1024


def dimensions(width: int, height: int):
    if not 0 < width <= 8192 or not 0 < height <= 8192 or width * height > MAX_PIXELS:
        raise ValueError(f"Invalid or oversized image: {width}x{height}")


def png_bytes(width: int, height: int, rgba: bytes) -> bytes:
    dimensions(width, height)
    if len(rgba) != width * height * 4:
        raise ValueError("RGBA size mismatch")

    def chunk(kind, payload):
        return (struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff))
    rows = b"".join(b"\0" + rgba[y * width * 4:(y + 1) * width * 4]
                    for y in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def decode_tga(data: bytes) -> tuple[int, int, bytes]:
    if len(data) < 18:
        raise ValueError("Truncated TGA header")
    id_bytes, color_map, kind = data[:3]
    width, height, depth, descriptor = struct.unpack_from("<HHBB", data, 12)
    dimensions(width, height)
    if color_map or kind not in (2, 3, 10, 11) or descriptor & 0xc0:
        raise ValueError("Unsupported TGA color map/type/interleaving")
    grayscale = kind in (3, 11)
    if depth not in ((8, 16) if grayscale else (16, 24, 32)):
        raise ValueError(f"Unsupported TGA pixel depth {depth}")
    size, cursor = depth // 8, 18 + id_bytes
    count = width * height
    pixels = []

    def read_pixel():
        nonlocal cursor
        if cursor + size > len(data):
            raise ValueError("Truncated TGA pixels")
        value = data[cursor:cursor + size]
        cursor += size
        if grayscale:
            return bytes((value[0], value[0], value[0], value[1] if size == 2 else 255))
        if size == 2:
            word = int.from_bytes(value, "little")
            return bytes((((word >> 10) & 31) * 255 // 31,
                          ((word >> 5) & 31) * 255 // 31,
                          (word & 31) * 255 // 31,
                          (255 if word & 0x8000 else 0) if descriptor & 15 else 255))
        return bytes((value[2], value[1], value[0], value[3] if size == 4 else 255))

    while len(pixels) < count:
        run, repeated = 1, False
        if kind in (10, 11):
            if cursor >= len(data):
                raise ValueError("Truncated TGA RLE packet")
            packet = data[cursor]
            cursor += 1
            run, repeated = (packet & 127) + 1, bool(packet & 128)
        if len(pixels) + run > count:
            raise ValueError("TGA RLE packet exceeds image")
        if repeated:
            pixels.extend([read_pixel()] * run)
        else:
            pixels.extend(read_pixel() for _ in range(run))
    result = bytearray(count * 4)
    for i, pixel in enumerate(pixels):
        x, y = i % width, i // width
        if descriptor & 0x10:
            x = width - 1 - x
        if not descriptor & 0x20:
            y = height - 1 - y
        target = (y * width + x) * 4
        result[target:target + 4] = pixel
    return width, height, bytes(result)


def rgb565(word):
    red, green, blue = word >> 11, (word >> 5) & 63, word & 31
    return ((red << 3) | (red >> 2), (green << 2) | (green >> 4),
            (blue << 3) | (blue >> 2))


def decode_dds(data: bytes) -> tuple[int, int, bytes]:
    if len(data) < 128 or data[:4] != b"DDS " or struct.unpack_from("<I", data, 4)[0] != 124:
        raise ValueError("Invalid DDS header")
    height, width = struct.unpack_from("<II", data, 12)
    dimensions(width, height)
    pfsize, flags, fourcc, bits, rm, gm, bm, am = struct.unpack_from("<II4sIIIII", data, 76)
    if pfsize != 32:
        raise ValueError("Invalid DDS pixel format")
    caps2 = struct.unpack_from("<I", data, 112)[0]
    if caps2:
        raise ValueError("DDS cubemap/volume textures are not supported")
    out = bytearray(width * height * 4)
    if flags & 4:
        if fourcc not in (b"DXT1", b"DXT3", b"DXT5"):
            raise ValueError(f"Unsupported DDS codec {fourcc!r}")
        blocksize = 8 if fourcc == b"DXT1" else 16
        blocks_x, blocks_y = (width + 3) // 4, (height + 3) // 4
        if 128 + blocks_x * blocks_y * blocksize > len(data):
            raise ValueError("Truncated DDS blocks")
        for by in range(blocks_y):
            for bx in range(blocks_x):
                base = 128 + (by * blocks_x + bx) * blocksize
                cbase = base if blocksize == 8 else base + 8
                c0, c1, indices = struct.unpack_from("<HHI", data, cbase)
                a, b = rgb565(c0), rgb565(c1)
                colors = [a + (255,), b + (255,)]
                if c0 > c1 or fourcc != b"DXT1":
                    colors += [tuple((2 * a[i] + b[i]) // 3 for i in range(3)) + (255,),
                               tuple((a[i] + 2 * b[i]) // 3 for i in range(3)) + (255,)]
                else:
                    colors += [tuple((a[i] + b[i]) // 2 for i in range(3)) + (255,), (0, 0, 0, 0)]
                alphas = None
                if fourcc == b"DXT3":
                    packed = int.from_bytes(data[base:base + 8], "little")
                    alphas = [((packed >> (i * 4)) & 15) * 17 for i in range(16)]
                elif fourcc == b"DXT5":
                    a0, a1 = data[base:base + 2]
                    table = [a0, a1]
                    table += ([( (7 - i) * a0 + i * a1) // 7 for i in range(1, 7)]
                              if a0 > a1 else [((5 - i) * a0 + i * a1) // 5 for i in range(1, 5)] + [0, 255])
                    packed = int.from_bytes(data[base + 2:base + 8], "little")
                    alphas = [table[(packed >> (i * 3)) & 7] for i in range(16)]
                for i in range(16):
                    x, y = bx * 4 + i % 4, by * 4 + i // 4
                    if x >= width or y >= height:
                        continue
                    color = colors[(indices >> (2 * i)) & 3]
                    if alphas is not None:
                        color = color[:3] + (alphas[i],)
                    offset = (y * width + x) * 4
                    out[offset:offset + 4] = bytes(color)
    elif flags & 0x40 and bits in (16, 24, 32):
        size = bits // 8
        pitch = width * size
        header_flags, stored_pitch = struct.unpack_from("<I", data, 8)[0], struct.unpack_from("<I", data, 20)[0]
        if header_flags & 8:
            if stored_pitch < pitch:
                raise ValueError("Invalid DDS row pitch")
            pitch = stored_pitch
        if 128 + pitch * height > len(data):
            raise ValueError("Truncated DDS RGB pixels")
        def channel(value, mask, default):
            if not mask:
                return default
            shift = (mask & -mask).bit_length() - 1
            maximum = mask >> shift
            if maximum & (maximum + 1):
                raise ValueError("Noncontiguous DDS channel mask")
            return ((value & mask) >> shift) * 255 // maximum
        for y in range(height):
            for x in range(width):
                offset = 128 + y * pitch + x * size
                word = int.from_bytes(data[offset:offset + size], "little")
                target = (y * width + x) * 4
                out[target:target + 4] = bytes(channel(word, m, default) for m, default in ((rm, 0), (gm, 0), (bm, 0), (am, 255)))
    else:
        raise ValueError("Unsupported DDS pixel layout")
    return width, height, bytes(out)


def parse_course_ini(data: bytes) -> dict:
    """Preserve duplicate keys and every raw coordinate; do not invent unit scale."""
    sections = []
    current = None
    for number, line in enumerate(data.decode("cp1252").splitlines(), 1):
        line = line.strip().lstrip("\ufeff")
        if not line or line.startswith((";", "'", "#")):
            continue
        match = re.fullmatch(r"\[([^\]]+)\]", line)
        if match:
            current = {"name": match[1], "entries": []}
            sections.append(current)
        elif "=" in line and current is not None:
            key, value = line.split("=", 1)
            current["entries"].append({"key": key.strip(), "value": value.strip(), "line": number})
    holes = []
    for section in sections:
        match = re.fullmatch(r"hole\s+(\d+)", section["name"], re.I)
        if not match:
            continue
        hole = {"number": int(match[1]), "pins": [], "tees": [], "pivots": []}
        for entry in section["entries"]:
            key, value = entry["key"].lower(), entry["value"]
            if key == "par":
                hole["par"] = int(value)
            elif key in ("yardage", "handicap"):
                try:
                    hole[key] = [int(n.strip()) for n in value.split(",")]
                except ValueError:
                    # Some shipped INIs contain typos such as "16.16.16".
                    # Keep raw data above and report it instead of repairing
                    # source values according to an unverified assumption.
                    hole.setdefault("warnings", []).append({"key": key, "raw": value,
                                                             "reason": "Not a comma-separated integer list"})
            elif re.fullmatch(r"(pin|tee|pivot)\d+", key):
                coordinates = [float(n.strip()) for n in value.split(",")]
                if len(coordinates) != 3 or any(not abs(v) < 1e9 for v in coordinates):
                    raise ValueError(f"Invalid {key} coordinates")
                kind = "pins" if key.startswith("pin") else "tees" if key.startswith("tee") else "pivots"
                hole[kind].append({"key": key, "xyz_raw": coordinates, "line": entry["line"]})
        holes.append(hole)
    return {"sections": sections, "holes": holes,
            "coordinate_units": "unverified; raw source values preserved",
            "limitations": ["INI metadata does not define the complete terrain mesh or materials.",
                            "Repeated pivot keys are preserved in file order, not silently overwritten."]}


def atomic_write(path: Path, data: bytes):
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_suffix(path.suffix + ".partial")
    partial.write_bytes(data)
    partial.replace(path)


def run_import(media: Path, output: Path):
    iso = ISO9660(media)
    result = {"schema_version": 1, "source_media": {"name": media.name, "sha256": digest_file(media)},
              "method": "Read-only disc extraction and native image conversion; no original code execution",
              "courses": {}, "images": [], "failures": [],
              "limitations": ["TCR terrain and TCL compiled libraries are not decoded by this importer.",
                              "Converted source textures are not improved or AI-upscaled.",
                              "This is asset import, not evidence of a faithful game rewrite."]}
    try:
        for entry in iso.files():
            source = entry["path"]
            parts = source.split("/")
            if len(parts) < 3 or parts[0] != "COURSES":
                continue
            suffix = Path(source).suffix.lower()
            if suffix not in (".ini", ".tga", ".dds", ".txt"):
                continue
            data = b"".join(iso.chunks(entry))
            digest = hashlib.sha256(data).hexdigest()
            relative = "/".join(parts[1:])
            provenance = {"source_path": source, "sha256": digest, "bytes": len(data)}
            if suffix == ".ini" and len(parts) == 3 and Path(source).stem == parts[1]:
                parsed = parse_course_ini(data)
                parsed["source"] = provenance
                result["courses"][parts[1]] = parsed
            elif suffix in (".tga", ".dds"):
                try:
                    width, height, pixels = (decode_tga(data) if suffix == ".tga" else decode_dds(data))
                    filename = str(Path(relative).with_suffix(".png"))
                    atomic_write(safe_target(output, filename), png_bytes(width, height, pixels))
                    result["images"].append({**provenance, "png": filename, "width": width, "height": height,
                                             "decoded_rgba_sha256": hashlib.sha256(pixels).hexdigest()})
                except ValueError as error:
                    result["failures"].append({**provenance, "reason": str(error)})
        atomic_write(output / "import-report.json", (json.dumps(result, indent=2) + "\n").encode())
    finally:
        iso.close()
    return result


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--media", type=Path, default=root / "Library/SourceMedia/pga2005/EA-TigerWoodsPGATour2005-CD3-CoursesDisc.B6I")
    parser.add_argument("--output", type=Path, default=root / "Library/Imported/pga2005")
    args = parser.parse_args()
    result = run_import(args.media, args.output)
    print(f"Imported {len(result['courses'])} courses' metadata and {len(result['images'])} images; {len(result['failures'])} unsupported images.")
    print(args.output / "import-report.json")


if __name__ == "__main__":
    main()
