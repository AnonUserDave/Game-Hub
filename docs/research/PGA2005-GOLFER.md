# PGA Tour 2005 golfer character: format findings

Status, 2026-10-13. The Tiger Woods character (`Golfer/chars/01char.xbx`) decodes to a
textured, skinned mesh, a 101-bone skeleton and usable swing, address and putt
animations. `Tools/decode_pga2005_golfer.py` writes these files to the ignored
`Library/Imported/pga2005/golfer/`.

Evidence labels:

- **Static**: Ghidra 12.1.2 decompiles and LLVM disassembly of Engine.dll, plus the
  vertex-shader text in TW2005.exe. Addresses use image base `0x10000000`.
- **Data**: arithmetic checks against the original files, such as sizes that sum
  exactly or every SKA blob ending on its last byte.
- **Visual**: our own Pillow re-rendering of the decoded data. This is not a
  runtime observation. The original game was never executed.

No runtime observations were made.

| Item | Result | Confidence |
| --- | --- | --- |
| SHOC container and Rdat decompression | Exact, from the engine's own routine | High (static, data) |
| Mesh positions, normals, UVs and strips | 5959 vertices, 6900 triangles | High (static, data, visual) |
| Skin weights (1–3 bones per vertex) | Palette → blend matrix → bones | High (static, visual in poses) |
| Skeleton (names, parents, bind) | 101 bones + synthetic `IG_Gball1` | High (data, visual) |
| Quaternion convention | Source stores the conjugate | High (data, visual) |
| Textures (DXT1/DXT3 in `.fxx`) | 23 used textures decode | High (data, visual) |
| Material → texture, decal layers | Base and decal layer with UV transform | Medium (data) |
| Animation (`motions.tbf` SKA) | All 1166 clips parse to exact size | High (static, data, visual) |
| Swing phase events (0 takeaway, 1 top, 2 impact) | Matches rendered poses | Medium (data, visual) |
| Absolute world size | Model is 2.04 units tall; scale to inches unresolved | Low to medium |
| Which file the game picks for "tiger" | 01 = HT.CHX, 02 = HS.CHX, both Tiger | Medium (01 is the default) |

## Inputs (SHA-256)

| File | SHA-256 |
| --- | --- |
| `engine/Executable/Engine.dll` | `94aa30bb645ea089fed6e98df0dce38d75c309e4531386cbe33c07f65bd19728` |
| `engine/Executable/TW2005.exe` | `2229ff0bc5ddbda3d892c45cf3ede1b4194bdb86ff90ca0396f2736ff34374f4` |
| `install/Golfer/chars/01char.xbx` | `22027e1429ea18ded93e0a26af6ba76d3a0e9896693b22cc36502d21585a6437` |
| `install/Golfer/CHARTEX/01alltex.fxx` | `1fbe9da117454afd7615e7d226b51d1f78c888171c452099d6410b0b5050f42b` |
| `install/Golfer/chars/motions.tbf` | `5306dde4bd9966ae6c3cef07b7ce778e57b5ce64fb8735c6a294837080d0160f` |

The Ghidra project is `Library/Research/ghidra-projects-golfer/golfer-engine` (Engine.dll
only). Decompiled pseudocode, the `DecompileTree.java` headless script and the extracted
`ID_SHADER_SKIN_FABRIC` source are in `Library/Research/golfer-ghidra/`. All of these are
ignored.

## Which character is Tiger Woods

- **Static.** `CGolferData::LoadPS2Character` (`0x101a1421`) calls `FUN_10223ae2`
  (`0x10223ae2`), which maps a name string to a model id. Both `tiger` and `tiger2` map
  to id 1, and `appleby` maps to 2. `FUN_1021d544` (`0x1021d544`) reads a byte from a
  per-model table at `0x10451eb1` (stride `0x1e8`) and loads
  `"%sChars\\%02dChar.xbx"` with that byte plus 1, after first loading
  `Chars\GlbChar.xbx`. The table lives in BSS and is filled at runtime, for example by
  `FUN_10252990` from user-profile data, so the file the id selects cannot be read
  statically.
