# PGA Tour 2005 vegetation, placed objects and sky dome

Updated October 13, 2026. This is static analysis of the supplied Windows
media. Nothing from the original game was executed. The findings come from
direct Ghidra 12.1.2 headless runs and Apple LLVM `objdump`; they are **not REA
Evidence**. Decompiler text is not original source. Runtime behaviour was not
observed, so every "the engine does X" statement is a static reading with the
confidence given.

Tools: `Tools/pga2005_xfile.py` (DirectX `.x` parser),
`Tools/decode_pga2005_objects.py` (decoder), `Tests/test_pga2005_objects.py`.

## Inputs and method

| Input | SHA-256 |
| --- | --- |
| CourseData.dll | `36664435…832e82c` |
| Engine.dll | `94aa30bb…bd19728` |
| PBL.TCR / PBL.TCL | `3761d6f9…0e47` / `72160b50…cd13d` |
| install `CoursesRoot/skydome.TCL` | recorded in `sky.json` (`source_sha256`) |

Ghidra used two projects in the ignored `Library/Research/ghidra-projects-objects/`:

- a fresh CourseData.dll import;
- a copy of the shared Engine.dll database, renamed `pga2005-objects-engine`.
  The shared `ghidra-projects/pga2005-physics` project was not opened.

All requested functions decompiled. Outputs (pseudocode, instructions and
referenced data bytes) are in `Library/Research/ghidra-objects-{coursedata,coursedata-2,coursedata-3,engine,sky}`.
Each output directory has an `index.txt` that records the program SHA-256.

## 1. What the "objects" are

The only *instanced* objects in PBL and TUR are vegetation. Houses, rails,
benches, ball washers and the pro shop are ordinary terrain-patch geometry with
their own materials (for example `obj_objtex_miscballwasher_01_p101.tga`).
They already render with the terrain.

Patches can also carry "2D objects": `CRVegetation::CreateVertexBuffers_2DObjects`
(`0x101d71cc`) reads s16 count `desc+0x3d` and 24-byte sprite records. That
count is 0 in every PBL patch. Confidence: high.

## 2. Tree instances (per hole)

**Location.** Each patch descriptor (`0x136` bytes, TCR `hdr+0x104`) holds the
instance count, s16 at `+0x2f` (`tagPatch::Num3DTrees`, CourseData `0x10003000`).
The records start at payload offset u32 `+0x55`. The data reader is
`tagSurfaceStructureCompressed::GetSurfaceStructure` (`0x1000e660`); its consumer
is `CRVegetation::FillTreeStructs` (`0x101cbcb8`).

**24-byte record** (positions are relative to the patch's integer origin: i32
`desc+0x13` = X, `desc+0x4d` = Y, `desc+0x17` = Z):

| Offset | Field |
| --- | --- |
| 0, 2, 4 | s16 x, y, z position (ground point) |
| 6 | f32 scale |
| 10 | u8 rotation step; angle = step × float32(2π/5) (`0x3fa0d97c`, at `0x1002adb0`) |
| 11 | u8 object type (TCR object index) |
| 12–22 | s16 bounds min xyz, max xyz |

FillTreeStructs wraps the angle at 2π, then sets `index = ftol(angle / step) % 5`.
An exact x87/float32 replay shows that bytes 0–4 give indices 0–4 and byte 5
gives 0. Three PBL patches repeat their last 4 records after the counted ones;
the decoder uses the count, as the engine does.

**Hole.** An instance belongs to its patch, so it inherits
`PatchLayerInfoS` (`desc+0x61`). The same predicate that selects terrain
(selector `(0x420 & ~0x1f) | hole`) selects its trees, because FillTreeStructs
walks only the loaded patches. Every PBL tree lies in a base patch
(condition bits 0). Confidence: high.

**Transform.** `CRVegetation::ComputeTreeMatrix` (`0x101da420`) builds
`S(scale)·RotY(index·72°)` and then translates. In D3D row-vector form:
`x' = s(x cos a + z sin a) + X`, `y' = s·y + Y`, `z' = s(−x sin a + z cos a) + Z`.
Coordinates are raw left-handed inches in the same frame as `terrain.ghpc`.

**Authoring angle (data inference).** The stored bounds match the LOD0 mesh
rotated by a *continuous* angle inside the stored step's 72° sector (fitted
offsets are uniform over 0–72°). Under the quantised angle the engine draws,
they do not match. So the authoring tool kept a free angle and stored
`floor(angle/72°)`, while the game draws trees at most 72° from that angle.
The bounds are still used for collision and box tests. Confidence: medium-high.

