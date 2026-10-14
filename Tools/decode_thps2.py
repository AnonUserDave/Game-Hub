#!/usr/bin/env python3
"""Bounded static THPS2 PSX v4 / TRG v2 readers and local level preparation.

The source uses s7.24 placement + s3.12 model vertices. Raw integer fields,
planes, flags, UVs, extension bytes and undecoded TRG payloads are retained.
This reconstructs supplied content, not the original script VM/skating solver.
See docs/research/THPS2.md. Original and prepared media must stay ignored.
"""
from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
import struct

MAX_SOURCE = 64 * 1024**2
MAX_RECORDS = 100_000
MAX_GEOMETRY = 2_000_000
MAX_PIXELS = 8_000_000


def span(data, offset, size, limit=None):
    end = len(data) if limit is None else min(len(data), limit)
    if offset < 0 or size < 0 or offset + size > end:
        raise ValueError("THPS2 record outside source extent")
    return memoryview(data)[offset:offset + size]


def unpack(data, fmt, offset, limit=None):
    return struct.unpack(fmt, span(data, offset, struct.calcsize(fmt), limit))


def count(value, maximum=MAX_RECORDS):
    if value > maximum:
        raise ValueError("THPS2 count exceeds resource budget")
    return value


def read_source(path):
    if path.stat().st_size > MAX_SOURCE:
        raise ValueError("THPS2 source exceeds 64 MiB")
    return path.read_bytes()


@dataclass(frozen=True)
class Face:
    offset: int
    flags: int
    length: int
    indices: tuple
    colors: tuple
    plane: int
    surface: int
    texture_index: int | None
    uv: tuple | None
    extension: bytes

    @property
    def corner_count(self):
        return 3 if self.flags & 0x10 else 4


@dataclass(frozen=True)
class Model:
    offset: int
    flags: int
    radius: int
    bounds: tuple
    unknown: int
    vertices: tuple
    planes: tuple
    faces: tuple


@dataclass(frozen=True)
class Texture:
    offset: int
    flags: int
    colors: int
    palette_name: int
    name_index: int
    width: int
    height: int
    storage_width: int
    storage_height: int
    pixels: bytes


@dataclass(frozen=True)
class BlockMap:
    bounds_fixed24: tuple
    dimensions: tuple
    cells: tuple


def blockmap(data, offset, size, object_count):
    end = offset + size
    xmin, zmin, xmax, zmax, width, height = unpack(data, "<4i2H", offset, end)
    if xmax <= xmin or zmax <= zmin or not width or not height or width * height > MAX_RECORDS:
        raise ValueError("Invalid THPS2 blockmap dimensions")
    pos, cells, refs = offset + 20, [], 0
    for _ in range(width * height):
        first, second, n = unpack(data, "<3I", pos, end); pos += 12
        refs += n
        if refs > MAX_GEOMETRY:
            raise ValueError("THPS2 blockmap reference budget exceeded")
        indices = unpack(data, "<" + "I" * n, pos, end); pos += n * 4
        last = unpack(data, "<I", pos, end)[0]; pos += 4
        if first or second or last or any(i >= object_count for i in indices):
            raise ValueError("Unqualified THPS2 blockmap cell or invalid object index")
        cells.append(indices)
    if pos != end:
        raise ValueError("Unexplained THPS2 blockmap bytes")
    return BlockMap((xmin, zmin, xmax, zmax), (width, height), tuple(cells))


@dataclass(frozen=True)
class PSX:
    objects: tuple
    models: tuple
    model_names: tuple
    texture_names: tuple
    palette4: dict
    palette8: dict
    textures: tuple
    gouraud: bytes | None
    chunks: tuple
    source_sha256: str
    blockmaps: tuple

    def summary(self):
        return dict(sha256=self.source_sha256, objects=len(self.objects), models=len(self.models),
                    vertices=sum(len(m.vertices) for m in self.models),
                    planes=sum(len(m.planes) for m in self.models),
                    faces=sum(len(m.faces) for m in self.models),
                    visible_faces=sum(not f.flags & 0x80 for m in self.models for f in m.faces),
                    texture_names=len(self.texture_names), textures=len(self.textures),
                    palette4=len(self.palette4), palette8=len(self.palette8),
                    face_flags={f"{k:04x}": v for k, v in sorted(Counter(f.flags for m in self.models for f in m.faces).items())},
                    surface_flags={f"{k:04x}": v for k, v in sorted(Counter(f.surface for m in self.models for f in m.faces).items())},
                    chunks=[dict(type=f"{t:08x}", offset=o, size=s) for t, o, s in self.chunks],
                    blockmaps=[dict(bounds_fixed24=m.bounds_fixed24, dimensions=m.dimensions, object_references=sum(len(c) for c in m.cells)) for m in self.blockmaps])