- **Data.** The resource-list chunk in each char file keeps the exporter path. Files
  01 and 02 hold `…ERWOODS\EXPORTED\HT.CHX` and `…\HS.CHX`; the leading `TIG` is cut off
  in the file. Files 03–23 follow the roster: `APPLEBY\SA`, `BEGAY\NB`, `DALY\JD` and so
  on. Their textures and meshes carry the `ht`/`hs` prefixes, Tiger and Nike logos and a
  cap.
- **Choice.** The decoder uses **01**, Tiger with cap ("HT"). It is a Tiger model either
  way; whether 01 or 02 is Tiger's default outfit is still an open question.
- `.plr` player files are obfuscated (`TBFile::Decrypt`, Utils.dll `0x10018c90`) and
  were not decoded.

## Container: `.xbx` (SHOC)

The loader loop is at `0x1025d3e0` (static). FourCCs are stored byte-reversed.

| Chunk | Layout |
| --- | --- |
| `LRTC` (CTRL) | 16 bytes, skipped |
| `CNYS` (SYNC) | 8 bytes |
| `LLIF` (FILL) | u32 size, padding |
| `COHS` (SHOC) | u32 total size, 8 bytes, then a subtype FourCC at `+0x10` |
| SHOC/`SHDR` | `+0x14` u32 kind (1 = data resource), `+0x18` resource FourCC, `+0x1c` id, `+0x20` uncompressed size |
| SHOC/`SDAT` | raw resource bytes at `+0x40` (kind 1) |
| SHOC/`Rdat` | `+0x40` u32 uncompressed block size, compressed stream at `+0x44` |

01char holds `RPNS`, `RLst` (kind 2) and one `CHR ` resource. The CHR resource is
`0x4bb00` bytes, split across 28 Rdat blocks; the block sizes sum exactly to the SHDR
size (data).

**Rdat compression** (`0x1025d860`, static, exact). Each command is a big-endian u16 `w`.
The loop runs until the output reaches the declared size.

- `(w & 0x8800) == 0x8800` and `(w >> 12) & 7 == 0`: copy a literal run of `w & 0x7ff`
  bytes.
- `(w & 0x8800) == 0x8800`, otherwise: run-length fill. Distance is
  `((w >> 5) & 0x38) | ((w >> 12) & 7)` and length is `(w & 0xff) + 3`; the output
  repeats the byte at `out[-distance]`.
- Otherwise: length is `(w >> 12) & 7`. A 7 adds the next byte. The final length is
  that value plus 3, and the distance is `w & 0xfff`.
  - Bit 15 clear: forward copy from `out[-distance]`.
  - Bit 15 set: reversed copy, `out[p + k] = out[p - distance + 2 - k]`. This suits
    mirrored data.
- The engine copies 8- or 16-byte groups. Overlapping short forward copies never occur in
  the data, and the decoder rejects them.

## CHR resource (`FUN_102487c0` @ `0x102487c0`, static)

| Offset | Content |
| --- | --- |
| `0x00..0x24` | Type, 1.0, flags, five skeleton shape floats (copied to skeleton `+0x14c..0x160`) |
| `0x30` | u32 skin-block size (four copies); skin block at `0x40` |
| after skin | u32 attachment count (+12), then count × 48-byte records |
| next | u32 skeleton size (+12), then the skeleton block (`FUN_10254c90`) |
| next | Slider block (`FUN_1024eb50`): u32 count, u32, 8 bytes; Tiger has count 0 |
| next | Two u32 counts, morph-rule lists `FUN_10261d10`/`FUN_10261e90` (0 for Tiger); align 8 |
| next | Texture directory: u32 size, u32 size2, 8 bytes, `size` bytes of 88-byte records, 4 bytes |
| next | Face-blend TXR block (`FUN_10259f20`); not decoded |

### Skin block, version 4

Parsed by `0x102570d0`; offsets are made relative by `0x102573c0` (static).