**PBL counts** (45,063 instances; types 19/20 are the two bushes, 16,684 in
total):

| Hole | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Instances | 2597 | 2890 | 3193 | 2336 | 3090 | 2679 | 2265 | 2104 | 2037 |
| **Hole** | **10** | **11** | **12** | **13** | **14** | **15** | **16** | **17** | **18** |
| Instances | 2132 | 1968 | 2142 | 2483 | 2925 | 3374 | 3052 | 1919 | 1877 |

Each hole world repeats its surrounding scenery, so these totals overlap in
space. TUR decodes with the same code: 6 types (bushes and pines) and 24,827
instances.

## 3. Object types and models

The TCR has u16 `hdr+0x48` types (21 in PBL). Its 19-byte descriptor tables use
the material-descriptor layout: `+4` is the library object index and
`+18 >> 2` is the library number. `CourseDataManager::GetTreeLibraryInfo`
(`0x10009e30`) and `Get3DObjectBySize` (`0x10008600`) read them.

| TCR field | Content |
| --- | --- |
| `+0x6c` / `+0x74` / `+0xd0` / `+0x70` | in-TCR polyObject copies: large / medium / minor / small (billboard source); material IDs remapped to TCR materials |
| `+0x78` / `+0x88` | references to library tree meshes (LOD0 / LOD1) |
| `+0x90` | baked tree lighting (section 6) |

The TCL repeats the same tables with library-local texture IDs. It adds
`+0xd4`, the LOD2 tree mesh, which is used only when the library version
(`& 0x7fff`) is above 4. `+0x98` holds the architect info records with BMP
thumbnails.

**Tree meshes are embedded DirectX files.** `LibraryC::GetAnimTree` (`0x1000c170`),
`GetMedTreeMesh` (`0x1000c1d0`) and `GetMinorTreeMesh` (`0x1000c230`) each return
a `tagTreeMesh`:

- u32 offset of the mesh (always 12);
- u32 offset of an optional animation;
- f32 LOD scale;
- an embedded `xof 0303bin 0032` mesh (frames, skinned `Mesh`, `XSkinMeshHeader`,
  `SkinWeights`);
- optionally a second `.x` file holding an `AnimationSet`.

In PBL, LOD0 has 9–13 bones and one sway animation with 2 keys per track. LOD1
and LOD2 have no animation. `CourseDataManager::LoadAllTrees` (`0x10007f80`) loads
them.

The `.x` texture names map to TCR materials by
`CourseDataManager::TextureIdFromFilePath` (`0x10007e10`): a case-insensitive
match on the file stem, where the first match wins and a miss gives material 0.
In two PBL LOD0 meshes, one stray face has no texture name and therefore draws
with material 0 (`strproshop05.tga`); the decoder reproduces this.

**LOD scale.** `ComputeTreeMatrix` multiplies the scale only when tree flag bit 2
is clear. `CRVegetation::LoadHole` (`0x101cc863`) sets that bit for new-style
trees. PBL (library version 7) is new-style, so all LODs use the instance
scale. Confidence: high.

The PBL models are `obtree01`, `03`–`12` (no `02`), `b` texture variants of most
of these, and `obbush01/02`. Several share geometry and differ only in texture.
`obtree06/06b` are the layered Monterey-cypress shape. `obtree03/08` are tall
pines, about 60 ft at their usual scale.

## 4. Leaves are camera-facing cards

Materials whose texture section has flag `0x100000` are leaves (PBL `*_l.tga`
sections are `0x500008`). `CTreeSkinMesh::CreateCleanPoints` (`0x100112e0`)
collapses each leaf (2 triangles, 4 vertices) to a point:

- centre = the box centre of its first triangle;
- half size = half that triangle's Y extent;
- UV rectangle = (min u, min(1−v)) to (max u, max(1−v)).

`CRVegetation::RotateLeaves` (`0x101d3434`) then rebuilds every leaf each frame
as a camera-facing square: centre + half × R·(±1, ±1, 0), where R is the
camera's yaw and pitch.

- Each leaf adds one of 5 random twists, (rn() − 0.5)·π/3, set in the
  CRVegetation constructor `0x101ca579`.
- A small wind sway uses amplitude 0.015 and 10 random phases.
- Positions are prebuilt for the 5 instance rotations.

