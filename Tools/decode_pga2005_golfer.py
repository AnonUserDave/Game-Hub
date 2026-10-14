#!/usr/bin/env python3
"""Decode the original PGA Tour 2005 golfer character for the native rewrite.

Reads the user's extracted install (``Golfer/chars/NNchar.xbx``,
``Golfer/CHARTEX/NNalltex.fxx`` and ``Golfer/chars/motions.tbf``) and writes a
skinned mesh, skeleton, PNG textures and animation clips to the ignored
``Library/Imported/pga2005/golfer`` directory. No game code is executed.
Standard library only; Pillow is imported lazily for ``--preview``.

Static evidence for every layout is recorded in docs/research/PGA2005-GOLFER.md
(Engine.dll addresses). Units and handedness are kept as stored:
model space is +Y up, the character faces +Z and its left side is +X.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from import_pga2005 import decode_dds, png_bytes  # noqa: E402

MESH_MAGIC = b"PGAGMSH1"
CLIP_MAGIC = b"PGAGCLP1"
VERTEX_BYTES = 40
MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_PAYLOAD_BYTES = 32 * 1024 * 1024
ANGLE = 2 * math.pi / 65536

# Xbox D3DFORMAT codes observed in the character texture directory.
XBOX_DXT = {0x0C: b"DXT1", 0x0E: b"DXT3", 0x0F: b"DXT5"}

# Tiger Woods signature clips (prefix "t") plus a generic putt stroke.
DEFAULT_CLIPS = ("tdlful50", "t7lful01", "twlful50", "tdlwag03", "tdlpre01", "gplptt01")
CLIP_ROLES = {
    "tdlful50": "Tiger driver full swing (address, backswing, downswing, follow-through)",
    "t7lful01": "Tiger 7-iron full swing",
    "twlful50": "Tiger wedge full swing",
    "tdlwag03": "Tiger driver waggle at address (idle/address loop candidate)",
    "tdlpre01": "Tiger driver pre-shot routine",
    "gplptt01": "Generic putting stroke (no Tiger-specific putt clip found)",
}


class FormatError(ValueError):
    pass


# --------------------------------------------------------------------------
# Small binary helpers
# --------------------------------------------------------------------------

def need(data: bytes, offset: int, size: int, what: str = "data"):
    if offset < 0 or size < 0 or offset + size > len(data):
        raise FormatError(f"Truncated or out-of-range {what} at 0x{offset:x}+{size}")


def unpack(fmt: str, data: bytes, offset: int, what: str = "field"):
    need(data, offset, struct.calcsize(fmt), what)
    return struct.unpack_from(fmt, data, offset)


def u32(data, offset, what="u32"):
    return unpack("<I", data, offset, what)[0]


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def cstring(raw: bytes) -> str:
    return raw.split(b"\0", 1)[0].decode("latin1")


# --------------------------------------------------------------------------
# Quaternion helpers.  Source quaternions are stored (x, y, z, w) but compose
# as the conjugate of the Hamilton convention; see the research note.
# --------------------------------------------------------------------------

def qmul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz)


def qconj(q):
    return (-q[0], -q[1], -q[2], q[3])


def qnormalize(q):
    n = math.sqrt(sum(c * c for c in q))
    if not math.isfinite(n) or n < 1e-12:
        return (0.0, 0.0, 0.0, 1.0)
    return tuple(c / n for c in q)


def qrotate(q, v):
    x, y, z, w = q
    t = qmul(qmul(q, (v[0], v[1], v[2], 0.0)), (-x, -y, -z, w))
    return t[:3]


def matrix_from(q, t):
    """Column-major 4x4 matrix for rotation q (Hamilton) then translation t."""
    x, y, z, w = q
    return [1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0.0,
            2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0.0,
            2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0.0,
            t[0], t[1], t[2], 1.0]


def inverse_rigid(q, t):
    qi = qconj(q)
    ti = qrotate(qi, t)
    return qi, (-ti[0], -ti[1], -ti[2])


# --------------------------------------------------------------------------
# SHOC container (.xbx) and Rdat compression
# --------------------------------------------------------------------------

def rdat_decompress(src: bytes, size: int) -> tuple[bytes, int]:
    """Engine.dll 0x1025d860: big-endian 16-bit command LZ with RLE and reversed copies."""
    if not 0 <= size <= MAX_PAYLOAD_BYTES:
        raise FormatError("Implausible Rdat size")
    out = bytearray()
    i = 0
    while len(out) < size:
        need(src, i, 2, "Rdat command")
        word = (src[i] << 8) | src[i + 1]
        i += 2
        if word & 0x8800 == 0x8800:
            count = (word >> 12) & 7
            if count == 0:
                literal = word & 0x7FF
                need(src, i, literal, "Rdat literal")
                out += src[i:i + literal]
                i += literal
            else:
                distance = ((word >> 5) & 0x38) | count
                length = (word & 0xFF) + 3
                if distance > len(out):
                    raise FormatError("Rdat fill reads before output start")
                out += bytes((out[-distance],)) * length
        else:
            length = (word >> 12) & 7
            distance = word & 0xFFF
            if length == 7:
                need(src, i, 1, "Rdat length")
                length += src[i]
                i += 1
            length += 3
            start = len(out)
            if word & 0x8000:
                base = start - distance + 2
                if base - length + 1 < 0 or base >= start:
                    raise FormatError("Rdat reverse copy out of range")
                for k in range(length):
                    out.append(out[base - k])
            else:
                source = start - distance
                if source < 0 or distance == 0:
                    raise FormatError("Rdat copy out of range")
                if distance < 16 and length > distance:
                    # Engine copies 8/16-byte groups; overlapping short copies never
                    # occur in observed data, so the bytewise result is identical.
                    raise FormatError("Rdat overlapping short copy is unsupported")
                for k in range(length):
                    out.append(out[source + k])
    if len(out) != size:
        raise FormatError("Rdat output overran declared size")
    return bytes(out), i


def read_container(data: bytes) -> list[dict]:
    """CTRL/SYNC/FILL/SHOC(SHDR|SDAT|Rdat) walk (Engine.dll 0x1025d3e0)."""
    if len(data) > MAX_FILE_BYTES:
        raise FormatError("Container too large")
    if data[:4] != b"LRTC":
        raise FormatError("Missing CTRL chunk")
    resources, current, offset = [], None, 0
    while offset + 8 <= len(data):
        tag = data[offset:offset + 4][::-1]
        size = u32(data, offset + 4)
        if tag == b"CTRL":
            offset += 0x10
            continue
        if tag == b"SYNC":
            offset += 8
            continue
        if tag == b"FILL":
            if size < 8:
                raise FormatError("Bad FILL size")
            offset += size
            continue
        if tag != b"SHOC" or size < 0x14 or offset + size > len(data):
            raise FormatError(f"Bad chunk at 0x{offset:x}")
        sub = data[offset + 16:offset + 20][::-1]
        if sub == b"SHDR":
            kind, rtag, a, rsize, c = unpack("<I4sIII", data, offset + 20, "SHDR")
            current = {"kind": kind, "tag": rtag[::-1].decode("latin1"), "id": a,
                       "size": rsize, "offset": offset, "parts": []}
            resources.append(current)
        elif sub in (b"SDAT", b"Rdat"):
            if current is None:
                raise FormatError("Data chunk before SHDR")
            current["parts"].append((offset, size, sub.decode()))
        else:
            raise FormatError(f"Unknown SHOC subtype {sub!r}")
        offset += size
    return resources


def resource_payload(data: bytes, resource: dict) -> bytes:
    out = bytearray()
    for offset, size, sub in resource["parts"]:
        if sub == "Rdat":
            usize = u32(data, offset + 0x40, "Rdat size")
            chunk, _ = rdat_decompress(data[offset + 0x44:offset + size], usize)
            out += chunk
        elif resource["kind"] == 1:
            out += data[offset + 0x40:offset + size]
    if resource["kind"] == 1 and len(out) != resource["size"]:
        raise FormatError(f"{resource['tag']!r} payload size mismatch")
    return bytes(out)


def export_path(data: bytes) -> str | None:
    match = re.search(rb"[A-Za-z_]*\\EXPORTED\\[A-Za-z0-9_]+\.CHX", data[:0x400])
    return match.group().decode("latin1") if match else None


# --------------------------------------------------------------------------
# CHR resource (Engine.dll 0x102487c0)
# --------------------------------------------------------------------------

def parse_chr(chr_data: bytes) -> dict:
    skin_size = u32(chr_data, 0x30, "skin size")
    skin_base = 0x40
    need(chr_data, skin_base, skin_size, "skin block")
    p = skin_base + skin_size
    attachment_count = u32(chr_data, p, "attachment count")
    p += 16 + attachment_count * 48
    skeleton_size = u32(chr_data, p, "skeleton size")
    p += 16
    need(chr_data, p, skeleton_size, "skeleton block")
    skeleton = parse_skeleton(chr_data[p:p + skeleton_size])
    p += skeleton_size
    slider_count, _ = unpack("<II", chr_data, p, "slider header")
    if slider_count:
        raise FormatError("Characters with texture sliders are not supported")
    p += 16
    list_start = p
    for _ in range(2):
        count = u32(chr_data, p)
        if count:
            raise FormatError("Characters with slider rule lists are not supported")
        p += 4
    p += (-(p - list_start)) % 8
    tex_size, tex_extra = unpack("<II", chr_data, p, "texture directory header")
    if tex_extra:
        raise FormatError("Unexpected second texture directory block")
    textures = parse_texture_directory(chr_data, p + 0x10, tex_size)
    skin = parse_skin(chr_data, skin_base, skin_size)
    model = parse_model(chr_data, skin["model_offset"], skin_base + skin_size)
    if skin["bone_count"] != skeleton["count"]:
        raise FormatError("Skin and skeleton bone counts differ")
    return {"skin": skin, "model": model, "skeleton": skeleton, "textures": textures,
            "attachment_count": attachment_count}


def parse_skeleton(blob: bytes) -> dict:
    count = u32(blob, 0, "bone count")
    if not 0 < count <= 255:
        raise FormatError("Bad bone count")
    bones = []
    for i in range(count):
        o = 12 + 33 * i
        need(blob, o, 33, "bone record")
        name = cstring(blob[o:o + 16])
        parent = struct.unpack_from("<b", blob, o + 16)[0]
        offset = struct.unpack_from("<3f", blob, o + 17)
        if parent >= i or parent < -1:
            raise FormatError("Bone parent is not earlier in the list")
        bones.append({"name": name, "parent": parent, "offset": offset})
    return {"count": count, "bones": bones}


def parse_skin(data: bytes, base: int, size: int) -> dict:
    """Skin block version 4 (Engine.dll 0x102570d0 / relocation 0x102573c0)."""
    header = unpack("<24i", data, base, "skin header")
    if header[0] != 4:
        raise FormatError(f"Unsupported skin version {header[0]}")
    bone_count, bind_offset = header[5], header[0xD]
    blend_count, blend_offset, model_offset = header[0x14], header[0x15], header[0x12]
    for off, length in ((bind_offset, bone_count * 32), (blend_offset, blend_count * 20)):
        if off <= 0 or off + length > size:
            raise FormatError("Skin table out of range")
    bind = []
    for i in range(bone_count):
        q = unpack("<4f", data, base + bind_offset + 32 * i)
        t = unpack("<3f", data, base + bind_offset + 32 * i + 16)
        bind.append((q, t))
    blends = []
    for i in range(blend_count):
        o = base + blend_offset + 20 * i
        count, b0, b1, b2 = unpack("<4H", data, o)
        weights = unpack("<3f", data, o + 8)
        if not 1 <= count <= 3:
            raise FormatError("Bad blend influence count")
        influences = [(b, w) for b, w in zip((b0, b1, b2), weights)][:count]
        for b, w in influences:
            if b >= bone_count or not math.isfinite(w):
                raise FormatError("Bad blend influence")
        blends.append(influences)
    if not 0 < model_offset < size:
        raise FormatError("Model offset out of range")
    return {"bone_count": bone_count, "bind": bind, "blends": blends,
            "model_offset": base + model_offset}


def parse_model(data: bytes, base: int, limit: int) -> dict:
    """Model block version 8 (relocation Engine.dll 0x102683c0)."""
    h = unpack("<52i", data, base, "model header")
    if h[0] != 8:
        raise FormatError(f"Unsupported model version {h[0]}")
    model_size = h[2]
    if base + model_size > limit:
        raise FormatError("Model exceeds skin block")
    model = data[base:base + model_size]

    def table(count, offset, stride, what):
        if count < 0 or offset < 0 or offset + count * stride > model_size:
            raise FormatError(f"{what} out of range")
        return offset

    slots = []
    table(h[4], h[5], 0x38, "texture slots")
    for i in range(h[4]):
        o = h[5] + 0x38 * i
        slots.append({"name": cstring(model[o:o + 16]),
                      "uv_transform": list(struct.unpack_from("<4f", model, o + 40))})
    table(h[7], h[8], 4, "material layers")
    layers = list(struct.unpack_from(f"<{h[7]}i", model, h[8]))
    buffers = []
    table(h[0xB], h[0xD], 16, "buffers")
    for i in range(h[0xB]):
        off, size, count, kind = struct.unpack_from("<4I", model, h[0xD] + 16 * i)
        if off and off + size > model_size:
            raise FormatError("Buffer out of range")
        buffers.append({"offset": off, "size": size, "count": count, "type": kind})
    table(h[0xE], h[0xF], 4, "buffer lists")
    lists = list(struct.unpack_from(f"<{h[0xE]}i", model, h[0xF]))
    table(h[0x10], h[0x11], 48, "render nodes")
    nodes = [list(struct.unpack_from("<12i", model, h[0x11] + 48 * i)) for i in range(h[0x10])]
    table(h[0x2A], h[0x2B], 2, "batch table")
    batches = list(struct.unpack_from(f"<{h[0x2A]}H", model, h[0x2B]))
    sets = {}
    table(h[0x14], h[0x15], 32, "visibility sets")
    table(h[0x16], h[0x17], 8, "visibility ranges")
    table(h[0x1A], h[0x1B], 4, "visibility node list")
    set_nodes = list(struct.unpack_from(f"<{h[0x1A]}i", model, h[0x1B]))
    for i in range(h[0x14]):
        o = h[0x15] + 32 * i
        name = cstring(model[o:o + 16])
        index = struct.unpack_from("<i", model, o + 20)[0]
        if 0 <= index < h[0x16]:
            count, start = struct.unpack_from("<2i", model, h[0x17] + 8 * index)
            sets[name] = set_nodes[start:start + count]
    variants = []
    table(h[0x20], h[0x21], 16, "texture variant names")
    variant_names = [cstring(model[h[0x21] + 16 * i:h[0x21] + 16 * i + 16]) for i in range(h[0x20])]
    table(h[0x1E], h[0x1F], 32, "texture variants")
    for i in range(h[0x1E]):
        o = h[0x1F] + 32 * i
        variants.append(cstring(model[o:o + 16]))
    scale = struct.unpack_from("<f", model, 0xB0)[0]
    if not (math.isfinite(scale) and 0 < scale < 1000):
        raise FormatError("Bad model position scale")
    return {"blob": model, "slots": slots, "layers": layers, "buffers": buffers,
            "lists": lists, "nodes": nodes, "batches": batches, "sets": sets,
            "variant_sets": variants, "variant_textures": variant_names,
            "position_scale": scale}


def parse_texture_directory(data: bytes, start: int, size: int) -> dict:
    if size % 88:
        raise FormatError("Texture directory is not a multiple of 88-byte records")
    need(data, start, size, "texture directory")
    textures = {}
    for i in range(size // 88):
        o = start + 88 * i
        name = cstring(data[o:o + 16])
        mips = []
        for k in range(4):
            off, size16, _, _, _ = struct.unpack_from("<IHHHH", data, o + 16 + 12 * k)
            if size16:
                mips.append((off, size16 * 16))
        width, height, _, index = struct.unpack_from("<4H", data, o + 64)
        fmt, mip_count = data[o + 72], data[o + 73]
        if name and name not in textures:
            textures[name] = {"index": index, "width": width, "height": height,
                              "format": fmt, "mip_count": mip_count, "mips": mips}
    return textures


# --------------------------------------------------------------------------
# Mesh assembly
# --------------------------------------------------------------------------

NODE_SKINNED = (1, 2)
NODE_MORPH_BASE = (5, 6)


def node_buffer_lists(model):
    starts = sorted({n[0] for n in model["nodes"]} | {len(model["lists"])})
    result = []
    for node in model["nodes"]:
        end = starts[starts.index(node[0]) + 1]
        result.append([b for b in model["lists"][node[0]:end] if b >= 0])
    return result


def decode_node(model, skin, node, buffer_ids):
    blob, buffers = model["blob"], model["buffers"]
    kind = node[3]
    if kind not in NODE_SKINNED + NODE_MORPH_BASE:
        return None
    roles = {}
    for b in buffer_ids:
        t = buffers[b]["type"]
        if t == 0x1808:
            roles["palette"] = b
        elif t & 0xFFFF == 0x0002:
            roles["index"] = b
        elif t & 0x11 == 0x11 and not t & 0x1000:
            roles["vertex"] = b
        elif t == 0x41:
            roles["uv"] = b
    for role in ("palette", "vertex", "index"):
        if role not in roles:
            raise FormatError(f"Render node lacks {role} buffer")
    vb, ib, pb = (buffers[roles[r]] for r in ("vertex", "index", "palette"))
    vtype = vb["type"]
    stride = (8 if vtype & 0x10 else 0) + (6 if vtype & 0x20 else 0) + (4 if vtype & 0x40 else 0)
    header = 0x40
    need(blob, vb["offset"] + header, vb["count"] * stride, "vertex stream")
    need(blob, ib["offset"] + header, ib["count"] * 2, "index stream")
    need(blob, pb["offset"], pb["count"] * 4, "matrix palette")
    uv_stream = None
    if not vtype & 0x40:
        if "uv" not in roles:
            raise FormatError("Vertex stream has no UV source")
        uvb = buffers[roles["uv"]]
        if uvb["count"] != vb["count"]:
            raise FormatError("UV stream count mismatch")
        need(blob, uvb["offset"] + header, uvb["count"] * 4, "uv stream")
        uv_stream = uvb["offset"] + header
    record = 5 if kind in NODE_MORPH_BASE else 4
    cursor = node[11]
    registers = {}
    pal_cursor = vert_cursor = idx_cursor = 0
    vertex_matrix = [None] * vb["count"]
    batches = []
    for _ in range(node[2]):
        if cursor + record > len(model["batches"]):
            raise FormatError("Batch table out of range")
        entry = model["batches"][cursor:cursor + record]
        cursor += record
        npal, nvert, nidx = entry[1], entry[2], entry[-1]
        for k in range(npal):
            word = struct.unpack_from("<I", blob, pb["offset"] + 4 * (pal_cursor + k))[0]
            register, source = (word >> 16) - 0x500, word & 0xFFFF
            if source & 3 or source // 4 >= len(skin["blends"]):
                raise FormatError("Palette references an unknown blend matrix")
            registers[register] = source // 4
        pal_cursor += npal
        for v in range(vert_cursor, vert_cursor + nvert):
            w = struct.unpack_from("<h", blob, vb["offset"] + header + stride * v + 6)[0]
            if w not in registers:
                raise FormatError("Vertex references an unloaded palette register")
            vertex_matrix[v] = registers[w]
        batches.append((vert_cursor, nvert, idx_cursor, nidx))
        vert_cursor += nvert
        idx_cursor += nidx
    if (pal_cursor, vert_cursor, idx_cursor) != (pb["count"], vb["count"], ib["count"]):
        raise FormatError("Batch totals do not match buffer counts")
    scale = model["position_scale"] / 32768.0
    vertices = []
    for v in range(vb["count"]):
        o = vb["offset"] + header + stride * v
        x, y, z, _ = struct.unpack_from("<4h", blob, o)
        nx, ny, nz = struct.unpack_from("<3h", blob, o + 8) if vtype & 0x20 else (0, 16384, 0)
        if vtype & 0x40:
            u, t = struct.unpack_from("<2h", blob, o + 14)
        else:
            u, t = struct.unpack_from("<2h", blob, uv_stream + 4 * v)
        n = math.sqrt(nx * nx + ny * ny + nz * nz) or 1.0
        vertices.append(((x * scale, y * scale, z * scale), (nx / n, ny / n, nz / n),
                         (u / 4096.0, t / 4096.0), vertex_matrix[v]))
    indices = struct.unpack_from(f"<{ib['count']}H", blob, ib["offset"] + header)
    triangles = []
    for first_v, nvert, first_i, nidx in batches:
        strip = indices[first_i:first_i + nidx]
        for k in range(len(strip) - 2):
            a, b, c = strip[k], strip[k + 1], strip[k + 2]
            if a == b or b == c or a == c:
                continue
            for i in (a, b, c):
                if not first_v <= i < first_v + nvert:
                    raise FormatError("Strip index outside its batch")
            triangles.append((a, b, c) if k % 2 == 0 else (b, a, c))
    return {"vertices": vertices, "triangles": triangles, "batches": len(batches),
            "vertex_type": vtype}


def build_mesh(character: dict) -> dict:
    model, skin = character["model"], character["skin"]
    lists = node_buffer_lists(model)
    node_sets = {}
    for name, members in model["sets"].items():
        for n in members:
            node_sets.setdefault(n, []).append(name)
    vertices, triangles, submeshes = [], [], []
    kept = flipped = 0
    for index, node in enumerate(model["nodes"]):
        decoded = decode_node(model, skin, node, lists[index])
        if decoded is None:
            continue
        base = len(vertices)
        first_index = len(triangles) * 3
        # The strips carry no consistent winding (the original draws the golfer with
        # D3DRS_CULLMODE = NONE, BodyC::SetupGolferRenderStates 0x1019a579), so each
        # triangle is oriented counter-clockwise about its stored vertex normals.
        for a, b, c in decoded["triangles"]:
            pa, pb_, pc = (decoded["vertices"][i][0] for i in (a, b, c))
            e1 = [pb_[k] - pa[k] for k in range(3)]
            e2 = [pc[k] - pa[k] for k in range(3)]
            face = (e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2],
                    e1[0] * e2[1] - e1[1] * e2[0])
            normal = [sum(decoded["vertices"][i][1][k] for i in (a, b, c)) for k in range(3)]
            if sum(f * n for f, n in zip(face, normal)) >= 0:
                kept += 1
                triangles.append((base + a, base + b, base + c))
            else:
                flipped += 1
                triangles.append((base + a, base + c, base + b))
        for vertex in decoded["vertices"]:
            influences = skin["blends"][vertex[3]]
            vertices.append((vertex[0], vertex[1], vertex[2], influences))
        material = node_material(model, node)
        submeshes.append({
            "node": index, "render_type": node[3], "sets": sorted(node_sets.get(index, [])),
            "first_index": first_index, "index_count": len(decoded["triangles"]) * 3,
            "first_vertex": base, "vertex_count": len(decoded["vertices"]),
            "batches": decoded["batches"], "source_vertex_type": decoded["vertex_type"],
            **material})
    return {"vertices": vertices, "triangles": triangles, "submeshes": submeshes,
            "strip_parity_agreement": kept / max(1, kept + flipped), "reoriented": flipped}


def node_material(model, node):
    layer_count = 2 if node[3] in (2, 6) else 1
    result = {}
    for layer in range(layer_count):
        entry = node[1] + layer
        if not 0 <= entry < len(model["layers"]):
            raise FormatError("Material layer index out of range")
        slot = model["slots"][model["layers"][entry]]
        info = {"texture": slot["name"] or None, "uv_transform": slot["uv_transform"]}
        result["base" if layer == 0 else "decal"] = info
    result.setdefault("decal", None)
    return result


def write_mesh(mesh: dict) -> bytes:
    vertices, triangles = mesh["vertices"], mesh["triangles"]
    wide = len(vertices) > 65535
    if not vertices:
        raise FormatError("No vertices decoded")
    lo = [min(v[0][k] for v in vertices) for k in range(3)]
    hi = [max(v[0][k] for v in vertices) for k in range(3)]
    out = bytearray(MESH_MAGIC)
    out += struct.pack("<6I", 1, len(vertices), len(triangles) * 3, len(mesh["submeshes"]),
                       1 + max(b for v in vertices for b, _ in v[3]), 1 if wide else 0)
    out += struct.pack("<6f", *lo, *hi)
    for position, normal, uv, influences in vertices:
        bones = [b for b, _ in influences] + [0] * (4 - len(influences))
        total = sum(max(0.0, w) for _, w in influences) or 1.0
        weights = [round(255 * max(0.0, w) / total) for _, w in influences]
        weights[weights.index(max(weights))] += 255 - sum(weights)
        weights += [0] * (4 - len(weights))
        out += struct.pack("<8f4B4B", *position, *normal, *uv, *bones, *weights)
    fmt = "<3I" if wide else "<3H"
    for tri in triangles:
        out += struct.pack(fmt, *tri)
    if len(out) % 4:
        out += b"\0" * (4 - len(out) % 4)
    for sub in mesh["submeshes"]:
        out += struct.pack("<4I", sub["first_index"], sub["index_count"],
                           sub["first_vertex"], sub["vertex_count"])
    return bytes(out)


def read_mesh(data: bytes) -> dict:
    """Reader for the documented PGAGMSH1 layout (used by tests and previews)."""
    if data[:8] != MESH_MAGIC:
        raise FormatError("Not a PGAGMSH1 mesh")
    version, nv, ni, ns, nbones, flags = struct.unpack_from("<6I", data, 8)
    if version != 1:
        raise FormatError("Unsupported mesh version")
    p = 56
    need(data, p, nv * VERTEX_BYTES, "vertices")
    vertices = []
    for i in range(nv):
        f = struct.unpack_from("<8f4B4B", data, p + VERTEX_BYTES * i)
        vertices.append((f[0:3], f[3:6], f[6:8], f[8:12], f[12:16]))
    p += nv * VERTEX_BYTES
    size = 4 if flags & 1 else 2
    need(data, p, ni * size, "indices")
    indices = struct.unpack_from(f"<{ni}{'I' if size == 4 else 'H'}", data, p)
    p += ni * size
    p += (-p) % 4
    need(data, p, ns * 16, "submeshes")
    submeshes = [struct.unpack_from("<4I", data, p + 16 * i) for i in range(ns)]
    return {"vertices": vertices, "indices": indices, "submeshes": submeshes,
            "bone_count": nbones, "bounds": struct.unpack_from("<6f", data, 32)}


# --------------------------------------------------------------------------
# Skeleton output
# --------------------------------------------------------------------------

def build_skeleton(character: dict) -> dict:
    """Bind pose in Hamilton convention: world = parent ⊗ local."""
    bones = character["skeleton"]["bones"]
    bind = character["skin"]["bind"]
    result, world = [], []
    for i, bone in enumerate(bones):
        q = qnormalize(qconj(bind[i][0]))
        t = tuple(bind[i][1])
        if bone["parent"] < 0:
            wq, wt = q, t
        else:
            pq, pt = world[bone["parent"]]
            rt = qrotate(pq, t)
            wq, wt = qnormalize(qmul(pq, q)), tuple(pt[k] + rt[k] for k in range(3))
        world.append((wq, wt))
        iq, it = inverse_rigid(wq, wt)
        result.append({"index": i, "name": bone["name"], "parent": bone["parent"],
                       "bind_local": {"rotation": rounded(q), "translation": rounded(t)},
                       "bind_world": {"rotation": rounded(wq), "translation": rounded(wt)},
                       "inverse_bind_matrix": rounded(matrix_from(iq, it))})
    # Engine.dll 0x10254c90 appends IG_Gball1 (parent 0, identity) for animation channel 101.
    result.append({"index": len(result), "name": "IG_Gball1", "parent": 0, "synthetic": True,
                   "bind_local": {"rotation": [0, 0, 0, 1], "translation": [0, 0, 0]},
                   "bind_world": {"rotation": [0, 0, 0, 1], "translation": [0, 0, 0]},
                   "inverse_bind_matrix": rounded(matrix_from((0, 0, 0, 1), (0, 0, 0)))})
    return {"bones": result, "world": world}


def rounded(values, digits=6):
    return [round(float(v), digits) for v in values]


# --------------------------------------------------------------------------
# Textures (.fxx)
# --------------------------------------------------------------------------

def dds_from_dxt(width: int, height: int, fourcc: bytes, blocks: bytes) -> bytes:
    header = bytearray(128)
    header[0:4] = b"DDS "
    struct.pack_into("<IIII", header, 4, 124, 0x81007, height, width)
    struct.pack_into("<II4s", header, 76, 32, 4, fourcc)
    struct.pack_into("<I", header, 108, 0x1000)
    return bytes(header) + blocks


def decode_texture(fxx: bytes, entry: dict) -> tuple[int, int, bytes]:
    fourcc = XBOX_DXT.get(entry["format"])
    if fourcc is None:
        raise FormatError(f"Unsupported Xbox texture format 0x{entry['format']:02x}")
    width, height = entry["width"], entry["height"]
    block = 8 if fourcc == b"DXT1" else 16
    expected = max(1, width // 4) * max(1, height // 4) * block
    offset, size = entry["mips"][0]
    if size != expected:
        raise FormatError("Texture mip size disagrees with dimensions")
    need(fxx, offset, size, "texture data")
    return decode_dds(dds_from_dxt(width, height, fourcc, fxx[offset:offset + size]))


# --------------------------------------------------------------------------
# Animation (motions.tbf / .ska, Engine.dll 0x10254000, 0x102545f0)
# --------------------------------------------------------------------------

def read_tbf(data: bytes) -> dict:
    count = u32(data, 0, "tbf count")
    if not 0 < count < 100000:
        raise FormatError("Bad tbf entry count")
    entries, p = {}, 4
    for _ in range(count):
        length = u32(data, p)
        if not 0 < length < 256:
            raise FormatError("Bad tbf name length")
        name = data[p + 4:p + 4 + length].decode("latin1")
        offset, size = unpack("<II", data, p + 4 + length)
        need(data, offset, size, "tbf entry")
        entries[name] = (offset, size)
        p += 12 + length
    return entries


def _axis(axis: int, raw: float):
    h = raw * ANGLE / 2
    q = [0.0, 0.0, 0.0, math.cos(h)]
    q[axis] = math.sin(h)
    return tuple(q)


def _euler(z, y, x):
    return qmul(qmul(_axis(0, x), _axis(1, y)), _axis(2, z))


def _bits2(bitfield: bytes, i: int) -> int:
    def bit(n):
        return (bitfield[n >> 3] >> (n & 7)) & 1
    return bit(i) | (bit(i + 1) << 1)


AXIS_FOR_MODE = {1: 2, 2: 0, 3: 1}       # 1=Z, 2=X, 3=Y
BASE_FOR_MODE = {1: 0, 2: 2, 3: 1}       # stream-A base component per mode


def parse_ska(blob: bytes) -> dict:
    flags = u32(blob, 0)
    frame_count = unpack("<h", blob, 0xC)[0]
    seconds_per_frame = unpack("<f", blob, 0x10)[0]
    channels = u32(blob, 0x1C)
    if not (0 < frame_count < 100000 and 0 < channels <= 256 and 0 < seconds_per_frame < 1):
        raise FormatError("Bad SKA header")
    event_count = unpack("<h", blob, 0x48)[0]
    p = 0x100
    events = [unpack("<If", blob, p + 16 * i) for i in range(event_count)]
    p += 16 * event_count
    if flags & 2:
        p += 0x1F0
    descriptors = p
    if u32(blob, 0x2C) != channels * 16:
        raise FormatError("SKA descriptor table size mismatch")
    p += channels * 16
    bits = p + u32(blob, 0x54) + u32(blob, 0x64)
    p += (-p) % 16
    layout = {}
    for name, size_at in (("constants", 0x40), ("a_base", 0x3C)):
        layout[name] = p
        p += u32(blob, size_at)
    layout["b_frames"] = p
    p += u32(blob, 0x38)
    layout["a_deltas"] = p
    p += u32(blob, 0x4)
    translation_frames_size, translation_params_size = u32(blob, 0x4C), u32(blob, 0x50)
    layout["t_params"] = p
    layout["t_frames"] = p + translation_params_size
    if translation_frames_size:
        p += translation_frames_size + translation_params_size
    if p > bits - u32(blob, 0x64):
        raise FormatError("SKA streams overrun the declared data size")
    words = (channels * 2 + 31) >> 5
    layout["a_bits"], layout["b_bits"] = bits, bits + words * 4
    if bits + words * 8 != len(blob):
        raise FormatError(f"SKA layout ends at 0x{bits + words * 8:x}, blob is 0x{len(blob):x}")
    return {"blob": blob, "flags": flags, "frame_count": frame_count,
            "seconds_per_frame": seconds_per_frame, "channels": channels,
            "events": [(int(i), float(t)) for i, t in events], "descriptors": descriptors,
            "const_count": u32(blob, 0x60), "a_count": u32(blob, 0x58), "b_count": u32(blob, 0x5C),
            "a_stride": unpack("<h", blob, 0x92)[0], "b_stride": unpack("<h", blob, 0x90)[0],
            "club_bone": cstring(blob[0xA0:0xB0]), "name": cstring(blob[0xB0:0xC0]), **layout}


def sample_ska(clip: dict, frame: int) -> list:
    """Return per channel (flags, source quaternion or None, translation or None)."""
    blob = clip["blob"]
    a_bits = blob[clip["a_bits"]:clip["a_bits"] + clip["b_bits"] - clip["a_bits"]]
    b_bits = blob[clip["b_bits"]:]
    consts = [_euler(*unpack("<3H", blob, clip["constants"] + 6 * i))
              for i in range(clip["const_count"])]
    stream_a, p = [], clip["a_deltas"] + frame * clip["a_stride"]
    for i in range(clip["a_count"]):
        base = unpack("<3H", blob, clip["a_base"] + 6 * i)
        mode = _bits2(a_bits, 2 * i)
        if mode == 0:
            d = blob[p:p + 3]
            p += 3
            stream_a.append(_euler(base[0] - 16 * d[0], base[1] - 16 * d[1], base[2] - 16 * d[2]))
        else:
            stream_a.append(_axis(AXIS_FOR_MODE[mode], base[BASE_FOR_MODE[mode]] - 16 * blob[p]))
            p += 1
    stream_b, p = [], clip["b_frames"] + frame * clip["b_stride"] * 2
    for i in range(clip["b_count"]):
        mode = _bits2(b_bits, 2 * i)
        if mode == 0:
            stream_b.append(_euler(*unpack("<3H", blob, p)))
            p += 6
        else:
            stream_b.append(_axis(AXIS_FOR_MODE[mode], unpack("<H", blob, p)[0]))
            p += 2
    result, ci, ai, bi, ti = [], 0, 0, 0, 0
    for ch in range(clip["channels"]):
        flags = u32(blob, clip["descriptors"] + 16 * ch)
        q = t = None
        if flags & 4:
            q, ci = consts[ci], ci + 1
        elif flags & 8:
            if flags & 0x20:
                q, ai = stream_a[ai], ai + 1
            else:
                q, bi = stream_b[bi], bi + 1
        if flags & 0x10:
            lo_hi = unpack("<6f", blob, clip["t_params"] + 24 * ti)
            raw = unpack("<3H", blob, clip["t_frames"] + (ti * clip["frame_count"] + frame) * 6)
            t = tuple(raw[k] * (1 / 65535) * (lo_hi[2 * k + 1] - lo_hi[2 * k]) + lo_hi[2 * k]
                      for k in range(3))
            ti += 1
        result.append((flags, q, t))
    return result


def clip_poses(clip: dict, skeleton: dict) -> tuple[list, list]:
    """Fully resolved local transforms (Hamilton) for every frame, plus channel flags."""
    bones = skeleton["bones"]
    if clip["channels"] > len(bones):
        raise FormatError("Clip has more channels than the skeleton (+IG_Gball1)")
    frames, channel_flags = [], None
    for f in range(clip["frame_count"]):
        sample = sample_ska(clip, f)
        sample += [(0, None, None)] * (len(bones) - len(sample))   # e.g. grass.ska: 101 channels
        if channel_flags is None:
            channel_flags = [(1 if fl & 8 else 0) | (2 if fl & 4 else 0) | (4 if fl & 0x10 else 0)
                             for fl, _, _ in sample]
        pose = []
        for i, (_, q, t) in enumerate(sample):
            bind = bones[i]["bind_local"]
            rq = qnormalize(qconj(q)) if q is not None else tuple(bind["rotation"])
            rt = tuple(t) if t is not None else tuple(bind["translation"])
            pose.append((rq, rt))
        frames.append(pose)
    return frames, channel_flags


def write_clip(clip: dict, frames: list, channel_flags: list) -> bytes:
    out = bytearray(CLIP_MAGIC)
    out += struct.pack("<3IfII", 1, len(channel_flags), len(frames), 1 / clip["seconds_per_frame"],
                       len(clip["events"]), 3)
    for event_id, seconds in clip["events"]:
        out += struct.pack("<If", event_id, seconds)
    out += bytes(channel_flags)
    out += b"\0" * ((-len(out)) % 4)
    for pose in frames:
        for q, t in pose:
            out += struct.pack("<7f", *q, *t)
    return bytes(out)


def read_clip(data: bytes) -> dict:
    if data[:8] != CLIP_MAGIC:
        raise FormatError("Not a PGAGCLP1 clip")
    version, bones, frames, fps, events, flags = struct.unpack_from("<3IfII", data, 8)
    p = 32
    event_list = [struct.unpack_from("<If", data, p + 8 * i) for i in range(events)]
    p += 8 * events
    channel_flags = list(data[p:p + bones])
    p += bones + (-(p + bones)) % 4
    need(data, p, frames * bones * 28, "clip frames")
    poses = []
    for f in range(frames):
        pose = []
        for b in range(bones):
            v = struct.unpack_from("<7f", data, p + 28 * (f * bones + b))
            pose.append((v[:4], v[4:]))
        poses.append(pose)
    return {"version": version, "fps": fps, "events": event_list, "flags": flags,
            "channel_flags": channel_flags, "poses": poses}


def swing_phases(clip: dict) -> dict | None:
    """Inferred from SKA events: 0 takeaway, 1 top of backswing, 2 impact (seconds)."""
    events = {i: t for i, t in clip["events"] if t > 0}
    spf, last = clip["seconds_per_frame"], clip["frame_count"] - 1
    frame = lambda s: max(0, min(last, round(s / spf)))  # noqa: E731
    if {0, 1, 2} <= set(events):
        e0, e1, e2 = frame(events[0]), frame(events[1]), frame(events[2])
        return {"address": [0, e0], "backswing": [e0, e1], "downswing": [e1, e2],
                "follow_through": [e2, last]}
    if 2 in events:
        e2 = frame(events[2])
        return {"stroke": [0, e2], "follow_through": [e2, last]}
    return None


def world_pose(skeleton: dict, pose: list) -> list:
    world = []
    for i, bone in enumerate(skeleton["bones"]):
        q, t = pose[i]
        parent = bone["parent"]
        if parent < 0:
            world.append((q, t))
        else:
            pq, pt = world[parent]
            rt = qrotate(pq, t)
            world.append((qnormalize(qmul(pq, q)), tuple(pt[k] + rt[k] for k in range(3))))
    return world


def skin_positions(skeleton: dict, mesh: dict, pose: list | None) -> list:
    if pose is None:
        return [v[0] for v in mesh["vertices"]]
    world = world_pose(skeleton, pose)
    bind = skeleton["world"]
    matrices = []
    for i in range(len(bind)):
        bq, bt = inverse_rigid(*bind[i])
        q = qmul(world[i][0], bq)
        t = qrotate(world[i][0], bt)
        matrices.append((q, tuple(t[k] + world[i][1][k] for k in range(3))))
    result = []
    for position, _, _, influences in mesh["vertices"]:
        acc = [0.0, 0.0, 0.0]
        for bone, weight in influences:
            q, t = matrices[bone]
            r = qrotate(q, position)
            for k in range(3):
                acc[k] += weight * (r[k] + t[k])
        result.append(tuple(acc))
    return result


# --------------------------------------------------------------------------
# Preview rendering (Pillow, optional)
# --------------------------------------------------------------------------

def render_preview(path: Path, mesh: dict, positions: list, textures: dict, view: str,
                   size=(640, 760), sets=("default", "GloveOn"), title: str = ""):
    from PIL import Image, ImageDraw
    width, height = size
    keep = [s for s in mesh["submeshes"] if set(s["sets"]) & set(sets)]
    # Viewer at +Z (front), +X (character's left side) or +Y (top); depth grows toward the viewer.
    proj = {"front": lambda p: (p[0], p[1], p[2]),
            "side": lambda p: (-p[2], p[1], p[0]),
            "top": lambda p: (-p[0], p[2], p[1])}[view]
    pts = [proj(p) for p in positions]
    used = [pts[i] for s in keep for i in range(s["first_vertex"], s["first_vertex"] + s["vertex_count"])]
    lo = [min(p[k] for p in used) for k in range(2)]
    hi = [max(p[k] for p in used) for k in range(2)]
    scale = 0.9 * min(width / max(1e-6, hi[0] - lo[0]), height / max(1e-6, hi[1] - lo[1]))
    cx, cy = (lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2
    screen = [((p[0] - cx) * scale + width / 2, height / 2 - (p[1] - cy) * scale, p[2]) for p in pts]
    image = Image.new("RGB", size, (58, 64, 74))
    pixels = image.load()
    depth = [[-1e30] * width for _ in range(height)]
    light = (0.35, 0.55, 0.75)
    for sub in keep:
        tex = textures.get((sub["base"] or {}).get("texture"))
        tw, th, tdata = tex if tex else (1, 1, bytes((200, 200, 200, 255)))
        lo_i, hi_i = sub["first_index"] // 3, (sub["first_index"] + sub["index_count"]) // 3
        for a, b, c in mesh["triangles"][lo_i:hi_i]:
            (x0, y0, z0), (x1, y1, z1), (x2, y2, z2) = screen[a], screen[b], screen[c]
            area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
            if abs(area) < 1e-9:
                continue
            pa, pb_, pc = proj(positions[a]), proj(positions[b]), proj(positions[c])
            e1 = [pb_[k] - pa[k] for k in range(3)]
            e2 = [pc[k] - pa[k] for k in range(3)]
            n = (e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0])
            ln = math.sqrt(sum(v * v for v in n)) or 1
            shade = 0.35 + 0.65 * abs(sum(n[k] * light[k] for k in range(3)) / ln)
            uv = [mesh["vertices"][i][2] for i in (a, b, c)]
            xmin, xmax = max(0, int(min(x0, x1, x2))), min(width - 1, int(max(x0, x1, x2)) + 1)
            ymin, ymax = max(0, int(min(y0, y1, y2))), min(height - 1, int(max(y0, y1, y2)) + 1)
            for py in range(ymin, ymax + 1):
                for px in range(xmin, xmax + 1):
                    sx, sy = px + 0.5, py + 0.5
                    w0 = ((x1 - sx) * (y2 - sy) - (x2 - sx) * (y1 - sy)) / area
                    w1 = ((x2 - sx) * (y0 - sy) - (x0 - sx) * (y2 - sy)) / area
                    w2 = 1 - w0 - w1
                    if w0 < 0 or w1 < 0 or w2 < 0:
                        continue
                    z = w0 * z0 + w1 * z1 + w2 * z2
                    if z <= depth[py][px]:
                        continue
                    u = w0 * uv[0][0] + w1 * uv[1][0] + w2 * uv[2][0]
                    v = w0 * uv[0][1] + w1 * uv[1][1] + w2 * uv[2][1]
                    tx = int((u % 1.0) * tw) % tw
                    ty = int((v % 1.0) * th) % th
                    o = (ty * tw + tx) * 4
                    depth[py][px] = z
                    pixels[px, py] = (int(tdata[o] * shade), int(tdata[o + 1] * shade), int(tdata[o + 2] * shade))
    if title:
        ImageDraw.Draw(image).text((8, 8), title, fill=(240, 240, 240))
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------

def load_character(media: Path, character_id: str) -> tuple[dict, dict]:
    path = media / "Golfer" / "chars" / f"{character_id}char.xbx"
    data = path.read_bytes()
    resources = read_container(data)
    chr_resources = [r for r in resources if r["tag"] == "CHR " and r["kind"] == 1]
    if len(chr_resources) != 1:
        raise FormatError("Expected exactly one CHR resource")
    payload = resource_payload(data, chr_resources[0])
    character = parse_chr(payload)
    provenance = {"file": str(path.relative_to(media)), "sha256": sha256(data), "bytes": len(data),
                  "export_path": export_path(data), "chr_bytes": len(payload),
                  "chr_sha256": sha256(payload),
                  "resources": [{"tag": r["tag"], "kind": r["kind"], "size": r["size"],
                                 "chunks": len(r["parts"])} for r in resources]}
    return character, provenance


def run(media: Path, output: Path, character_id: str, clips: list[str],
        preview: Path | None, all_textures: bool, write_dds: bool = False) -> dict:
    character, provenance = load_character(media, character_id)
    mesh = build_mesh(character)
    skeleton = build_skeleton(character)
    output.mkdir(parents=True, exist_ok=True)
    (output / "textures").mkdir(exist_ok=True)
    (output / "clips").mkdir(exist_ok=True)

    mesh_bytes = write_mesh(mesh)
    atomic_write(output / "golfer_mesh.bin", mesh_bytes)

    fxx_path = media / "Golfer" / "CHARTEX" / f"{character_id}alltex.fxx"
    fxx = fxx_path.read_bytes()
    model = character["model"]
    wanted = {layer["texture"] for s in mesh["submeshes"] for layer in (s["base"], s["decal"])
              if layer and layer["texture"]}
    if all_textures:
        variants = {name.lower() for name in model["variant_textures"]}
        wanted |= {name for name in character["textures"] if name.lower() in variants}
    texture_info, decoded = {}, {}
    for name in sorted(wanted):
        entry = character["textures"].get(name) or next(
            (v for k, v in character["textures"].items() if k.lower() == name.lower()), None)
        if entry is None:
            texture_info[name] = {"error": "not in character texture directory"}
            continue
        try:
            w, h, rgba = decode_texture(fxx, entry)
        except FormatError as error:
            texture_info[name] = {"error": str(error)}
            continue
        decoded[name] = (w, h, rgba)
        atomic_write(output / "textures" / f"{name}.png", png_bytes(w, h, rgba))
        if write_dds:
            offset, size = entry["mips"][0]
            atomic_write(output / "textures" / f"{name}.dds",
                         dds_from_dxt(w, h, XBOX_DXT[entry["format"]], fxx[offset:offset + size]))
        texture_info[name] = {"file": f"textures/{name}.png", "width": w, "height": h,
                              "source_format": XBOX_DXT[entry["format"]].decode(),
                              "source_bytes": entry["mips"][0][1],
                              "source_mips": entry["mip_count"], "rgba_bytes": w * h * 4}

    skeleton_json = {"schema": 1, "units": "golfer model units (see golfer.json)",
                     "convention": "Hamilton quaternions [x,y,z,w]; world = parent ⊗ local; "
                                   "translation in parent space; source stores the conjugate",
                     "bones": skeleton["bones"]}
    atomic_write(output / "skeleton.json", (json.dumps(skeleton_json, indent=1) + "\n").encode())

    motions_path = media / "Golfer" / "chars" / "motions.tbf"
    motions = motions_path.read_bytes()
    entries = read_tbf(motions)
    clip_info = []
    preview_clip = None
    preview_frames = {}
    for name in clips:
        key = name if name.endswith(".ska") else name + ".ska"
        if key not in entries:
            clip_info.append({"name": name, "error": "not in motions.tbf"})
            continue
        off, size = entries[key]
        clip = parse_ska(motions[off:off + size])
        frames, flags = clip_poses(clip, skeleton)
        data = write_clip(clip, frames, flags)
        atomic_write(output / "clips" / f"{name}.pgaclip", data)
        info = {"name": name, "file": f"clips/{name}.pgaclip", "role": CLIP_ROLES.get(name),
                "frames": clip["frame_count"], "fps": round(1 / clip["seconds_per_frame"], 4),
                "seconds": round((clip["frame_count"] - 1) * clip["seconds_per_frame"], 4),
                "club_bone": clip["club_bone"], "events": clip["events"],
                "phases_frames": swing_phases(clip), "bytes": len(data),
                "animated_rotation_bones": sum(1 for f in flags if f & 1),
                "translation_bones": sum(1 for f in flags if f & 4)}
        clip_info.append(info)
        phases = info["phases_frames"] or {}
        if preview_clip is None and "backswing" in phases:
            preview_clip = (name, clip, frames, info)
        elif "stroke" in phases and name not in preview_frames:
            preview_frames[name] = (frames, {"address": 0, "impact": phases["stroke"][1],
                                             "finish": phases["follow_through"][1]})

    triangles = len(mesh["triangles"])
    default_sets = {"default", "GloveOn"}
    default_tris = sum(s["index_count"] // 3 for s in mesh["submeshes"] if set(s["sets"]) & default_sets)
    default_verts = sum(s["vertex_count"] for s in mesh["submeshes"] if set(s["sets"]) & default_sets)
    manifest = {
        "schema": 1,
        "tool": "Tools/decode_pga2005_golfer.py",
        "character": character_id,
        "character_note": ("01char.xbx exporter path TIGERWOODS\\EXPORTED\\HT.CHX (02 is HS.CHX); "
                           "engine lookup 'tiger'->model id 1 is mapped through a runtime table"),
        "source": {**provenance, "textures": {"file": str(fxx_path.relative_to(media)), "sha256": sha256(fxx)},
                   "motions": {"file": str(motions_path.relative_to(media)), "sha256": sha256(motions),
                               "entries": len(entries)}},
        "units": {"model_units_height": round(max(v[0][1] for v in mesh["vertices"]) -
                                              min(v[0][1] for v in mesh["vertices"]), 4),
                  "position_scale_source": model["position_scale"],
                  "engine_world_scale_inches_per_unit": 44.68504,
                  "engine_world_scale_note": "Engine.dll 0x101aebb7: (1*0.3937008+0.5)/2/0.01, then * per-player "
                                             "local scale (BodyC::SetOwner) and X mirrored (-1) in "
                                             "SkeletonC::CreateWorldMatrix 0x101b262d"},
        "coordinate_system": {"up": "+Y", "character_faces": "+Z", "character_left": "+X",
                              "bind_pose": "T-pose, pelvis at origin",
                              "animated_poses": "root translation is ground-relative (pelvis ~0.99 units up)"},
        "mesh": {"file": "golfer_mesh.bin", "format": "PGAGMSH1 (see docs/research/PGA2005-GOLFER.md)",
                 "bytes": len(mesh_bytes), "vertices": len(mesh["vertices"]), "triangles": triangles,
                 "default_visible_vertices": default_verts, "default_visible_triangles": default_tris,
                 "winding": "counter-clockwise about stored vertex normals (right-handed cross product); "
                            "original renders the golfer double-sided (CULLMODE NONE) with alpha blend",
                 "reoriented_triangles": mesh["reoriented"],
                 "strip_order_agreement": round(mesh["strip_parity_agreement"], 4),
                 "max_influences": 3, "submeshes": mesh["submeshes"]},
        "visibility_sets": model["sets"],
        "shirt_variants": {"sets": model["variant_sets"], "textures": model["variant_textures"]},
        "skeleton": {"file": "skeleton.json", "bones": len(skeleton["bones"])},
        "textures": texture_info,
        "clips": clip_info,
        "memory": {
            "mesh_file_bytes": len(mesh_bytes),
            "texture_source_dxt_bytes": sum(t.get("source_bytes", 0) for t in texture_info.values()),
            "texture_rgba_bytes": sum(t.get("rgba_bytes", 0) for t in texture_info.values()),
            "clip_bytes": sum(c.get("bytes", 0) for c in clip_info)},
    }
    atomic_write(output / "golfer.json", (json.dumps(manifest, indent=1) + "\n").encode())

    if preview is not None:
        bind = skin_positions(skeleton, mesh, None)
        render_preview(preview / "bind_front.png", mesh, bind, decoded, "front", title="bind pose front")
        render_preview(preview / "bind_side.png", mesh, bind, decoded, "side", title="bind pose side")
        if preview_clip:
            name, clip, frames, info = preview_clip
            phases = info["phases_frames"]
            keys = {"address": phases["address"][0], "top": phases["backswing"][1],
                    "impact": phases["downswing"][1],
                    "finish": min(len(frames) - 1, phases["follow_through"][0] +
                                  round(0.8 / clip["seconds_per_frame"]))}
            preview_frames[name] = (frames, keys)
        for name, (frames, keys) in preview_frames.items():
            for label, f in keys.items():
                positions = skin_positions(skeleton, mesh, frames[f])
                render_preview(preview / f"{name}_{label}_f{f:03d}.png", mesh, positions, decoded, "front",
                               title=f"{name} {label} frame {f}")
    return manifest


def atomic_write(path: Path, data: bytes):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_bytes(data)
    temporary.replace(path)


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--media", type=Path, default=root / "Library/SourceMedia/pga2005/install")
    parser.add_argument("--output", type=Path, default=root / "Library/Imported/pga2005/golfer")
    parser.add_argument("--character", default="01", help="two-digit NNchar.xbx id (default 01, Tiger HT)")
    parser.add_argument("--clip", action="append", help="motions.tbf clip name (repeatable)")
    parser.add_argument("--preview", type=Path, nargs="?", const=root / "Library/Research/golfer-preview",
                        help="render orthographic PNG previews (requires Pillow)")
    parser.add_argument("--all-textures", action="store_true", help="also decode shirt variant textures")
    parser.add_argument("--dds", action="store_true",
                        help="also write the source DXT1/DXT3 blocks as .dds (BC1/BC2 upload, no RGBA expansion)")
    args = parser.parse_args()
    if not re.fullmatch(r"\d\d", args.character):
        parser.error("--character must be two digits")
    manifest = run(args.media, args.output, args.character, args.clip or list(DEFAULT_CLIPS),
                   args.preview, args.all_textures, args.dds)
    mesh = manifest["mesh"]
    print(f"character {manifest['character']}: {mesh['vertices']} vertices, {mesh['triangles']} triangles "
          f"({mesh['default_visible_triangles']} default-visible), {len(manifest['textures'])} textures, "
          f"{len([c for c in manifest['clips'] if 'file' in c])} clips -> {args.output}")


if __name__ == "__main__":
    main()