| Int index | Meaning (01char value) |
| --- | --- |
| 0 | version = 4 |
| 2 | block size `0x44000` |
| 5 | bone count = 101 |
| `0xd` | Bind records: 101 × 32 bytes (quaternion xyzw, translation xyz, pad) |
| `0x12` | Offset of the model block (version 8) |
| `0x14` | Blend-matrix count = 964 |
| `0x15` | Blend records: 964 × 20 bytes |

A **blend record** is: u16 influence count (1–3), u16 bone0, u16 bone1, u16 bone2, then
f32 w0, w1, w2. Unused slots hold uninitialised exporter garbage (data). The first 101
records are rigid, one per bone. Weights sum to 1.

**Skinning model.** The static evidence is the `ID_SHADER_SKIN_FABRIC` text resource in
TW2005.exe, written for the "GoVSPrelitTextured_Xbox" shader:

- `mov a0.x, v0.w`: the vertex's 4th position component is a constant-register offset.
- `r1 = c[a0+3] + c[a0+2]*z + c[a0+1]*y + c[a0+0]*x`: one matrix per vertex, in row-vector
  form.
- `mul r10.xyz, v0.xyz, c[MODEL_SCALE].x`: position scale.
- `mul r9.xy, v9.xy, c[MODEL_SCALE].y`: UV scale.

The CPU computes the 964 blended matrices; model buffer 0 is a `0xf100` = 964 × 64-byte
runtime matrix buffer.

### Model block, version 8

Offsets are made relative by `0x102683c0` (static). The layout was mapped from data
plus the relocation list. The 32-bit header ints are:

| Int | Meaning |
| --- | --- |
| 2 | block size `0x3d140` |
| 4, 5 | Texture slots: 27 × 0x38 (name[16], …, f32 uv_transform[4] at `+0x28`) |
| 7, 8 | Material layers: 34 × i32 slot index |
| `0xb`, `0xd` | Buffers: 114 × (u32 offset, u32 size, u32 count, u32 type) |
| `0xe`, `0xf` | Buffer-index lists: 188 × i32 (−1 = empty morph slot) |
| `0x10`, `0x11` | Render nodes: 104 × 12 i32 |
| `0x14`, `0x15` | Visibility options: name[16], u32, i32 range index |
| `0x16`, `0x17` | Ranges: (count, start) into the node list |
| `0x1a`, `0x1b` | Node list (26 ids) |
| `0x1e`/`0x1f`, `0x20`/`0x21` | Shirt variant sets (`shirt`…`shirt3`), 20 texture names |
| `0x2a`, `0x2b` | Batch table: `0x202` u16 |
| byte `0xb0` | f32 position scale (1.0783) |

**Buffer types (data).** Vertex sizes are confirmed by `FUN_1022536f` (`0x1022536f`,
static); it adds 8 bytes for `0x10`, 8 for `0x20` and 4 for `0x40` in the shader path.

| Type | Content |
| --- | --- |
| `0x1808` | Matrix palette, u32 per entry: `hi16 − 0x500` = register (−4, −8, …, −96), `lo16 / 4` = blend-matrix index |
| `0x71` | Vertex stream, 18 bytes after a 0x40 header (see below) |
| `0x100031` | Vertex stream, 14 bytes (no UV) |
| `0x41` | UV stream, 4 bytes |
| `0x2` | u16 indices after a 0x40 header |
| `0x1030` | Face morph deltas; not exported |
| `0x700004` | Runtime blended-matrix buffer (no data) |

The 18-byte `0x71` vertex is s16 x, y, z, w(register), s16 nx, ny, nz, s16 u, v.
Decode positions as `s16 × scale / 32768`, normals as `s16 / 16384`, UVs as
`s16 / 4096` with a top-left origin. UVs observed range 0..4096.

**Render node** (12 ints):

| Field | Meaning |
| --- | --- |
| `[0]` | Start in the buffer-index list |
| `[1]` | Material-layer index |
| `[2]` | Batch count |
| `[3]` | Type: 1 skinned, 2 skinned + decal, 5 morph base, 6 morph base + decal, 9 morph target |
| `[11]` | u16 offset in the batch table |