**V flip.** The leaf-only `1−v` was checked against the atlas
`pbl_06t_l.tga`: the flipped rectangles land exactly on its five leaf
clusters, and unflipped ones straddle them. New-style bark keeps the file UVs
(`TreeSkinnedMeshC::ChangeToTerrainVertex` `0x10014300` flips only old-style
trees).

Confidence: high for card geometry and UVs; medium for twist and sway constants.

## 5. LOD and billboard behaviour

`CRVegetation::FlagHighLowTrees` (`0x101cd96d`) picks the LOD for new-style
trees from a distance:

| Distance | Draw |
| --- | --- |
| ≤ LOD1 | LOD0 (skinned, can animate) |
| ≤ LOD2 | LOD1 |
| ≤ LOD3 | LOD2 |
| beyond LOD3 | LOD3 billboard |

`Camera::NextFrame` (`0x101927b3`) feeds `SetupLODBoundary` from CRenderSettings
`+0x12/+0x16/+0x1a/+0x1e`. `CRenderSettings::RestoreDefaults` (`0x10229013`) sets
the transition to 18000 and LOD1/2/3 to **540 / 1800 / 14400 in**
(15 / 50 / 400 yd). Registry and INI overrides were not traced. Confidence: medium.

**LOD3 billboard.** `CreateLowLODBuffers` (`0x101cb4ba`) and `TransformLowLODs`
(`0x101cce99`) build one quad per tree:

- centred on the instance;
- width = scale × the small polyObject's X extent;
- height from the instance Y to its stored bounds' max Y;
- turned about Y to face the camera (cylindrical);
- UV (0,0) at top-left to (1,1);
- textured with the `.x.tga` texture (section `0x400009`, DXT3 with a soft edge).

An unknown per-type factor, `CRData+0x24`, multiplies the width; it is assumed
to be 1.0.

**Render states.** `CRVegetation::SetupRenderStates` (`0x101d4946`):

- alpha test on, `ALPHAREF` 150, no blending;
- billboards are drawn without culling;
- the alpha reference is animated during LOD cross-fades
  (`RenderLowObjects` `0x101d6993`).

`[TreeAmbient]` from the active render INI is added to the tree vertex lighting.

## 6. Baked tree lighting (located, not exported)

`CRVegetation::LoadNewTreeLightingData` (`0x101d22df`) reads TCR `+0x90`, one
descriptor per type, through `CourseDataManager::GetLightingData` (`0x10008b00`).
Each record starts with 3 u32 sizes (2 sizes for libraries of version ≤ 4),
one per LOD. For all 63 PBL type/LOD pairs, a size equals exactly
**5 × the `.x` vertex count**: one brightness byte per vertex for each of the
5 rotations.

`FillDiffuseBuffers` (`0x101d2ab4`) turns a byte into grey
`min(255, 2·(byte + TreeAmbient))` on default settings, then applies the tree
contrast.

The engine's vertex order is unresolved. For bark, ascending original index
within each material fits best (mean neighbour difference 22–42 against 55–78
for random), which is not conclusive.

## 7. Sky dome

