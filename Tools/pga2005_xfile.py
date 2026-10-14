#!/usr/bin/env python3
"""Standard-library parser for DirectX retained-mode ``.x`` files (``xof 0303``).

Tiger Woods PGA Tour 2005 ships both encodings of the same format:

* text (``xof 0303txt 0032``): ``ball01.x``, the ``cls/PB*.x`` crowd meshes;
* binary (``xof 0303bin 0032``): ``tee01.x``, divots, birds, and every tree
  mesh embedded in a course library (``.TCL``) ``tagTreeMesh`` record.

The parser is template driven. It reads template definitions found in the
file, falls back to the standard DirectX/D3DX templates, and interprets each
data object's flat value stream (integers, floats, strings) against its
template. It then exposes frames (with ``FrameTransformMatrix``), meshes
(positions, polygon faces, normals with their own face indices, texture
coordinates, vertex colours, material lists and texture file names), skin
weights and animation keys.

No code from the original game runs. Compressed ``tzip``/``bzip`` files and
the ``Decl``/``FVFData`` vertex-declaration extensions are not supported; no
supplied PGA 2005 file uses them.

API::

    xf = parse(data)                 # or load(path)
    for mesh in xf.meshes():         # flattened, with the accumulated frame matrix
        arrays = mesh.render_arrays()  # split vertices, triangles, material ranges

Matrices keep the file's DirectX row-vector convention: a point ``p`` maps to
``p · M``; translation is in elements 12–14. Coordinates are left as authored
(DirectX is left-handed); callers convert.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import json
import math
from pathlib import Path
import re
import struct
import sys

MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_ARRAY = 8_000_000

PRIMITIVES = {"WORD", "DWORD", "FLOAT", "DOUBLE", "CHAR", "UCHAR", "BYTE", "SWORD",
              "SDWORD", "STRING", "CSTRING", "UNICODE", "LPSTR", "VOID"}
INTEGER_TYPES = {"WORD", "DWORD", "CHAR", "UCHAR", "BYTE", "SWORD", "SDWORD"}
FLOAT_TYPES = {"FLOAT", "DOUBLE"}
STRING_TYPES = {"STRING", "CSTRING", "UNICODE", "LPSTR"}

# Binary token identifiers (DirectX "Binary Format" specification).
TOKEN_NAME, TOKEN_STRING, TOKEN_INTEGER, TOKEN_GUID = 1, 2, 3, 5
TOKEN_INTEGER_LIST, TOKEN_FLOAT_LIST = 6, 7
PUNCTUATION = {10: "{", 11: "}", 12: "(", 13: ")", 14: "[", 15: "]", 16: "<", 17: ">",
               18: ".", 19: ",", 20: ";"}
TOKEN_TEMPLATE = 31
TYPE_TOKENS = {40: "WORD", 41: "DWORD", 42: "FLOAT", 43: "DOUBLE", 44: "CHAR", 45: "UCHAR",
               46: "SWORD", 47: "SDWORD", 48: "VOID", 49: "LPSTR", 50: "UNICODE",
               51: "CSTRING"}
TOKEN_ARRAY = 52

STANDARD_TEMPLATES = """
template Header { <3D82AB43-62DA-11cf-AB39-0020AF71E433> WORD major; WORD minor; DWORD flags; }
template Vector { <3D82AB5E-62DA-11cf-AB39-0020AF71E433> FLOAT x; FLOAT y; FLOAT z; }
template Coords2d { <F6F23F44-7686-11cf-8F52-0040333594A3> FLOAT u; FLOAT v; }
template Matrix4x4 { <F6F23F45-7686-11cf-8F52-0040333594A3> array FLOAT matrix[16]; }
template ColorRGBA { <35FF44E0-6C7C-11cf-8F52-0040333594A3> FLOAT red; FLOAT green; FLOAT blue; FLOAT alpha; }
template ColorRGB { <D3E16E81-7835-11cf-8F52-0040333594A3> FLOAT red; FLOAT green; FLOAT blue; }
template IndexedColor { <1630B820-7842-11cf-8F52-0040333594A3> DWORD index; ColorRGBA indexColor; }
template Boolean { <4885AE61-78E8-11cf-8F52-0040333594A3> WORD truefalse; }
template Boolean2d { <4885AE63-78E8-11cf-8F52-0040333594A3> Boolean u; Boolean v; }
template MaterialWrap { <4885AE60-78E8-11cf-8F52-0040333594A3> Boolean u; Boolean v; }
template TextureFilename { <A42790E1-7810-11cf-8F52-0040333594A3> STRING filename; }
template Material { <3D82AB4D-62DA-11cf-AB39-0020AF71E433> ColorRGBA faceColor; FLOAT power; ColorRGB specularColor; ColorRGB emissiveColor; [...] }
template MeshFace { <3D82AB5F-62DA-11cf-AB39-0020AF71E433> DWORD nFaceVertexIndices; array DWORD faceVertexIndices[nFaceVertexIndices]; }
template MeshFaceWraps { <4885AE62-78E8-11cf-8F52-0040333594A3> DWORD nFaceWrapValues; array Boolean2d faceWrapValues[nFaceWrapValues]; }
template MeshTextureCoords { <F6F23F40-7686-11cf-8F52-0040333594A3> DWORD nTextureCoords; array Coords2d textureCoords[nTextureCoords]; }
template MeshMaterialList { <F6F23F42-7686-11cf-8F52-0040333594A3> DWORD nMaterials; DWORD nFaceIndexes; array DWORD faceIndexes[nFaceIndexes]; [Material] }
template MeshNormals { <F6F23F43-7686-11cf-8F52-0040333594A3> DWORD nNormals; array Vector normals[nNormals]; DWORD nFaceNormals; array MeshFace faceNormals[nFaceNormals]; }
template MeshVertexColors { <1630B821-7842-11cf-8F52-0040333594A3> DWORD nVertexColors; array IndexedColor vertexColors[nVertexColors]; }
template Mesh { <3D82AB44-62DA-11cf-AB39-0020AF71E433> DWORD nVertices; array Vector vertices[nVertices]; DWORD nFaces; array MeshFace faces[nFaces]; [...] }
template FrameTransformMatrix { <F6F23F41-7686-11cf-8F52-0040333594A3> Matrix4x4 frameMatrix; }
template Frame { <3D82AB46-62DA-11cf-AB39-0020AF71E433> [...] }
template FloatKeys { <10DD46A9-775B-11cf-8F52-0040333594A3> DWORD nValues; array FLOAT values[nValues]; }
template TimedFloatKeys { <F406B180-7B3B-11cf-8F52-0040333594A3> DWORD time; FloatKeys tfkeys; }
template AnimationKey { <10DD46A8-775B-11cf-8F52-0040333594A3> DWORD keyType; DWORD nKeys; array TimedFloatKeys keys[nKeys]; }
template AnimationOptions { <E2BF56C0-840F-11cf-8F52-0040333594A3> DWORD openclosed; DWORD positionquality; }
template Animation { <3D82AB4F-62DA-11cf-AB39-0020AF71E433> [...] }
template AnimationSet { <3D82AB50-62DA-11cf-AB39-0020AF71E433> [Animation] }
template AnimTicksPerSecond { <9E415A43-7BA6-4a73-8743-B73D47E88476> DWORD AnimTicksPerSecond; }
template XSkinMeshHeader { <3CF169CE-FF7C-44ab-93C0-F78F62D172E2> WORD nMaxSkinWeightsPerVertex; WORD nMaxSkinWeightsPerFace; WORD nBones; }
template VertexDuplicationIndices { <B8D65549-D7C9-4995-89CF-53A9A8B031E3> DWORD nIndices; DWORD nOriginalVertices; array DWORD indices[nIndices]; }
template SkinWeights { <6F0D123B-BAD2-4167-A0D0-80224F25FABB> STRING transformNodeName; DWORD nWeights; array DWORD vertexIndices[nWeights]; array FLOAT weights[nWeights]; Matrix4x4 matrixOffset; }
"""


class XFileError(ValueError):
    """Malformed or unsupported .x input."""


class XString(str):
    """A quoted/encoded string value, distinct from a raw text-format number."""


@dataclass
class Token:
    kind: str          # name, string, num, int, float, ints, floats, guid, template, array, type, or punctuation
    value: object = None


@dataclass
class Member:
    type: str
    name: str
    dims: list = field(default_factory=list)   # ints or member names; empty for scalars


@dataclass
class Template:
    name: str
    guid: str | None
    members: list[Member]
    restriction: str      # "closed", "open" or "restricted"


@dataclass
class Reference:
    name: str


@dataclass
class DataObject:
    type: str
    name: str | None
    values: object                     # dict for template-decoded data, list of raw values otherwise
    children: list = field(default_factory=list)   # DataObject or Reference


@dataclass
class Material:
    name: str | None
    face_color: tuple
    power: float
    specular: tuple
    emissive: tuple
    textures: list[str]


@dataclass
class SkinWeights:
    bone: str
    vertex_indices: list[int]
    weights: list[float]
    offset_matrix: list[float]


@dataclass
class Mesh:
    name: str | None
    frame_path: list[str]
    matrix: list[float]                 # accumulated frame matrix (row-vector, 16 floats)
    positions: list[tuple]
    faces: list[list[int]]
    normals: list[tuple] = field(default_factory=list)
    normal_faces: list[list[int]] = field(default_factory=list)
    uvs: list[tuple] = field(default_factory=list)
    colors: dict = field(default_factory=dict)      # vertex index -> RGBA
    face_materials: list[int] = field(default_factory=list)
    materials: list[Material] = field(default_factory=list)
    skin_header: dict | None = None
    skin_weights: list[SkinWeights] = field(default_factory=list)
    duplication_indices: dict | None = None

    def triangles(self):
        """Fan-triangulate polygons; yields (face_index, (a, b, c), corner_indices)."""
        for f, face in enumerate(self.faces):
            for k in range(1, len(face) - 1):
                yield f, (face[0], face[k], face[k + 1]), (0, k, k + 1)

    def render_arrays(self, apply_matrix: bool = False) -> dict:
        """Return de-indexed arrays suitable for a GPU vertex buffer.

        A render vertex is a unique (position index, normal index) pair; UVs
        and colours follow the position index as in D3DX. Triangles are
        grouped by material, and ``material_ranges`` lists contiguous index
        ranges ``(material, first_index, index_count)``.
        """
        matrix = self.matrix if apply_matrix else None
        has_normals = bool(self.normals) and len(self.normal_faces) == len(self.faces)
        if has_normals:
            for f, (face, nface) in enumerate(zip(self.faces, self.normal_faces)):
                if len(face) != len(nface):
                    raise XFileError(f"Mesh {self.name}: face {f} normal arity differs")
        lookup, positions, normals, uvs, colors = {}, [], [], [], []
        by_material: dict[int, list[int]] = {}
        normals_by = normal_matrix(matrix) if matrix else None
        for f, tri, corners in self.triangles():
            material = self.face_materials[f] if f < len(self.face_materials) else 0
            out = by_material.setdefault(material, [])
            for vertex, corner in zip(tri, corners):
                normal_index = self.normal_faces[f][corner] if has_normals else -1
                key = (vertex, normal_index)
                index = lookup.get(key)
                if index is None:
                    index = len(positions)
                    lookup[key] = index
                    p = self.positions[vertex]
                    positions.append(transform_point(p, matrix) if matrix else p)
                    if has_normals:
                        n = self.normals[normal_index]
                        normals.append(normalize(transform_vector(n, normals_by)) if matrix else n)
                    uvs.append(self.uvs[vertex] if vertex < len(self.uvs) else (0.0, 0.0))
                    colors.append(self.colors.get(vertex, (1.0, 1.0, 1.0, 1.0)))
                out.append(index)
        indices, ranges = [], []
        for material in sorted(by_material):
            ranges.append((material, len(indices), len(by_material[material])))
            indices.extend(by_material[material])
        return {"positions": positions, "normals": normals, "uvs": uvs, "colors": colors,
                "indices": indices, "material_ranges": ranges}


@dataclass
class Frame:
    name: str | None
    matrix: list[float]
    children: list["Frame"] = field(default_factory=list)
    meshes: list[DataObject] = field(default_factory=list)


@dataclass
class AnimationKey:
    key_type: int          # 0 rotation quaternion (w,x,y,z), 1 scale, 2 position, 3/4 matrix
    keys: list[tuple]      # (time, values)


@dataclass
class Animation:
    name: str | None
    target: str | None
    keys: list[AnimationKey]


@dataclass
class AnimationSet:
    name: str | None
    animations: list[Animation]


IDENTITY = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]


def multiply(a: list[float], b: list[float]) -> list[float]:
    """Row-vector product: p · (a · b) applies a first, then b."""
    return [sum(a[r * 4 + k] * b[k * 4 + c] for k in range(4)) for r in range(4) for c in range(4)]


def transform_point(p, m):
    x, y, z = p
    return (x * m[0] + y * m[4] + z * m[8] + m[12],
            x * m[1] + y * m[5] + z * m[9] + m[13],
            x * m[2] + y * m[6] + z * m[10] + m[14])


def transform_vector(v, m):
    x, y, z = v
    return (x * m[0] + y * m[4] + z * m[8], x * m[1] + y * m[5] + z * m[9], x * m[2] + y * m[6] + z * m[10])


def normalize(v):
    length = math.sqrt(sum(c * c for c in v))
    return tuple(c / length for c in v) if length > 0 else v


def normal_matrix(m):
    """Inverse-transpose of the upper 3x3 (row-vector form), as a 16-element matrix."""
    a, b, c, d, e, f, g, h, i = m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10]
    det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    if abs(det) < 1e-30:
        return m
    inv = [(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
           (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
           (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]
    t = [inv[0], inv[3], inv[6], inv[1], inv[4], inv[7], inv[2], inv[5], inv[8]]
    return [t[0], t[1], t[2], 0.0, t[3], t[4], t[5], 0.0, t[6], t[7], t[8], 0.0, 0.0, 0.0, 0.0, 1.0]


# ---------------------------------------------------------------- tokenizers

_TEXT_TOKEN = re.compile(rb"""
    (?P<ws>\s+|//[^\n]*|\#[^\n]*)
  | (?P<guid><\s*[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\s*>)
  | (?P<string>"[^"]*")
  | (?P<num>[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?(?![A-Za-z_]))
  | (?P<name>[A-Za-z_][A-Za-z0-9_\-.]*|\d[A-Za-z0-9_\-.]*[A-Za-z_][A-Za-z0-9_\-.]*)
  | (?P<punct>[{}\[\]<>,;().])
""", re.X)


def tokenize_text(body: bytes) -> list[Token]:
    tokens, position, length = [], 0, len(body)
    while position < length:
        match = _TEXT_TOKEN.match(body, position)
        if not match:
            raise XFileError(f"Unexpected text .x byte {body[position:position + 16]!r} at {position + 16}")
        position = match.end()
        kind = match.lastgroup
        text = match.group(kind)
        if kind == "ws":
            continue
        if kind == "guid":
            tokens.append(Token("guid", text.strip(b"<> \t\r\n").decode("ascii").upper()))
        elif kind == "string":
            tokens.append(Token("string", XString(text[1:-1].decode("cp1252"))))
        elif kind == "num":
            tokens.append(Token("num", text.decode("ascii")))
        elif kind == "name":
            name = text.decode("cp1252")
            if name == "template":
                tokens.append(Token("template"))
            elif name == "array":
                tokens.append(Token("array"))
            else:
                tokens.append(Token("name", name))
        else:
            tokens.append(Token(text.decode("ascii")))
    return tokens


def tokenize_binary(body: bytes, float_size: int) -> list[Token]:
    tokens, position, length = [], 0, len(body)
    float_format = "<%d" + ("f" if float_size == 4 else "d")

    def take(count):
        nonlocal position
        if count < 0 or position + count > length:
            raise XFileError("Truncated binary .x token")
        data = body[position:position + count]
        position += count
        return data

    while position < length:
        if length - position < 2:
            break   # trailing pad byte
        token = struct.unpack("<H", take(2))[0]
        if token == TOKEN_NAME:
            count = struct.unpack("<I", take(4))[0]
            tokens.append(Token("name", take(count).decode("cp1252")))
        elif token == TOKEN_STRING:
            count = struct.unpack("<I", take(4))[0]
            text = take(count).decode("cp1252").split("\0", 1)[0]
            # The specification shows a DWORD terminator; the shipped D3DX
            # writer emits the ';'/',' as an ordinary WORD token, which the
            # parser then skips as a separator.
            tokens.append(Token("string", XString(text)))
        elif token == TOKEN_INTEGER:
            tokens.append(Token("int", struct.unpack("<I", take(4))[0]))
        elif token == TOKEN_GUID:
            a, b, c = struct.unpack("<IHH", take(8))
            tail = take(8)
            tokens.append(Token("guid", f"{a:08X}-{b:04X}-{c:04X}-{tail[:2].hex().upper()}-{tail[2:].hex().upper()}"))
        elif token == TOKEN_INTEGER_LIST:
            count = struct.unpack("<I", take(4))[0]
            if count > MAX_ARRAY:
                raise XFileError("Binary .x integer list exceeds resource bound")
            tokens.append(Token("ints", list(struct.unpack("<%dI" % count, take(4 * count)))))
        elif token == TOKEN_FLOAT_LIST:
            count = struct.unpack("<I", take(4))[0]
            if count > MAX_ARRAY:
                raise XFileError("Binary .x float list exceeds resource bound")
            tokens.append(Token("floats", list(struct.unpack(float_format % count, take(float_size * count)))))
        elif token in PUNCTUATION:
            tokens.append(Token(PUNCTUATION[token]))
        elif token == TOKEN_TEMPLATE:
            tokens.append(Token("template"))
        elif token == TOKEN_ARRAY:
            tokens.append(Token("array"))
        elif token in TYPE_TOKENS:
            tokens.append(Token("type", TYPE_TOKENS[token]))
        else:
            raise XFileError(f"Unknown binary .x token {token} at {position + 14}")
    return tokens


# -------------------------------------------------------------------- parser

class _Parser:
    def __init__(self, tokens: list[Token], templates: dict[str, Template]):
        self.tokens, self.index, self.templates = tokens, 0, templates

    def peek(self, offset=0):
        i = self.index + offset
        return self.tokens[i] if i < len(self.tokens) else None

    def next(self):
        token = self.peek()
        if token is None:
            raise XFileError("Unexpected end of .x data")
        self.index += 1
        return token

    def expect(self, kind):
        token = self.next()
        if token.kind != kind:
            raise XFileError(f"Expected {kind!r}, found {token.kind!r} {token.value!r}")
        return token

    def parse(self):
        objects = []
        while self.peek() is not None:
            token = self.peek()
            if token.kind == "template":
                template = self.parse_template()
                self.templates[template.name] = template
            elif token.kind == "name":
                objects.append(self.parse_object())
            elif token.kind in (";", ","):
                self.index += 1
            else:
                raise XFileError(f"Unexpected top-level token {token.kind!r}")
        return objects

    def parse_template(self):
        self.expect("template")
        name = self.expect("name").value
        self.expect("{")
        guid = self.next().value if self.peek() and self.peek().kind == "guid" else None
        members, restriction = [], "closed"
        while True:
            token = self.next()
            if token.kind == "}":
                break
            if token.kind == "[":
                depth, contents = 1, []
                while depth:
                    inner = self.next()
                    depth += inner.kind == "["
                    depth -= inner.kind == "]"
                    contents.append(inner)
                restriction = "open" if any(t.kind == "." for t in contents) else "restricted"
                continue
            is_array = token.kind == "array"
            if is_array:
                token = self.next()
            if token.kind not in ("name", "type"):
                raise XFileError(f"Template {name}: unexpected member token {token.kind!r}")
            member = Member(str(token.value), self.expect("name").value)
            if is_array:
                while self.peek() and self.peek().kind == "[":
                    self.next()
                    dim = self.next()
                    if dim.kind == "name":
                        member.dims.append(dim.value)
                    elif dim.kind in ("num", "int"):
                        member.dims.append(int(dim.value))
                    elif dim.kind == "ints" and len(dim.value) == 1:
                        member.dims.append(dim.value[0])
                    else:
                        raise XFileError(f"Template {name}: invalid array dimension")
                    self.expect("]")
                if not member.dims:
                    raise XFileError(f"Template {name}: array without dimension")
            members.append(member)
            if self.peek() and self.peek().kind == ";":
                self.next()
        return Template(name, guid, members, restriction)

    def parse_object(self) -> DataObject:
        type_name = self.expect("name").value
        name = None
        if self.peek() and self.peek().kind == "name":
            name = self.next().value
        self.expect("{")
        if self.peek() and self.peek().kind == "guid":
            self.next()
        values, children = [], []
        while True:
            token = self.peek()
            if token is None:
                raise XFileError(f"Unterminated {type_name} object")
            if token.kind == "}":
                self.index += 1
                break
            if token.kind == "name":
                children.append(self.parse_object())
            elif token.kind == "{":
                self.index += 1
                reference = self.expect("name").value
                if self.peek() and self.peek().kind == "guid":
                    self.next()
                self.expect("}")
                children.append(Reference(reference))
            elif token.kind in ("ints", "floats"):
                values.extend(token.value)
                self.index += 1
            elif token.kind in ("int", "num", "string"):
                values.append(token.value)
                self.index += 1
            elif token.kind in (";", ",", "guid"):
                self.index += 1
            else:
                raise XFileError(f"Unexpected token {token.kind!r} inside {type_name}")
        template = self.templates.get(type_name)
        if template is not None and template.members:
            cursor = [0]
            decoded = self.decode(template, values, cursor)
            if cursor[0] != len(values):
                raise XFileError(f"{type_name} {name or ''}: {len(values) - cursor[0]} unread values")
            return DataObject(type_name, name, decoded, children)
        return DataObject(type_name, name, values, children)

    def decode(self, template: Template, values: list, cursor: list) -> dict:
        result = {}
        for member in template.members:
            if member.dims:
                counts = []
                for dim in member.dims:
                    count = result.get(dim) if isinstance(dim, str) else dim
                    if not isinstance(count, int) or not 0 <= count <= MAX_ARRAY:
                        raise XFileError(f"{template.name}.{member.name}: invalid array size {count!r}")
                    counts.append(count)
                result[member.name] = self.read_array(member.type, counts, values, cursor)
            else:
                result[member.name] = self.read_value(member.type, values, cursor)
        return result

    def read_array(self, type_name, counts, values, cursor):
        if len(counts) > 1:
            return [self.read_array(type_name, counts[1:], values, cursor) for _ in range(counts[0])]
        count = counts[0]
        if type_name in FLOAT_TYPES and cursor[0] + count <= len(values):
            start = cursor[0]
            chunk = values[start:start + count]
            if any(isinstance(v, XString) for v in chunk):
                raise XFileError("Expected FLOAT values, found a string")
            cursor[0] += count
            return [float(v) for v in chunk]
        return [self.read_value(type_name, values, cursor) for _ in range(count)]

    def read_value(self, type_name, values, cursor):
        if type_name in PRIMITIVES:
            if cursor[0] >= len(values):
                raise XFileError(f"Missing {type_name} value")
            value = values[cursor[0]]
            cursor[0] += 1
            if type_name in STRING_TYPES:
                if not isinstance(value, XString):
                    raise XFileError(f"Expected string value, found {value!r}")
                return str(value)
            if isinstance(value, XString):
                raise XFileError(f"Expected {type_name}, found string {value!r}")
            if type_name in INTEGER_TYPES:
                if isinstance(value, str) and not re.fullmatch(r"[-+]?\d+(\.0*)?", value):
                    raise XFileError(f"Expected integer, found {value!r}")
                return int(float(value)) if isinstance(value, str) else int(value)
            if type_name in FLOAT_TYPES:
                return float(value)
            raise XFileError(f"Unsupported primitive {type_name}")
        template = self.templates.get(type_name)
        if template is None:
            raise XFileError(f"Unknown template type {type_name}")
        return self.decode(template, values, cursor)


def standard_templates() -> dict[str, Template]:
    parser = _Parser(tokenize_text(STANDARD_TEMPLATES.encode("ascii")), {})
    parser.parse()
    return parser.templates


_STANDARD = None


@dataclass
class XFile:
    format: str
    float_size: int
    templates: dict
    objects: list

    def frames(self) -> list[Frame]:
        def build(obj):
            frame = Frame(obj.name, list(IDENTITY))
            for child in obj.children:
                if isinstance(child, DataObject):
                    if child.type == "FrameTransformMatrix":
                        frame.matrix = list(child.values["frameMatrix"]["matrix"])
                    elif child.type == "Frame":
                        frame.children.append(build(child))
                    elif child.type == "Mesh":
                        frame.meshes.append(child)
            return frame
        return [build(o) for o in self.objects if o.type == "Frame"]

    def named_objects(self) -> dict[str, DataObject]:
        """Top-level named data objects, used to resolve ``{ Name }`` material references."""
        return {o.name: o for o in self.objects if o.name}

    def meshes(self) -> list[Mesh]:
        """Every mesh with its accumulated frame matrix (row-vector: child, then parents)."""
        out, named = [], self.named_objects()

        def walk(frame, parent, path):
            world = multiply(frame.matrix, parent)
            here = path + [frame.name or ""]
            for mesh in frame.meshes:
                out.append(mesh_from_object(mesh, here, world, named))
            for child in frame.children:
                walk(child, world, here)
        for frame in self.frames():
            walk(frame, IDENTITY, [])
        for obj in self.objects:
            if obj.type == "Mesh":
                out.append(mesh_from_object(obj, [], list(IDENTITY), named))
        return out

    def animation_sets(self) -> list[AnimationSet]:
        sets = []
        for obj in self.objects:
            if obj.type != "AnimationSet":
                continue
            animations = []
            for child in obj.children:
                if not isinstance(child, DataObject) or child.type != "Animation":
                    continue
                target, keys = None, []
                for item in child.children:
                    if isinstance(item, Reference):
                        target = item.name
                    elif item.type == "Frame":
                        target = item.name
                    elif item.type == "AnimationKey":
                        keys.append(AnimationKey(item.values["keyType"],
                                                 [(k["time"], tuple(k["tfkeys"]["values"]))
                                                  for k in item.values["keys"]]))
                animations.append(Animation(child.name, target, keys))
            sets.append(AnimationSet(obj.name, animations))
        return sets

    def ticks_per_second(self) -> int | None:
        for obj in self.objects:
            if obj.type == "AnimTicksPerSecond":
                return obj.values["AnimTicksPerSecond"]
        return None


def _material(obj: DataObject) -> Material:
    v = obj.values
    color = v["faceColor"]
    textures = [c.values["filename"] for c in obj.children
                if isinstance(c, DataObject) and c.type == "TextureFilename"]
    return Material(obj.name, (color["red"], color["green"], color["blue"], color["alpha"]),
                    v["power"], tuple(v["specularColor"].values()), tuple(v["emissiveColor"].values()),
                    textures)


def mesh_from_object(obj: DataObject, path: list[str], matrix: list[float],
                     named: dict | None = None) -> Mesh:
    v = obj.values
    positions = [(p["x"], p["y"], p["z"]) for p in v["vertices"]]
    faces = [list(f["faceVertexIndices"]) for f in v["faces"]]
    for face in faces:
        if len(face) < 3 or any(not 0 <= i < len(positions) for i in face):
            raise XFileError(f"Mesh {obj.name}: invalid face {face}")
    mesh = Mesh(obj.name, path, matrix, positions, faces)
    for child in obj.children:
        if isinstance(child, Reference):
            continue
        cv = child.values
        if child.type == "MeshNormals":
            mesh.normals = [(n["x"], n["y"], n["z"]) for n in cv["normals"]]
            mesh.normal_faces = [list(f["faceVertexIndices"]) for f in cv["faceNormals"]]
            if any(not 0 <= i < len(mesh.normals) for f in mesh.normal_faces for i in f):
                raise XFileError(f"Mesh {obj.name}: invalid normal index")
        elif child.type == "MeshTextureCoords":
            mesh.uvs = [(c["u"], c["v"]) for c in cv["textureCoords"]]
        elif child.type == "MeshVertexColors":
            mesh.colors = {c["index"]: (c["indexColor"]["red"], c["indexColor"]["green"],
                                        c["indexColor"]["blue"], c["indexColor"]["alpha"])
                           for c in cv["vertexColors"]}
        elif child.type == "MeshMaterialList":
            mesh.face_materials = list(cv["faceIndexes"])
            for item in child.children:
                if isinstance(item, DataObject) and item.type == "Material":
                    mesh.materials.append(_material(item))
                elif isinstance(item, Reference) and named and item.name in named:
                    mesh.materials.append(_material(named[item.name]))
            if mesh.face_materials and len(mesh.face_materials) < len(faces):
                # D3DX repeats the last index when the list is shorter.
                mesh.face_materials += [mesh.face_materials[-1]] * (len(faces) - len(mesh.face_materials))
            if any(not 0 <= m < max(cv["nMaterials"], 1) for m in mesh.face_materials):
                raise XFileError(f"Mesh {obj.name}: material index out of range")
        elif child.type == "XSkinMeshHeader":
            mesh.skin_header = dict(cv)
        elif child.type == "SkinWeights":
            if any(not 0 <= i < len(positions) for i in cv["vertexIndices"]):
                raise XFileError(f"Mesh {obj.name}: invalid skin vertex index")
            mesh.skin_weights.append(SkinWeights(cv["transformNodeName"], list(cv["vertexIndices"]),
                                                 list(cv["weights"]), list(cv["matrixOffset"]["matrix"])))
        elif child.type == "VertexDuplicationIndices":
            mesh.duplication_indices = dict(cv)
    if mesh.uvs and len(mesh.uvs) != len(positions):
        raise XFileError(f"Mesh {obj.name}: texture coordinate count differs from vertex count")
    return mesh


def parse(data: bytes) -> XFile:
    global _STANDARD
    if len(data) < 16 or len(data) > MAX_FILE_BYTES:
        raise XFileError("Invalid .x byte count")
    header = data[:16]
    if header[:4] != b"xof " or header[4:8] not in (b"0302", b"0303"):
        raise XFileError(f"Not a DirectX .x file: {header!r}")
    kind, float_bits = header[8:12], header[12:16]
    if float_bits not in (b"0032", b"0064"):
        raise XFileError("Unsupported .x float size")
    float_size = 4 if float_bits == b"0032" else 8
    if kind == b"txt ":
        tokens = tokenize_text(data[16:])
    elif kind == b"bin ":
        tokens = tokenize_binary(data[16:], float_size)
    else:
        raise XFileError(f"Unsupported .x encoding {kind!r} (compressed files are not supported)")
    if _STANDARD is None:
        _STANDARD = standard_templates()
    parser = _Parser(tokens, dict(_STANDARD))
    objects = parser.parse()
    return XFile(kind.decode().strip(), float_size, parser.templates, objects)


def load(path: str | Path) -> XFile:
    return parse(Path(path).read_bytes())


def summary(xf: XFile) -> dict:
    meshes = []
    for mesh in xf.meshes():
        lo = [min(p[i] for p in mesh.positions) for i in range(3)] if mesh.positions else []
        hi = [max(p[i] for p in mesh.positions) for i in range(3)] if mesh.positions else []
        meshes.append({"name": mesh.name, "frame_path": mesh.frame_path,
                       "vertices": len(mesh.positions), "faces": len(mesh.faces),
                       "triangles": sum(len(f) - 2 for f in mesh.faces),
                       "normals": len(mesh.normals), "uvs": len(mesh.uvs),
                       "vertex_colors": len(mesh.colors),
                       "materials": [{"name": m.name, "face_color": m.face_color,
                                      "textures": m.textures} for m in mesh.materials],
                       "bones": [w.bone for w in mesh.skin_weights],
                       "bounds_local": [lo, hi]})

    def frame_tree(frame):
        return {"name": frame.name, "matrix": frame.matrix, "meshes": [m.name for m in frame.meshes],
                "children": [frame_tree(c) for c in frame.children]}
    return {"format": xf.format, "float_size": xf.float_size,
            "top_level": [o.type + (" " + o.name if o.name else "") for o in xf.objects],
            "frames": [frame_tree(f) for f in xf.frames()], "meshes": meshes,
            "animation_sets": [{"name": s.name, "animations": len(s.animations)} for s in xf.animation_sets()]}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args()
    for path in args.paths:
        try:
            print(json.dumps({"path": str(path), **summary(load(path))}, indent=1))
        except (OSError, XFileError, struct.error) as error:
            print(f"{path}: {error}", file=sys.stderr)
            raise SystemExit(1)


if __name__ == "__main__":
    main()