**Batches.** Each batch record is u16 `0xffff`, palette count, vertex count, (morph
vertex count, types 5/6 only), index count. A batch first loads its palette entries into
registers; registers persist across the batches of a node. It then draws its vertex range
with its index range.

Per-node totals equal the buffer counts exactly for all 26 drawable nodes (data). The
decoder rejects any mismatch.

**Strips.** Indices are absolute D3D triangle strips with degenerates. Their winding is
not consistent: strip parity agrees with the vertex normals only about 51% of the time.
`BodyC::SetupGolferRenderStates` (`0x1019a579`, static) sets `D3DRS_CULLMODE` (`0x16`)
to 1 (NONE) and enables SRCALPHA/INVSRCALPHA blending. The decoder therefore orients
every triangle counter-clockwise about its stored normals; 3407 of 6900 were reordered.

**Materials (medium).** For node material `m`, the base texture is
`slots[layers[m]]`. Node types 2 and 6 add a decal layer from `slots[layers[m+1]]`. Each
layer's `uv_transform` (su, sv, ou, ov) feeds `oT = uv * (su, sv) + (ou, ov)`, as in the
shader's `TEXTURE_XFORM`. The decals are the Nike and TW logos on the cap and shirt and
the eye lens.

**Visibility sets (data).**

- `shadow`: node 0, a 268-vertex proxy.
- `GloveOn`: node 1, glove on the left hand.
- `GloveOff`: node 2, glove in the back pocket.
- `default`: 23 nodes.

`FUN_1021d544` passes `"Glove"`/`"GloveOff"` to `FUN_10246a60` (static).

### Skeleton block (`FUN_10254c90` @ `0x10254c90`, static)

The block is u32 count (101), 8 bytes, then 33-byte records: name[16], s8 parent,
f32[4]. The f32[4] is the local translation plus a 0 pad; it matches the skin bind
translations (data). Bone names follow the `IG_*` scheme:

- Root/Hips/spine: `IG_rig`, `IG_Root`, `IG_Hips`, then `BsSpine`→`UpSpine`.
- Face: neck, head and face bones (eyes, jaw, cheeks), plus `IG_Hat`.
- Hair: `IG_tail1-5`.
- Arms: arms, twist bones, fingers, and sleeve bones (`SlvF/B/H`).
- Legs: legs and trouser bones (`PntF/H/O`).
- Club: `IG_driver`, `IG_driver_Break`, `IG_driver_head`.

The loader is called with one extra slot. It appends `IG_Gball1` (parent 0, identity),
so animation clips carry 102 channels.

### Bind pose and quaternion convention

**Data and visual, high.** Chain the skin bind records with the conjugate of each stored
quaternion: `world_q = parent_q ⊗ conj(q_src)` and
`world_t = parent_t + rotate(parent_q, t)`. The result is a clean T-pose that wraps the
mesh: feet at y ≈ −0.94, hat bone at 0.95, hands at x = ±0.80. The mesh spans y −1.047…0.993
and x ±1.02. The raw quaternions produce a broken pose.

The model space is:

- +Y up.
- The character faces +Z (toes point +Z).
- The character's left is +X; the glove and left foot are at +X.

The decoder writes all quaternions in standard Hamilton form, so no conjugation is
needed downstream.

### Units and world placement

- The model is 2.04 units tall, feet to cap top (data).
- `SkeletonC::CreateWorldMatrix` (`0x101b262d`, static) builds
  `RotZ/RotX/RotY(IK) · Scale(−s, s, s) · T(IK) · RotY(heading) · T(position)`.
  The **X axis is mirrored** into the engine's left-handed space.
- `s = g · localScale`. `g` is computed at `0x101aebb7` as `(1·0.3937008 + 0.5) / 2 / 0.01`,
  which is **44.685 inches per unit** (static). `localScale` comes from the player record
  (`BodyC::SetOwner` `0x10198fcb` → `ScaleLocal`) and is runtime data.