def psx_v4(data):
    if len(data) > MAX_SOURCE:
        raise ValueError("THPS2 source exceeds 64 MiB")
    version, magic, tags = unpack(data, "<HHI", 0)
    if (version, magic) != (4, 2):
        raise ValueError("Only supplied THPS2 PSX v4/2 is supported")
    no = count(unpack(data, "<I", 8)[0])
    table = 12 + no * 36
    span(data, 12, no * 36)
    objects = tuple(unpack(data, "<IiiiIHHhhII", 12 + i * 36) for i in range(no))
    nm = count(unpack(data, "<I", table)[0])
    table += 4
    offsets = unpack(data, "<" + "I" * nm, table)
    table += nm * 4
    if not table <= tags <= len(data) - 4:
        raise ValueError("THPS2 tagged section overlaps object/model tables")
    # Models must occupy independent regions before tags. Reject aliased spans
    # before decoding counts to prevent repeated records multiplying allocation.
    ordered = sorted(offsets)
    if len(set(offsets)) != nm or any(o < table or o >= tags for o in offsets):
        raise ValueError("THPS2 model pointer overlap or invalid extent")
    limits = dict(zip(ordered, ordered[1:] + [tags]))
    models, total_vertices, total_planes, total_faces = [], 0, 0, 0
    for offset in offsets:
        end = limits[offset]
        mf, nv, np, nf, radius, *tail = unpack(data, "<4HI6hI", offset, end)
        total_vertices += nv
        total_planes += np
        total_faces += nf
        for n in (total_vertices, total_planes, total_faces):
            count(n, MAX_GEOMETRY)
        pos = offset + 28
        vertices = unpack(data, "<" + "hhhh" * nv, pos, end)
        vertices = tuple(vertices[i:i + 4] for i in range(0, len(vertices), 4))
        pos += nv * 8
        planes = unpack(data, "<" + "hhhh" * np, pos, end)
        planes = tuple(planes[i:i + 4] for i in range(0, len(planes), 4))
        pos += np * 8
        faces = []
        for _ in range(nf):
            start = pos
            flags, length, *fields = unpack(data, "<HH8BHH", start, end)
            if length < 16 or length % 4:
                raise ValueError("Invalid THPS2 face length")
            span(data, start, length, end)
            idx = tuple(fields[:4])
            col = tuple(fields[4:8])
            plane, surface = fields[8:]
            if any(v >= nv for v in idx) or plane >= np:
                raise ValueError("THPS2 face references invalid vertex/plane")
            pos = start + 16
            ti, uv = None, None
            if flags & 2:
                if mf & 1:
                    raise ValueError("Unqualified THPS2 model texture layout")
                ti = unpack(data, "<I", pos, start + length)[0]
                pos += 4
            if flags & 1:
                u = unpack(data, "<8B", pos, start + length)
                uv = tuple(zip(u[::2], u[1::2]))
                pos += 8
            # Keep extension fields verbatim; subdivision/draw semantics are
            # explicitly not reconstructed by this content parser.
            extra = bytes(span(data, pos, start + length - pos, end))
            faces.append(Face(start, flags, length, idx, col, plane, surface, ti, uv, extra))
            pos = start + length
        if pos != end:
            raise ValueError("Unexplained THPS2 bytes between models")
        models.append(Model(offset, mf, radius, tuple(tail[:6]), tail[6], vertices, planes, tuple(faces)))
    if any(o[6] >= nm for o in objects):
        raise ValueError("THPS2 placement references invalid model")
    pos, chunks, gouraud = tags, [], None
    while True:
        kind = unpack(data, "<I", pos)[0]
        pos += 4
        if kind == 0xFFFFFFFF:
            break
        size = unpack(data, "<I", pos)[0]
        pos += 4
        region = span(data, pos, size)
        if len(chunks) >= 1024:
            raise ValueError("THPS2 chunk limit")
        chunks.append((kind, pos, size))
        if kind == 0x73424752:
            if not 0 < size <= 1024 or size % 4 or gouraud is not None:
                raise ValueError("Invalid THPS2 RGBs chunk")
            gouraud = bytes(region)
        pos += size
    model_names = unpack(data, "<" + "I" * nm, pos)
    pos += nm * 4
    nt = count(unpack(data, "<I", pos)[0])
    pos += 4
    texture_names = unpack(data, "<" + "I" * nt, pos)
    pos += nt * 4
    palettes = []
    for colors in (16, 256):
        n = count(unpack(data, "<I", pos)[0]); pos += 4
        palette = {}
        for _ in range(n):
            name = unpack(data, "<I", pos)[0]; pos += 4
            if name in palette:
                raise ValueError("Duplicate THPS2 palette")
            palette[name] = unpack(data, "<" + "H" * colors, pos)
            pos += colors * 2
        palettes.append(palette)
    ntex = count(unpack(data, "<I", pos)[0]); pos += 4
    tex_offsets = unpack(data, "<" + "I" * ntex, pos); pos += ntex * 4
    textures, total_pixels = [], 0
    for offset in tex_offsets:
        if offset != pos:
            raise ValueError("Overlapping or unexplained THPS2 texture extent")
        flags, colors, palette_name, ni, w, h = unpack(data, "<4IHH", pos)
        pos += 20
        if colors not in (16, 256) or not 0 < w <= 2048 or not 0 < h <= 2048 or ni >= nt:
            raise ValueError("Unqualified THPS2 texture format or dimensions")
        palette = palettes[0 if colors == 16 else 1]
        if palette_name not in palette:
            raise ValueError("THPS2 texture references missing palette")
        alignment = 4 if colors == 16 else 2
        sw, sh = (w + alignment - 1) & -alignment, h
        total_pixels += sw * sh
        count(total_pixels, MAX_PIXELS)
        size = sw * sh // (2 if colors == 16 else 1)
        pixels = bytes(span(data, pos, size)); pos += size
        textures.append(Texture(offset, flags, colors, palette_name, ni, w, h, sw, sh, pixels))
    if pos != len(data):
        raise ValueError("Unexplained THPS2 trailing source bytes")
    for obj in objects:
        if obj[-1]:
            span(data, obj[-1], 4)
    for model in models:
        for face in model.faces:
            if face.texture_index is not None and face.texture_index >= nt:
                raise ValueError("THPS2 face references invalid texture")
            if face.flags & 0x800 and (gouraud is None or any(c * 4 + 4 > len(gouraud) for c in face.colors[:face.corner_count])):
                raise ValueError("THPS2 gouraud face lacks RGBs palette")
    maps = tuple(blockmap(data, o, s, no) for t, o, s in chunks if t == 10)
    return PSX(objects, tuple(models), model_names, texture_names, palettes[0], palettes[1],
               tuple(textures), gouraud, tuple(chunks), hashlib.sha256(data).hexdigest(), maps)