The `CRSkydome` constructor (`0x101bf69d`) and loader (`0x101bf995`) open
`Courses\Skydome.tcl` (the install's `CoursesRoot/skydome.TCL`) and take pan block
`SKYTYPE − 1`.

- **Pan blocks.** `LibraryC::GetPanBlock` (`0x1000c320`) reads the count at
  `hdr+0x68` (8) and the table at `+0x84`.
- **SKYTYPE.** It comes from the active `renderN.ini` `[SKY]` section, read at
  `0x101e88bc`, stored at CGlobalRenderSettings+4 and clamped to 1–8.
- **Geometry.** Each block is a polyObject dome: 307 vertices and 480 triangles,
  32-byte vertices (XYZ, ARGB, two UV sets) parsed by `0x101bf09d`. The dome is
  about 69,700 in in radius and spans Y −3,889 to +23,889 in.

| SKYTYPE (presets) | Block | Texture (1024×512 A8R8G8B8) |
| --- | --- | --- |
| 1 Clear (render1–5) | sunny.obj | sunny.tga |
| 2 Fair (render6–10) | sunset.obj | sunset.tga (the image is a fair cirrus sky) |
| 3 Partly cloudy (11–15) | partially_cloudy.obj | partly_cloudy.tga |
| 4 Cloudy (16–20) | cloudy.obj | cloudy.tga |
| 5 Foggy/overcast/light rain (21–35) | overcast.obj | overcast1.tga |
| 6 Heavy rain (36–40) | stormy.obj | stormy.tga + `overcast_overlay1` + `fogging_dk_grey` |
| 7, 8 (no preset) | sunrise.obj, fair.obj | evening.tga, fair.tga |

**Draw routine** (`0x101bfdb1`):

- Scale(SkyDome ScaleX, 1, ScaleZ).
- Translate by (camera.x − dome centre x, courseMinY + SkyDome YOffset,
  camera.z − dome centre z). courseMinY is `CRData+0x78`, set by
  `CRManager::SetCourseMinY`.
- No depth or lighting.
- Groups whose section flag has bit `0x1` alpha-blend.
- Groups with flag `0x1000` are cloud layers:
  - their UVs scroll by `[SkydomeAnimationControls] deltaU/V`;
  - for sky types 4–6 their UVs are rebuilt from the vertex direction (`asin`);
  - procedural clouds can replace them.

PBL's `[SkyDome]` is ScaleX 1, ScaleZ 1, YOffset 1. Dome UVs are already
top-left-origin (top v ≈ 0). The decoder also copies `cloudturb.dds`, `sun1.dds`,
`lflare1a/b.dds` and `DataImages/Game/Lensflare/*.dds`. It records each
`renderN.ini`'s SKYTYPE, fog, `SkydomeDiffuse` and lens-flare keys.

Confidence:

- geometry, textures and the block-index rule: high;
- placement: medium-high;
- cloud-layer behaviour: medium.

## 8. Panorama backdrop (exported, placement unverified)

The TCR also has 19 pan blocks: count `hdr+0x68`, table `+0x84`, read by
`CourseDataManager::GetPan` (`0x10007bc0`). They use the sky-dome polyObject
layout, with 32-byte vertices of XYZ, ARGB and two UV sets.

- **Geometry.** Their vertices are already world coordinates: vertical strips
  about 2,000 in tall at Y ≈ 82,900–85,300 around the course.
- **Textures.** Block 0 uses `pbl_bowl.tga` and `pbmtpiece1–8.tga`; blocks 1–18
  use `pan05/06` and `panend*`. All are DXT1/DXT3 with cut-out alpha.
- **Per-hole selection.** Each `[HOLE n]` section has `HolePanId` (PBL uses
  n) and `PanRotate` (0), read by `CourseInfoC::GetHolePanId` (`0x1000ab10`)
  and `GetPanRotation` (`0x1000abf0`).

The `CRPanorama` draw code was not analysed. Two points are therefore
unverified: that the block index equals `HolePanId`, and what the rotation and
`[PanEditing] offsetY=-83000` mean. The decoder exports the blocks and the INI
values only.

## Outputs, formats and API

```sh
python3 Tools/decode_pga2005_objects.py --course PBL          # course objects + sky + validation
python3 Tools/decode_pga2005_objects.py --course PBL --no-sky  # options: --no-course --no-validate --output --tcr --tcl --terrain --skydome
python3 Tools/pga2005_xfile.py file.x                          # JSON summary of any .x
```

API:

- `decode_course_objects(tcr, [tcl], out)`;
- `decode_sky(skydome_tcl, out, extras, presets, ini)`;
- `validate_floor(instances, ghpc[, materials])` and `validate_bounds(result, out)`;
- `read_ghom(bytes)`;
- `pga2005_xfile.parse(bytes).meshes()`, where each mesh offers `.render_arrays()`.

A PBL run takes about 17 s with validation on the M5; the sky takes about 7 s.

### Course output: `Library/Imported/pga2005/<COURSE>/objects/` (23 MB for PBL; sky 39 MB)

**`instances.json`**

- `holes["N"]` holds rows of
  `[type, x, y, z, rotation_index, scale, min_x, min_y, min_z, max_x, max_y, max_z, layer, patch]`
  in raw inches.
- It also carries the transform and the selection rule.

**`objects.json`**

- `types[k]`: model key and descriptors, plus the baked-lighting location.
- `models[key].lods[]`:
  - GHOM `mesh`, `lod_scale`;
  - `materials`: texture PNG/DDS, `kind` `mesh` or `leaf_card`, section flags,
    TCR material, fallback flag;
  - counts and animation summary.
- `models[key].billboard`: texture, `width_local`, x/y extents, UV range.
- `panoramas`: blocks (GHOM mesh, bounds, groups) and per-hole INI values.
- `textures[]`: alpha statistics against reference 150.
- `render_rules`, `evidence`, `validation`, `limitations`.

**`meshes/mesh-<sha16>.ghom`** (deduplicated) and
**`textures/library-L-texture-NNNN.{png,dds}`**.

### Sky output: `Library/Imported/pga2005/sky/`

- `sky.json`: `domes[]` with GHOM mesh, bounds, centre and groups (texture,
  flags, `alpha_blend`, `cloud_layer`), plus textures, `render_presets`,
  `course_ini` and `render_rules`.
- `meshes/` and `textures/`.

### GHOM v1 (little-endian)

**Header** (64 bytes):

| Offset | Field |
| --- | --- |
| 0 | `"GHOM"` |
| 4 | u32 version = 1 |
| 8 | u32 vertex count |
| 12 | u32 index count |
| 16 | u32 range count |
| 20 | u32 leaf-card count |
| 24 | u32 vertex stride = 36 |
| 28 | u32 flags (bit 0: normals valid; 0 for sky) |
| 32 | f32 bounds min[3] |
| 44 | f32 bounds max[3] |
| 56 | u32 reserved[2] |

**Then, in order:**

- **Vertices**, 36 bytes: f32 position[3], f32 normal[3], f32 uv[2]
  (top-left origin, repeat), u8 rgba[4].
- **Indices**: u32 triangle list, D3D clockwise front faces.
- **Ranges**: (u32 material, u32 first index, u32 count). The material indexes
  the JSON `materials` list for trees, or `groups` for sky.
- **Leaf cards**, 36 bytes: f32 centre[3], f32 half size, f32 uv_min[2] (top-left),
  f32 uv_max[2], u32 material.

Positions are model units for trees and raw inches for the sky. Apply the
instance transform first, then the terrain's native transform. Mirroring Z
reverses winding.

## Validation (PBL, M5, static data only)

**Floor.** Each instance's Y was compared with the nearest floor of its own hole
(selector `0x420|hole`) under its XZ:

- 45,063 of 45,063 instances have such a floor;
- median signed error −1.50 in;
- |error| p95 1.94 in, p99 1.99 in, max 2.01 in.

Instance Y is an integer about 1.5 in below the floor, consistent with
quantisation. A synthetic test checks that a different hole's floor is not
accepted.

**Surface under trees.**

| Surface | Instances |
| --- | ---: |
| `pbl_rough` | 41,829 |
| heavy rough | 1,924 |
| fairway | 481 |
| road | 397 |
| cliff | 216 |
| bunker | 98 |
| green | 47 |
| tee | 41 |
| ocean | 30 |

**Bounds.** Stored bounds were compared with the LOD0 mesh, fitted inside each
instance's 72° sector:

- median 0.81 in, p90 1.57 in, p99 1.98 in, max 6.2 in;
- at the quantised drawn angle: median 28 in.

This independently confirms the type→model mapping, scale, rotation sign and
origin decoding.

**TUR.** Floor max 2.0 in; bounds fit median 0.66 in.

**Textures.**

- Leaf textures are DXT1 with 1-bit alpha: 40–69 % of pixels fall below the
  reference.
- Billboards are DXT3 with 8 alpha levels: 28–80 % cut.
- Bark has no alpha.

**Other checks.**

- Side-view renders of decoded LOD0 meshes with leaf cards show coherent trees
  (broadleaf, pine, cypress, bush).
- All 138 supplied `.x` files parse (71 text, 67 binary), including `ball01.x`
  (2113 vertices, 1076 faces) and `tee01.x` (32/48).
- `Tests/test_pga2005_objects.py` has 16 tests (synthetic plus optional
  real-data), and all pass. The library, import and terrain suites also pass.

## Open questions

- The engine vertex order for baked tree lighting (TCR `+0x90`), and the
  active lighting slot (`CRVegetation+0x839`).
- The per-type billboard factor `CRData+0x24`, and the two distances at tree
  `+0x1a/+0x1e` (camera vs. LOD-boundary point) used with `FadeObjectModeE`.
- Registry/INI overrides of tree LOD distances (the protected `TW2005.exe` is the
  likely caller).
- Exporting skin weights and the LOD0 sway `AnimationSet` (both parse; not
  exported). `GetTreeBoneScale` reads `[Conditions] TreeAnimScale` (default 1).
- Procedural clouds (`ProceduralClouds`, `UpdateProcCloudsFromIni` `0x101e9b68`)
  and lens flare placement (render INI `[LensFlare] Position`) are not
  reconstructed.
- Why SKYTYPE 2 uses an image named `sunset.tga` (its content is a fair sky),
  and how the front end picks a render preset (and so a sky) for a round.
- Panorama placement and selection (`CRPanorama` draw code).