- **Open question:** the authored scale. With `localScale = 1` the golfer would be 91 in
  tall. If 1 unit is 1 yard, the model is 1.865 m, which matches Tiger's 1.85 m plus cap.
  The game should normalise to the desired height. The manifest keeps the source units.

## Textures

Each `NNalltex.fxx` is headerless raw texture data (data). The CHR texture directory
holds 88-byte records:

- name[16].
- 4 × mip (u32 file offset, u16 size/16, u16 `0xffff`, u16, u16).
- u16 width, u16 height, u16 `0xffff`, u16 index.
- u8 Xbox D3DFORMAT, u8 mip count, u8, u8 log2w, u8 log2h, 3 bytes, then 8 bytes of
  zeros.

The formats are the Xbox codes `0x0c` = DXT1 and `0x0e` = DXT2/3 (`0x0f` = DXT5 is
supported but not seen). Decoded sizes match `w·h/2` and `w·h` exactly (data).
`render.ini`/`[GolferMaterial]` and the cube maps were not needed for base colour.

## Animation: `motions.tbf` and `.ska`

**Directory (data).** u32 count (1166), then per entry: u32 name length, the name, u32
offset, u32 size.

**Naming (inferred).**

- First letter: style. `t` is Tiger's signature set; `g` is generic.
- Second letter: club. `d` driver, `3`, `7`, `w` wedge, `p` putter.
- Then `l`.
- Then the action: `ful` full swing, `wag` waggle, `pre` pre-shot, `ptt` putt, `chp`
  chip, `pun` punch, `rx±` reactions, `crp` create-a-player.

**SKA layout.** Static sources: `FUN_10254000` relocation, `FUN_10253eb0` layout and
`FUN_102545f0` sampling. Header (0x100 bytes):

| Offset | Field |
| --- | --- |
| `+0x00` | Flags (bit 1 → 0x1f0-byte extra block) |
| `+0x0c` | s16 frame count |
| `+0x10` | f32 seconds per frame (1/60, 1/30 or 1/15) |
| `+0x1c` | Channel count |
| `+0x2c` | Descriptor bytes (16 per channel) |
| `+0x38`/`+0x3c`/`+0x40`/`+0x04` | Stream-B frames / stream-A bases / constants / stream-A deltas sizes |
| `+0x48` | s16 event count |
| `+0x4c`/`+0x50` | Translation frames / translation params sizes |
| `+0x54` | Data size |
| `+0x58`/`+0x5c`/`+0x60` | Stream-A / stream-B / constant counts |
| `+0x64` | Optional block size |
| `+0x90`/`+0x92` | Stream-B / stream-A per-frame strides |
| `+0xa0` | Club bone name |
| `+0xb0` | Clip name |

The body is: events (16 B each: u32 id, f32 seconds), the optional 0x1f0 block,
descriptors, then data aligned to 16, then two 2-bit axis bitfields (stream A, stream B).

**Descriptor flags.**

- 4: constant rotation.
- 8: animated rotation. With 0x20 it comes from stream A, otherwise stream B.
- 0x10: translation channel. It uses 24 bytes of params (min/max per axis) and 3 × u16
  per frame: `v = u/65535·(max−min)+min` (`0x102536e0`).

**Rotation decoding** (all static):

- Stream B (`0x102541c0`) and constants: per channel either an Euler triple u16 (z, y, x)
  or one u16 for a single axis. The 2-bit mode gives 1 = Z, 2 = X, 3 = Y.
- Angle is `raw · 2π / 65536`.
- The Euler quaternion is `qX(x) ⊗ qY(y) ⊗ qZ(z)`, from the x87 sequence of `0x102540e0`.
  The half-angle sine table index uses ±1303.797 = 16384/4π. Single-axis helpers are
  `0x102610c0` (Z), `0x10261160` (X) and `0x10261110` (Y).
- Stream A (`0x10254350`) is delta-coded: `angle = base_u16 − 16·byte` per frame, with
  bases in the same z, y, x order.
- Frames are slerped (`0x10260700`) and translations lerped (`0x10253680`).
- Channels without data keep the bind pose.

**Data validation.** All 1166 clips end exactly at the computed end of their bitfields.