def texture_rgba(source, texture):
    """Preserve PS1 zero transparency; retain STP in raw palettes for later blend RE.

    Nonzero color entries are opaque here. Original half/add/subtract blending
    is not inferred from palette bit 15. Source shader comparison is pending.
    """
    palette = (source.palette4 if texture.colors == 16 else source.palette8)[texture.palette_name]
    colors = []
    for value in palette:
        channels = tuple(((value >> shift) & 31) * 255 // 31 for shift in (0, 5, 10))
        colors.append(bytes((*channels, 0 if value == 0 else 255)))
    rgba = bytearray()
    for y in range(texture.height):
        for x in range(texture.width):
            pixel = y * texture.storage_width + x
            index = (texture.pixels[pixel // 2] >> ((pixel & 1) * 4)) & 15 if texture.colors == 16 else texture.pixels[pixel]
            rgba += colors[index]
    return bytes(rgba)


NODE_NAMES = {1: "baddy", 2: "crate", 3: "point", 4: "autoexec", 5: "pickup", 6: "commandpoint",
              8: "restart", 10: "railpoint", 11: "raildef", 12: "trickobject", 13: "camera",
              14: "goalobject", 15: "autoexec2", 255: "terminator", 501: "offlight", 1000: "scriptpoint"}


# This is framing of qualified command-list records, not a VM. Unknown
# opcodes stop decoding at their own source address, preserving the rest.
COMMAND_WORDS = {
    3: ("send-pulse", 0), 4: ("send-activate", 0), 5: ("send-suspend", 0),
    10: ("send-signal", 0), 11: ("send-kill", 0), 12: ("send-kill-loudly", 0),
    13: ("send-visible", 1), 104: ("fog-parameters", 3), 130: ("camera-angle", 2),
    131: ("background-on", 1), 132: ("background-off", 1), 134: ("initial-pulses", 1),
    135: ("camera-distance-xz", 2), 143: ("camera-distance-y", 2),
    144: ("camera-offset-x", 2), 145: ("camera-offset-y", 2), 146: ("camera-offset-z", 2),
    147: ("game-level", 1), 149: ("endif", 0), 151: ("dual-buffer-size", 1),
    152: ("kill-skater", 0), 153: ("camera-collision-side", 1), 155: ("midi-fade-in", 1),
    157: ("reverb-type", 1), 158: ("end-level", 0), 166: ("ordering-pushback", 1),
    167: ("camera-zoom", 2), 169: ("ordering-pushback2", 1), 200: ("fade-color", 2),
    202: ("sky-color", 2), 203: ("set-career-flag", 1), 204: ("if-career-flag", 1),
    65535: ("end-command-list", 0),
}
COMMAND_STRINGS = {126: "spool-in", 128: "spool-in2", 140: "restart", 142: "object-file", 178: "restart2"}


def command_list(data, start, end):
    pos, rows = start, []
    def string():
        nonlocal pos
        begin = pos
        while pos < end and data[pos] and pos - begin <= 256:
            pos += 1
        if pos >= end or pos - begin > 256:
            raise ValueError("Invalid THPS2 command string")
        value = bytes(span(data, begin, pos - begin)).decode("ascii")
        pos = (pos + 2) & ~1
        if pos > end:
            raise ValueError("THPS2 command alignment exceeds node")
        return value
    while pos < end:
        at = pos
        opcode = unpack(data, "<H", pos, end)[0]; pos += 2
        row = dict(offset=at, opcode=opcode)
        if opcode in COMMAND_WORDS:
            name, n = COMMAND_WORDS[opcode]
            row.update(kind=name, words=unpack(data, "<" + "H" * n, pos, end)); pos += n * 2
        elif opcode in COMMAND_STRINGS:
            row.update(kind=COMMAND_STRINGS[opcode], string=string())
        elif opcode == 2:
            # Supplied restart lists do not always contain a terminating empty
            # string. Do not use the public disassembler's guessed framing.
            row.update(kind="unqualified-restart-list", undecoded_size=end - at)
            rows.append(row)
            break
        elif opcode in (171, 201):
            pos = (pos + 3) & ~3
            checksum = unpack(data, "<I", pos, end)[0]; pos += 4
            n = 3 if opcode == 171 else 1
            row.update(kind="background-create" if opcode == 171 else "gap-poly-hit", checksum=checksum,
                       words=unpack(data, "<" + "H" * n, pos, end)); pos += n * 2
        else:
            row.update(kind="unknown", undecoded_size=end - at)
            rows.append(row)
            break
        row["size"] = pos - at
        rows.append(row)
        if opcode == 65535:
            break
    return rows


def trg_v2(data):
    if len(data) > MAX_SOURCE:
        raise ValueError("THPS2 TRG exceeds resource budget")
    magic, version, n = unpack(data, "<4sII", 0)
    if magic != b"_TRG" or version != 2 or not 0 < n <= MAX_RECORDS:
        raise ValueError("Only supplied THPS2 TRG v2 is supported")
    offsets = unpack(data, "<" + "I" * n, 12)
    table_end = 12 + n * 4
    if offsets[0] != table_end or any(a >= b for a, b in zip(offsets, offsets[1:])) or offsets[-1] != len(data) - 2:
        raise ValueError("Invalid THPS2 TRG node extents")
    if unpack(data, "<H", offsets[-1])[0] != 255:
        raise ValueError("Missing THPS2 TRG final terminator")
    result = []
    for index, start in enumerate(offsets):
        end = offsets[index + 1] if index + 1 < n else len(data)
        kind = unpack(data, "<H", start, end)[0]
        node = dict(index=index, offset=start, size=end - start, type=kind,
                    kind=NODE_NAMES.get(kind, "unknown"), sha256=hashlib.sha256(span(data, start, end - start)).hexdigest())
        pos = start + 2
        if kind in (3, 6, 8, 10, 11, 12, 14):
            nl = unpack(data, "<H", pos, end)[0]; pos += 2
            links = unpack(data, "<" + "H" * nl, pos, end); pos += nl * 2
            if any(link >= n for link in links):
                raise ValueError("THPS2 node references invalid link")
            node["links"] = links
            pos = (pos + 3) & ~3
            if kind in (3, 8, 10, 11):
                node["position_fixed12"] = unpack(data, "<3i", pos, end); pos += 12
                if kind in (8, 10, 11):
                    node["parameters"] = unpack(data, "<" + "H" * (3 if kind == 8 else 1), pos, end)
                    pos += 6 if kind == 8 else 2
                if kind == 8:
                    name = bytes(span(data, pos, end - pos)).split(b"\0", 1)[0]
                    if len(name) > 256 or pos + len(name) == end:
                        raise ValueError("Invalid THPS2 restart name")
                    node["name"] = name.decode("ascii")
                    pos = (pos + len(name) + 2) & ~1
            else:
                node["object_checksum"] = unpack(data, "<I", pos, end)[0]; pos += 4
        elif kind == 13:
            node["link"] = unpack(data, "<H", pos, end)[0]; pos = (pos + 5) & ~3
            node["position_fixed12"] = unpack(data, "<3i", pos, end); pos += 12
            node["parameters"] = unpack(data, "<2H", pos, end); pos += 4
        # The remaining extent is retained in the original TRG. Never scan
        # every 16-bit word as an opcode: arguments and strings are not code.
        node["undecoded_offset"] = pos
        node["undecoded_size"] = end - pos
        if pos > end:
            raise ValueError("THPS2 node fields exceed its extent")
        if kind in (4, 6, 8, 15):
            node["commands"] = command_list(data, pos, end)
        result.append(node)
    return dict(sha256=hashlib.sha256(data).hexdigest(), nodes=result,
                node_types={str(k): v for k, v in sorted(Counter(r["type"] for r in result).items())})


def prepare_level(original, output, stem, texture_stem, objects_stem=None, pc_directory=None):
    """Prepare one exact scene variant; all source/derived content stays local.

    PC high-resolution BMP overrides are recorded separately, never silently
    replacing the original paletted library. Source selection remains explicit.
    """
    from PIL import Image
    original, output = original.resolve(), output.resolve()
    if not re.fullmatch(r"[A-Z0-9_]+", stem) or (texture_stem is not None and not re.fullmatch(r"[A-Z0-9_]+", texture_stem)):
        raise ValueError("Invalid THPS2 source stem")
    output.mkdir(parents=True, exist_ok=True)
    layers = []
    textures = {}
    for selected, role in ((stem, "level"), (texture_stem, "texture-library"), (objects_stem, "objects")):
        if selected is None:
            continue
        if not re.fullmatch(r"[A-Z0-9_]+", selected):
            raise ValueError("Invalid THPS2 source stem")
        path = original / "data" / (selected + ".PSX")
        decoded = psx_v4(read_source(path))
        layers.append(dict(role=role, path=str(path.relative_to(original)), **decoded.summary()))
        for texture in decoded.textures:
            key = f"{decoded.texture_names[texture.name_index]:08X}"
            # Level and object texture IDs can legitimately share an image.
            # Keep per-source images separately and record exact resolution.
            filename = f"{selected}-{texture.name_index}-{key}.png"
            rgba = texture_rgba(decoded, texture)
            Image.frombytes("RGBA", (texture.width, texture.height), rgba).save(output / filename)
            textures.setdefault(key, []).append(dict(kind="psx-paletted", source_path=str(path.relative_to(original)),
                                                    source_sha256=decoded.source_sha256, path=filename,
                                                    width=texture.width, height=texture.height,
                                                    palette_name=f"{texture.palette_name:08X}", flags=texture.flags, name_index=texture.name_index,
                                                    sha256=hashlib.sha256((output / filename).read_bytes()).hexdigest()))
    if pc_directory:
        folder = original / "newtex" / pc_directory
        if not folder.is_dir():
            raise ValueError("Missing THPS2 PC texture directory")
        # Search authored level overrides first, then shared PC textures.
        for key, versions in textures.items():
            candidates = [folder / (key + ".BMP"), original / "newtex" / (key + ".BMP")]
            for path in candidates:
                if not path.is_file():
                    continue
                raw = read_source(path)
                with Image.open(path) as image:
                    if image.width * image.height > MAX_PIXELS or image.width > 2048 or image.height > 2048:
                        raise ValueError("THPS2 PC texture exceeds pixel budget")
                    target = f"PC-{key}.png"
                    image.convert("RGBA").save(output / target)
                    versions.append(dict(kind="pc-bmp", source_path=str(path.relative_to(original)),
                                         source_sha256=hashlib.sha256(raw).hexdigest(), path=target,
                                         width=image.width, height=image.height,
                                         sha256=hashlib.sha256((output / target).read_bytes()).hexdigest()))
                break
    trigger_path = original / "data" / (stem + "_T.TRG")
    trigger = trg_v2(read_source(trigger_path))
    (output / "nodes.json").write_text(json.dumps(trigger, indent=2) + "\n")
    receipt = dict(schema=1, title="thps2", scene_stem=stem, layers=layers,
                   trigger=dict(path=str(trigger_path.relative_to(original)), sha256=trigger["sha256"],
                                nodes=len(trigger["nodes"]), node_types=trigger["node_types"]),
                   textures=textures, axes="unaltered source coordinates; placement s7.24, vertices s3.12",
                   limits=dict(source_bytes=MAX_SOURCE, geometry_records=MAX_GEOMETRY, texture_pixels=MAX_PIXELS),
                   fidelity="Original scene foundation only; VM/physics/animation/modes/comparisons/M1 acceptance unfinished")
    (output / "level.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


# Names/source pairing are checked against actual TRG startup spools and
# hexadecimal PC texture IDs. This is content coverage, not playable coverage.
LEVELS = {
    "hangar": ("SKHAN", "SKHAN_L", "SKHAN_O", "Hangar"),
    "school-ii": ("SKSL2", "SKSL2_L", "SKSL2_O", "School2"),
    "new-york": ("SKNY", "SKNY_L", "SKNY_O", "NY"),
    "marseille": ("SKMAR", "SKMAR_L", "SKMAR_O", "Mar"),
    "venice": ("SKVEN", "SKVEN_L", "SKVEN_O", "Venice"),
    "skatestreet": ("SKSS", "SKSS_L", "SKSS_O", "SS"),
    "philadelphia": ("SKPH", "SKPH_L", "SKPH_O", "Philly"),
    "bullring": ("SKBUL", "SKBUL_L", "SKBUL_O", "Bullring"),
    "chopper-drop": ("SKB1", None, "SKB1_O", "Hawaii"),
    "skate-heaven": ("SKHVN", "SKHVN_L", "SKHVN_O", "Heaven"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--original", type=Path, default=Path("Library/Imported/thps2/original"))
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--all-levels", action="store_true")
    parser.add_argument("--scene", default="SKHAN")
    parser.add_argument("--texture-library", default="SKHAN_L")
    parser.add_argument("--objects", default="SKHAN_O")
    parser.add_argument("--pc-textures", default="Hangar")
    args = parser.parse_args()
    if args.all_levels:
        output = args.output or Path("Library/Imported/thps2/levels")
        rows = []
        for name, (stem, library, objects, folder) in LEVELS.items():
            receipt = prepare_level(args.original, output / name, stem, library, objects, folder)
            rows.append(dict(level=name, scene=stem, layers=receipt["layers"], trigger=receipt["trigger"],
                             textures=len(receipt["textures"])))
        print(json.dumps(rows, indent=2))
    else:
        output = args.output or Path("Library/Imported/thps2/levels/hangar")
        receipt = prepare_level(args.original, output, args.scene, args.texture_library, args.objects, args.pc_textures)
        print(json.dumps(dict(output=str(output), layers=receipt["layers"], trigger=receipt["trigger"],
                              textures=len(receipt["textures"])), indent=2))



if __name__ == "__main__":
    main()