- 1163 clips have 102 channels. `grass` and `point_at` have 101; `static` has 103.
- Frame rates: 662 clips at 15 fps, 486 at 30 and 18 at 60.

**Events (medium; data and visual).** Full-swing clips carry id 0 = takeaway, 1 = top of
backswing and 2 = impact, in seconds. For `tdlful50` at 60 fps:

| Phase | Frames |
| --- | --- |
| address | 0–8 |
| backswing | 8–48 |
| downswing | 48–63 |
| follow-through | 63–320 |

The rendered frames 48 and 63 show the top of the backswing and impact. Putt clips carry
only id 2 (impact).

Root (`IG_Root`) translation is ground-relative: the pelvis is about 0.99 units up and
z = −1.23. The rig origin is probably the ball (inferred).

## Output formats (`Library/Imported/pga2005/golfer/`)

All binary files are little-endian.

**`golfer_mesh.bin` (PGAGMSH1).**

| Offset | Field |
| --- | --- |
| 0 | `"PGAGMSH1"` |
| 8 | u32 version (1) |
| 12 | u32 vertex count |
| 16 | u32 index count |
| 20 | u32 submesh count |
| 24 | u32 bone count used |
| 28 | u32 flags (bit 0 = u32 indices) |
| 32 | f32 bbox min[3], max[3] |
| 56 | Vertices, 40 bytes each |
| then | Triangle-list indices (u16 unless flag), padded to 4 |
| then | Submeshes, 16 bytes each |

- Vertex (40 bytes): f32 pos[3], f32 normal[3], f32 uv[2], u8 joints[4], u8 weights[4]
  (unorm8, sum 255, at most 3 used).
- Submesh (16 bytes): u32 first_index, index_count, first_vertex, vertex_count.
- Positions are model units in bind pose, right-handed as stored. Triangles are CCW about
  the normals.
- Per-submesh texture, decal (with `uv_transform`), visibility `sets` and source node are
  listed in `golfer.json` → `mesh.submeshes`, in the same order.

**`skeleton.json`.** One entry per bone, 102 in all with `IG_Gball1` marked `synthetic`.
Fields: index, name, parent, `bind_local`/`bind_world` {rotation xyzw (Hamilton),
translation}, and a column-major `inverse_bind_matrix`. Skinning matrix:
`World(pose) · inverse_bind`.

**`clips/*.pgaclip` (PGAGCLP1).**

| Offset | Field |
| --- | --- |
| 0 | `"PGAGCLP1"` |
| 8 | u32 version |
| 12 | u32 bone count (102) |
| 16 | u32 frame count |
| 20 | f32 fps |
| 24 | u32 event count |
| 28 | u32 flags (3 = Hamilton rotations, parent-space translations) |
| 32 | events: (u32 id, f32 seconds) each |
| then | u8 channel flags per bone (1 animated rotation, 2 constant rotation, 4 translation), padded to 4 |
| then | Frames: frame × bone × 7 f32 (qx, qy, qz, qw, tx, ty, tz) |

Frames hold fully resolved local transforms. Bones without a channel use the bind
values. Play back at the stored fps.

**`golfer.json`.** Provenance and SHA-256 values, units, coordinate system, submesh
materials, visibility sets, shirt variants, texture table (source format and sizes),
clips (role, frames, fps, events, `phases_frames`) and memory totals.

**`textures/*.png`.** RGBA8 PNGs, top mip only. `--dds` also writes the source DXT blocks
as `.dds`; M1 Metal can sample BC1/BC2 directly, which avoids RGBA expansion.
`--all-textures` adds the shirt variants.

## Counts and memory (01char)

| Asset | Size |
| --- | --- |
| Mesh, all nodes | 5959 vertices, 6900 triangles |
| Mesh, default + GloveOn | 5656 vertices, 6352 triangles |
| Shadow proxy | 268 vertices, 512 triangles |
| `golfer_mesh.bin` | 280,232 bytes (238 KB vertices at 40 B + 41 KB u16 indices) |
| Textures used (23) | 340 KB as DXT1/DXT3; 2.43 MB as RGBA8. Largest 256×256: face, neck, pants ×2, arm, shirt front/back |
| Skeleton | 102 bones; skinning uses up to 101 matrices; ≤ 3 influences per vertex |

Six default clips, 2.44 MB of dense f32 in total:

| Clip | Frames | Size | Content |
| --- | --- | --- | --- |
| `tdlful50` | 321 @ 60 fps | 917 KB | Tiger driver full swing |
| `t7lful01` | 113 @ 30 fps | 323 KB | Tiger 7-iron |
| `twlful50` | 118 @ 30 fps | 337 KB | Tiger wedge |
| `tdlwag03` | 157 @ 30 fps | 449 KB | Address waggle |
| `tdlpre01` | 131 @ 15 fps | 374 KB | Pre-shot routine |
| `gplptt01` | 15 @ 15 fps | 43 KB | Generic putt |

These sizes suit the 8 GB M1 target. One golfer needs well under 1 MB of GPU geometry
and 0.34–2.4 MB of textures. Skinning 101 matrices on the CPU or GPU is trivial.

## Validation

- `Tests/test_pga2005_golfer.py`: 22 tests.
  - Synthetic fixtures cover Rdat literal, fill, copy, reverse copy and bounds; the
    container walk and payload size; the quaternion Euler order; SKA layout and sampling
    (constant, stream B, translation) and size rejection; clip and mesh binary round
    trips; palette registers and batch totals; texture directory and DXT1; skeleton
    inverse bind.
  - Real-media checks, skipped when the media are absent: 01 identity and counts, bind
    dimensions, all 1166 clips parse, the face texture decodes, and end-to-end `run`.
  - The full Python suite passed: 118 tests.
- `Library/Research/golfer-preview/` (visual, our renderer):
  - `bind_front.png` and `bind_side.png`: textured T-pose.
  - `tdlful50_{address,top,impact,finish}`: driver key poses.
  - `gplptt01_{address,impact,finish}`: putt.
  - Skinning, weights and animation decode look anatomically correct: no tearing,
    the glove is on the left hand, a right-handed swing, and the finish is on the lead
    foot.
- Generality (data): the same pipeline decodes 02, 28, 29, 31 and 32.
  - 04–12, 14–23, 26, 27 and 30 use the texture-slider block (`FUN_1024eb50` record
    sizes are sums over tables at `0x10399f58`, `0x10399f18` and `0x10399f48`), which is
    not implemented.
  - In 03, 13 and 25 the declared CHR size exceeds the Rdat data present in the file.
  - 24/25 (create-a-player) use an `FXFF` resource.

## Open questions

1. Which of 01 (HT) and 02 (HS) the roster uses by default. This needs the runtime table
   at `0x10451eb1`, which is filled from the front-end or create-a-player data.
2. The authored unit and the per-player `localScale` (`player+4 → +0x12f7`), i.e.
   absolute height in inches.
3. The golf club mesh (`CLB ` resource in `GlbChar.xbx`, 0xa1070 bytes) and attaching it
   to `IG_driver`.
4. Face morph targets (`0x1030` buffers, 13 per face node) and the TXR face-blend block.
5. The extra 0x1f0-byte SKA block (flags bit 1) and event ids 3/4 in putt clips.
6. Shader-faithful lighting (`render.ini [GolferMaterial]`, cube maps). Base colour only
   is exported.

## Reproduce

```sh
python3 Tools/decode_pga2005_golfer.py --preview            # Tiger 01, default clips
python3 Tools/decode_pga2005_golfer.py --clip tdlful50 --clip gplptt10 --dds --all-textures
python3 -m unittest Tests/test_pga2005_golfer.py
```

Ghidra headless (own project, Engine.dll only), using `Library/Research/golfer-ghidra/ghidra.sh`:

```sh
ghidra.sh golfer-engine import <Engine.dll> Noop.java               # once
ghidra.sh golfer-engine process Engine.dll DecompileTree.java <outdir> <depth> <addr...>
```
