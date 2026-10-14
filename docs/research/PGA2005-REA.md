# PGA Tour 2005 reverse-engineering ledger

Updated October 13, 2026. This records static observations from the supplied
Windows media. It does not establish a complete port, execution parity, or
performance. The original game has not been executed in this investigation.

## Identity and packaging

The root `TW2005.EXE` on the courses disc is 4,073,254 bytes with SHA-256
`2229ff0bc5ddbda3d892c45cf3ede1b4194bdb86ff90ca0396f2736ff34374f4`.
The executable extracted from the installer cabinet has the same SHA-256,
confirming the two copies are byte-identical. The readable
installed `TW2005.ini` declares `Version=v1.0 - 08.27.2004`.

Disc 1 uses InstallShield cabinets (`ISc(`), not Microsoft cabinets (`MSCF`).
`DATA1.HDR` indexes `DATA1.CAB` and the 660,305,920-byte `DATA2.CAB`.
Disc 2 also contains `DATA3.CAB`. A local build of unshield 1.6.2 successfully
listed the installer and extracted all 63 files in its `Executable` group,
including the engine DLLs, camera scripts, render settings, and game executable.
This was static extraction; no Windows installer was run.

The installed game is split across PE32 DLLs with extensive named exports:

| Module | Bytes | Named exports | SHA-256 |
| --- | ---: | ---: | --- |
| Engine.dll | 4,005,888 | 6,270 | `94aa30bb645ea089fed6e98df0dce38d75c309e4531386cbe33c07f65bd19728` |
| CourseData.dll | 294,912 | 966 | `36664435b88646e6b96d55f81573e1fdb73ee88e7f54762c4a723c693832e82c` |
| DXWrap.dll | 1,265,664 | 1,324 | `493a8aee88ef75d06d26b77802c20cd383a2ae6bf3c8b03fa5cb46a0c7696f3e` |
| Animator.dll | 274,432 | 927 | `2cfd96948be50d0fd0e9f682bdeb91605ad7df50b0a304e4e37dbce2126aa2f5` |
| Utils.dll | 307,200 | 997 | `2539899f22be0488d7b63783a988adc2b0a72f58d04984b955287fe257d85578` |

The names and RVAs above came from a standard-library PE export-table parser,
not a REA decompiler. `Library/Research/pga2005-dll-exports.json` is the complete
local inventory. Names establish interfaces, not their implementations.

`TW2005.EXE` has additional `stxt774` and `stxt371` sections and a small active
import table, with many other decorated symbol names present in its bytes.
This warrants investigating executable protection or a bootstrap before
assuming ordinary entry-point analysis is complete. No protection mechanism
or bypass has been established.

## Confirmed REA evidence

`inspect_pe_resources` succeeded without a deep analysis engine.
Evidence ID:
`ev_16339d15120a4fd5723dbd09d3d6eda3621702c68d31f203cb3bb36df7afe64c`.
Its target digest is the courses-disc executable digest above. It observed
PE32, machine 332 (`0x14c`), a complete resource tree of 40 resources across
91 directory entries, seven named `VERTEX_SHADER` resources, and a
`BINARY/DEFAULT_RENDER_STATES` resource. Shader resource names include
`ID_SHADER_BUMP`, `ID_SHADER_BEMDIV`, `ID_SHADER_BEMPERPIXEL`,
`ID_SHADER_SKIN_FABRIC`, `ID_SHADER_TEXCOORD4`, `ID_SH_CLS`, and `ID_SH_CLS_SS`.

The complete portable REA resource evidence was exported locally to
`Library/Research/pga2005-rea-evidence.json`. Payload hashes and exact file
ranges are in that bundle. The parser retains shader payloads as opaque bytes;
their names alone do not establish shader behavior or a working Metal version.

## Terrain and course format entry points

CourseData.dll uses image base `0x10000000`. These export-table addresses are
good seeds for static analysis:

| Address | Exported method | Reconstruction question |
| --- | --- | --- |
| `0x100090a0` | CourseDataManager::ReadHeaders | Course header and patch table layout |
| `0x1000d180` | MappedCourseC::ReadHeaders | Mapped resource header and descriptors |
| `0x1000d6b0` | tagPatch::FixupOffsets | Patch-relative pointers, geometry arrays |
| `0x1000e110` | TerrainVertexCompressed::GetTerrainVertex | Packed positions, normals, colors, UVs |
| `0x1000e660` | tagSurfaceStructureCompressed::GetSurfaceStructure | Packed surface records |
| `0x1000cd50` | MappedDataManagerC::LoadMemObject | Resource stream mapping/decompression |
| `0x1000e260` | TerrainVertexHelper::SizeOf | Expanded vertex record size |
| `0x1000e270` | TerrainVertexHelper::SizeOfCompressed | Packed vertex record size |

Export names also identify `TerrainPropsCoefficients`, texture descriptions,
`GetTerrainInfo`, `GetTextureDescriptor`, `LoadAPatch`, and `LibraryC`.
The `.TCR`/`.TCL` geometry and material interpretation needs actual function
analysis and validation against more than one course before a native importer
can claim coverage.

### Recovered course layout

Direct Ghidra 12.1.4 decompilation succeeded for all eight initial CourseData
functions and seven focused follow-ups. Target identity is the CourseData.dll
digest above. Local outputs are `Library/Research/ghidra-coursedata` and
`Library/Research/ghidra-coursedata-detail`; each includes target identity,
function address, inclusive body extent, recovered signature, and pseudocode.
The detail pass also records instructions and referenced data bytes. They are
static decompiler observations, not original source or execution traces.

`MappedCourseC::ReadHeaders` at `0x1000d180` reads an initial `0x324` bytes,
rejects version `0xffff`, then uses the little-endian u32 at header offset
`0x3e` as the complete header byte count and rereads that region.
`tagCourse::Fixup` at `0x1000d850` relocates 27 nonzero offsets beginning at
`0x6c`, then separate offsets at `0xfc`, `0x100`, `0x104`, and structured
course-information blocks.

`CourseDataManager::LoadAPatch` at `0x10008990` selects the patch table at
header offset `0x104` with a stride of `0x136` bytes. The count is u16 at
header offset `0x46`. The patch begins with a descriptor: source file offset
at `+0x00`, secondary location at `+0x04`, current data location at `+0x08`,
and payload byte count at `+0x0c`. `LoadMemObject` maps/reads this range and
then `tagPatch::FixupOffsets` converts its stored relative offsets for runtime
use. A new importer should retain bounded file offsets instead of reproducing
32-bit runtime pointers.

These relationships were independently checked against the PBL course bytes:

| PBL.TCR field | Observed value |
| --- | ---: |
| Version u16 at `0x00` | 7 |
| Header bytes u32 at `0x3e` | `0x785269` (7,885,417) |
| Patch count u16 at `0x46` | 6,943 |
| Patch table u32 at `0x104` | `0x577adf` |
| Table + count × `0x136` | `0x785269`, exactly the header boundary |
| First three payload byte counts | 187, 187, 187 |

`TerrainVertexCompressed::GetTerrainVertex` (`0x1000e110`) and independent
LLVM instruction decoding establish a 20-byte packed vertex:

| Byte offset | Interpretation |
| --- | --- |
| 0–2 | X: leading byte shifted 16, OR little-endian u16 from bytes 1–2 |
| 3–5 | Y with the same packing |
| 6–8 | Z with the same packing |
| 9–11 | R/G/B; expanded color is `0xffRRGGBB` |
| 12–15 | Float U |
| 16–19 | Float V |

For each packed coordinate, bit `0x80000` triggers sign extension by OR with
`0xfff00000`; the signed 32-bit result is then converted to float. The high
unused nibble should be validated rather than silently accepted. The expanded
vertex is 32 bytes: XYZ floats, ARGB u32, UV floats, and two trailing zero
floats. The uncompressed helper copies that full record unchanged.

`TerrainVertexCompressed::SetScales` (`0x1000de40`) and its call from
`CourseDataManager::Init` (`0x100095c0`; second overload `0x10009670`) give:

```
x = packedX / float(header + 0xdc) + float(header + 0x318)
y = packedY / float(header + 0xd8) + float(header + 0x31c)
z = packedZ / float(header + 0xdc) + float(header + 0x320)
u = storedU
v = storedV
```

The PBL header scales are 4.0 vertically and 3.3591599464416504 horizontally;
the origin is approximately (-287.99667, 82185.39844, 7781.46533). The third
scale argument comes from header `+0xf4`, but the observed SetScales routine
overwrites its UV multiplier with 1.0.

`tagPatch::GetNumPoints` (`0x10002f60`, independently disassembled) takes the
maximum of four **u16** counts at `+0x33`, `+0x35`, `+0x37`, and `+0x39`.
Those are separate fields, even where following zeroes make a u32 read appear
to work. The first PBL patch has three vertices and one face. The largest
observed patch (1793) has 14,835 vertices and 12,392 candidate faces.
Raw-byte relationships support vertices beginning at payload offset zero,
u16 triangle indices at patch `+0x45`, and count × 6 bytes ending at `+0x49`.
Material groups and per-group vertex bases require renderer/collision mesh
confirmation before interpreting every index as a global patch vertex index.

### Confirmed original mesh groups

The subsequent Engine.dll pass decompiled `CTerrainMesh::AddPatchToMesh`
(`0x102039b5`), `GetPolyPointCount` (`0x1020384a`), `CreateMesh`
(`0x10203dad`), and `CRTerrain::VBAddPolys_Terrain` (`0x101c4be2`). Outputs are
in `Library/Research/ghidra-terrainmesh`, with the same Engine.dll identity.
These independently agree on group-local vertices and triangle indices:

1. The primary `tagPolyObject` is at payload offset `u32(patch + 0x81)`.
2. Its group count is u32 at `polyObject + 0x18`.
3. Group records are 44 bytes and begin at `polyObject + 0x3d`.
4. Within each group record, signed i32 at `+4` is the triangle-index offset
   **relative to the polyObject**, u32 at `+8` is triangle count, signed i32 at
   `+12` is the vertex offset **relative to the polyObject**, u32 at `+16` is
   vertex count, and u32 at `+20` is terrain/material ID.
5. Indices are little-endian u16 triples local to that group's vertices. A
   combined mesh must add its accumulated vertex base to each group's indices.
6. The original routine checks that indices are below group vertex count and
   that each triangle has three distinct indices. Vertex compression is enabled
   when `(courseVersion & 0x7fff) >= 6`; older versions use 32-byte records.

For PBL patch 0, the polyObject begins at payload offset 82. Its sole group has
index offset -10 (payload 72), one triangle, vertex offset -82 (payload 0),
three vertices, and material ID 10. Negative relative offsets are legitimate;
the resolved range must still remain inside the payload.

A static validation applied this layout across **all 6,943 PBL patches** and
checked every group range, every triangle index, and degenerate triangles:
13,574 groups, 925,930 group vertices, 843,279 triangles, 181 material IDs,
and zero rejected ranges, invalid indices, or degenerate faces. The hash-bound
local report is `Library/Research/pga2005-pbl-mesh-layout-validation.json`.
All 925,930 vertices also decoded to finite XYZ/UV values, with zero nonzero
unused coordinate high nibbles. The second Engine.dll auto-analysis completed
in 142 seconds and all four selected functions decompiled successfully.
This is strong coverage for this course's primary mesh layout. Material texture
resolution has subsequently been recovered below. Alternate polyObjects, course life, animations, physics collision
flags, and other course versions remain separate obligations.

### Original TCL materials and textures

A further direct CourseData.dll pass recovered texture/material lookup methods;
the hash-bound outputs are `Library/Research/ghidra-materials`. The original
lookup chain is:

- TCR header `+0x80` points to 19-byte material descriptors. A mesh material ID
  selects one; u16 at descriptor `+4` selects the library texture index, and
  descriptor byte `+18 >> 2` selects the library number.
- TCR header `+0x5e` is its library count; the GUID list starts at `+0x10c`.
  Each supplied TCL must match the referenced GUID at TCL bytes 2–17.
- TCL header u16 `+0x50` is its texture count. Its `+0x80` points to 19-byte
  image descriptors, and `+0x7c` points to 19-byte original-name descriptors.
  Image descriptor u32 `+0` and `+12` identify exact file offset and byte count.
- Image payloads in the observed libraries contain a little-endian u32 DDS
  length followed by that exact DDS. The original names can end in `.tga`,
  although the stored image is DDS.
- TCL header `+0xe4` points to 83-byte texture information sections. A section
  has u16 surface count at `+0x4d` and a header-relative surface-array offset
  at `+0x4f`. Each surface record is 68 bytes: ten float coefficients, u32 flags
  at `+0x28`, u16 lie-graphic index at `+0x2c`, and original text at `+0x2e`.

The relevant observed methods are `CourseDataManager::GetTextureInfo`
(`0x10009940`), `LibraryC::GetFullTextureInfo` (`0x1000c560`),
`GetTextureDescriptor` (`0x1000c7d0`), `GetTexture` (`0x1000c070`),
`GetTextureName` (`0x1000bfe0`), `GetTerrainInfo` (`0x1000c5a0`),
`TerrainPropsInfo` (`0x10009c50`), and `TerrainPropsLieText` (`0x10009de0`).
Original out-of-range texture lookup falls back to index zero; the new decoder
rejects unexpected indices to avoid silently assigning an incorrect material.

`Tools/decode_pga2005_library.py` applies these layouts with GUID, file/header
range, coefficient-finiteness, DDS length, and source mesh-report SHA checks.
It preserves original DDS bytes and writes PNG versions of their base levels.
PBL's 181 used mesh materials all resolved to 181 original textures; Turnberry's
81 used materials likewise resolved to 81 textures. PBL material 2 is
`pbl_rough.tga` (1024 × 1024) with original surface labels including `Md Rough`,
`Lt Rough`, and `Dp Rough`; material 10 resolves to `pbl_ocean.tga` (512 × 512).
PBL includes 175 DXT1 images and six DXT3 images among its used materials.

The generated local `Library/Imported/pga2005/{PBL,TUR}/materials.json` uses
schema version 1. Its `materials` array has integer `id`, `name`,
`library_index`, `texture_index`, relative PNG `texture`, relative
`original_dds`, dimensions, `surface_types`, and descriptor provenance. Surface
entries preserve the original label, flags, ten coefficient values, graphic
index, and file offset. The `textures` array records original DDS and decoded
RGBA SHA-256 values and source descriptor ranges. Relative image paths resolve
against the directory containing `materials.json`; the original UVs require
repeat addressing.

An independent Pillow DDS decode was compared with eight generated PNGs,
covering six DXT1 and two DXT3 textures, including both 1024 × 1024 rough images
and alpha-bearing green/fringe textures. All RGBA bytes matched exactly:
zero differing channels across 10,754,048 channel values. Hashes and Pillow
version are retained in `Library/Research/pga2005-dds-pillow-comparison.json`.
This validates image conversion against an independent decoder; original GPU
filtering, shader effects, alpha compositing, and screenshots remain separate.

### Authoritative original hole coordinates and units

The original game reads authored tees and pins directly from TCR, rather than
using the raw INI coordinate lists for those choices. `CHole::ReadHoleInfo`
(`0x1018249b`) loads the course-information block pointed to by TCR header
`+0xe0`. The block begins with its u32 byte size and has a u16 hole count at
`+0x10`. For one-based hole N, the record is at
`infoBlock + u32(infoBlock + 0x0e + N*4)`. Record fields are:

| Offset | Observed data |
| --- | --- |
| `+0` | u16 par |
| `+2` | Stored u16 matching legacy yardage in source INI |
| `+4` | u16 handicap |
| `+6/+8/+10` | u16 tee/aim-point/pin counts |
| `+0x10/+0x14/+0x18` | Tee/aim-point/pin array offsets relative to infoBlock |

Each position is three float32 values. `CHole::TeePosition` (`0x1017fd5c`),
`PinPosition` (`0x1017ff55`), and Utils.dll `APosition` construction/update
(`0x10010560`/`0x10010940`) establish that the authored XYZ values are copied
without scaling. `Tools/decode_pga2005_holes.py` validates block and array
bounds and emits those exact native values. PBL yields 18 holes, 90 tee choices,
and 180 pin choices in `Library/Imported/pga2005/PBL/holes.json`.

That file uses schema version 1 and records source TCR/optional INI SHA-256,
block provenance, and `holes[{number,par,handicap,legacy_yardage,tee_count,
pin_count,tees,pins,aim_points}]`. Each point has zero-based `index`, unchanged
`xyz_raw`, and `source_offset`. Optional original INI yardage overrides are
kept separately as `yardages_by_tee`.

For all 270 PBL tee/pin points, a static numerical comparison confirmed
`TCR XYZ ≈ (INI.x*12-origin.x, INI.y*12, INI.z*12-origin.z)` with a maximum
absolute difference of 0.006625 engine units, consistent with INI decimal
rounding. The emitted coordinates nevertheless come directly from TCR.

Units have stronger support than the earlier physical-constant inference:
LLVM instructions for `CHole::TotalYards` (`0x1017fc76`) call the imported
Utils `APosition::DistanceFrom`, accumulate path distance, divide by float32
**36.0** at `0x102d67d8` (bytes `00001042`), add **0.5**, and convert to integer.
Thus native spatial units are inches relative to its named yardage result.
The independent assembly is in `Library/Research/engine-totalyards-llvm.asm.txt`.
The Ghidra C approximation omits parts of these x87 operations because the
external function return type was unresolved; the instruction evidence is
required for this conclusion.

Six new parser tests cover correct descriptor/provenance chains, mismatching
GUIDs, texture range escapes, inconsistent DDS lengths, unchanged native hole
positions, and hole pointers escaping the information block. The full Python
suite passes all 18 tests.

## Ball physics entry points

Engine.dll also uses image base `0x10000000`:

| Address | Exported method |
| --- | --- |
| `0x101f5b7d` | CBallFlight::Flying |
| `0x101f6112` | CBallFlight::RollingAndSlipping |
| `0x101f6742` | CBallFlight::PureRolling |
| `0x101f4e6a` | CBallFlight::Impact |
| `0x101f795f` | CBallFlight::BallLoop |
| `0x101f8696` | CBallFlight::BallLoopUpdatePos |
| `0x101f758b` | CBallFlight::StartBall |

Other named methods cover tree, terrain, object, and cup collisions,
coefficient adjustment, ball serialization, and flight FIFO records. Flight
constants, units, integrator steps, lie coefficients, and collision response
must be recovered and validated; a generic golf simulation is not evidence of
PGA2005 parity.

### Recovered physics structure

Direct Ghidra decompilation succeeded for all seven initial physics functions
in Engine.dll. `Library/Research/ghidra-physics` contains 790 lines of
pseudocode plus complete function instruction dumps and local provenance.
Whole-program Engine.dll auto-analysis hit its 180-second budget, despite all
seven selected function decompilations completing. The import log also reports
an unrelated invalid PNG signature and unresolved reads in a different
function (`0x1023540c`). Whole-module coverage is therefore partial; successful
selected pseudocode is not proof that every function or resource was analyzed.
`Library/Research/pga2005-physics-constants.json` records referenced constants
as original byte hex with both float32 and float64 interpretations; consumers
must select the width used by each instruction, not the more plausible number.

`BallLoopUpdatePos` at `0x101f8696` dispatches on byte `this+0x378`: 2 invokes
flight, 4 rolling/slipping, 8 pure rolling, and other values stop this update.
It then copies old XYZ position and adds per-tick velocity. Relevant double
fields are velocity XYZ at `+0x30d/+0x315/+0x31d`, position XYZ at
`+0x32d/+0x335/+0x33d`, and angular velocity XYZ at `+0x2f5/+0x2fd/+0x305`.

`StartBall` at `0x101f758b` computes `fps/60` and `60/fps` from the integer
field at `+0x7f`, then sets its gravity increment to
`0.1071700006723404 * (60/fps)^2`. The base constant's exact f64 bytes are
`000000407e6fbb3f` at address `0x102d97c8`. A radius-like constant
`0.8399999737739563` at `0x102d9758` and its squared value
`0.7056000232696533` at `0x102d9760` participate in rolling calculations.
The values are consistent with inches and a roughly 60 Hz reference update,
but that unit interpretation remains an inference pending caller/reference
validation.

Flight at `0x101f5b7d` computes velocity relative to horizontal wind, speed
dependent drag, lift from the cross product with angular velocity, vertical
gravity, and spin decay. Wind is disabled below an 18-unit height difference;
the observed wind multiplier is approximately 0.6. Spin decay includes a base
approximately 0.003 and an additional headwind-dependent term. The complete
coefficient values remain in the hash-bound local constants report rather
than being replaced with generic aerodynamic coefficients.

Rolling routines obtain terrain coefficients through
`CourseDataManager::TerrainPropsCoefficients`, normalize the terrain normal,
project velocity onto its tangent, and apply lie/terrain flags to friction.
Rolling/slipping switches to pure rolling when linear speed is at most angular
speed × the radius-like constant. Pure rolling also adjusts direction on a
slope and stops when the remaining speed is below the per-step resistance.

`BallLoop` at `0x101f795f` updates position, queries terrain height, checks
valid terrain bounds, then processes tree, miscellaneous, cup, and terrain
collisions before recording the ball FIFO. Impact, coefficients, terrain flags,
cup behavior, zero-vector edge cases, and floating-point rounding still need
structured recovery and reference validation. Decompiled x87 arithmetic must
not be assumed bit-identical to a new ARM64 double implementation.

## Original visual data

The `Data-Golfball` cabinet group contains text DirectX `.x` meshes, DDS
textures, logo archives, and readable material configuration. Its `ball01.x`
starts with `xof 0303txt 0032`, providing a format-aware import path independent
of proprietary course mesh decoding. `Golfball.ini` specifies scale
`0.02479542`, bump scale `1.64`, RGB specular `(0.2, 0.2, 0.16)`, specular power
`4`, and ambient light `0.96`. These are observations of configuration values;
their renderer interpretation still needs confirmation.

`render.ini` defines eight light entries plus a self-shadow light, fog start
`800` and end `64000`, texture filter choices, and bump scale. The course media
also contains original DDS/TGA assets and course-specific INIs. These data can
guide style preservation; native 2560 × 1600 output and upgraded filtering are
new renderer work that needs visual comparisons and frame-time measurement.

## Analysis tools and reproducibility

REA MCP 6.4.0 initially had no configured native provider. Hopper was absent,
and Ghidra lacked both Java and its Apple Silicon native decompiler.
The user authorized installing Ghidra/Hopper when useful. Ghidra and its JDK
are installed portably under ignored `.tools`; no global REA configuration or
Apple license acceptance is needed for this analysis workflow.

Official downloads were resolved from their release metadata:

- [Ghidra 12.1.4 release](https://github.com/NationalSecurityAgency/ghidra/releases/tag/Ghidra_12.1.4_build):
  `ghidra_12.1.4_PUBLIC_20260921.zip`, 569,649,598 bytes, verified SHA-256
  `ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db`.
- [Eclipse Temurin JDK 21 releases](https://adoptium.net/temurin/releases?version=21&os=mac&arch=aarch64):
  `OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.12.1_1.tar.gz`, 200,073,404 bytes,
  verified SHA-256
  `3623232f33a9c3baadf304480b2535f9a3cba8a58d42ecbb438ba267315d9998`.
- [Unshield 1.6.2 source](https://github.com/twogood/unshield/tree/1.6.2):
  built locally with the installed Apple clang and explicit SDK; cabinet
  extraction validated the stored per-file checksums.

The Ghidra archive supplies a Linux native decompiler. Its shipped C++
sources were built successfully for macOS arm64 with the installed direct
clang++ executable and explicit SDK. The resulting `decompile` is confirmed
as Mach-O arm64. A task-local environment passes
`GHIDRA_INSTALL_DIR` and `JAVA_HOME` to a new REA process.
`Tools/analyze_pga2005_rea.py` uses the public MCP stdio protocol to retain one
database per DLL, collect bounded course/physics dossiers, export complete
evidence, and close the target. Its outputs are research artifacts, not
compilable original source.

Provider readiness passes after installation, but the actual REA deep launch
is blocked by its Darwin process-ownership helper. REA 6.4.0 compiles that
helper through the hard-coded `/usr/bin/xcrun`, which fails on this machine
because the Xcode license has not been accepted. The same error persisted
after one retry outside the sandbox. The helper and ownership checks have
not been modified or bypassed within REA.

The supported fallback is a separate direct Ghidra headless Java invocation,
using public GhidraScript APIs through `Tools/ExportGameFunctions.java` and
`Tools/analyze_pga2005_ghidra.py`. This process imports the DLL as
`x86:LE:32:default:windows`, performs static analysis, records target SHA-256
and command provenance, and closes/deletes its owned temporary project.
Those outputs are explicitly direct Ghidra observations, **not REA Evidence**.
User-home and Java temporary writes are isolated within the project's `.tools`.
The mesh follow-up retained its local database in
`Library/Research/ghidra-projects/pga2005-physics`. Further exact-address
requests can add `--resume-project --keep-project` to the same Engine.dll
profile to avoid a repeat import. The export script checks the imported
database's executable SHA-256 against the requested file before accepting
results. Ghidra databases contain original bytes and must remain local/ignored.

## Remaining verification

- Alternate course mesh layers, shader/material rendering rules, and additional
  course/library versions; primary group geometry, texture linkage, and authored
  hole coordinates are now recovered for PBL and original textures for TUR.
- Physics coefficient schemas, collision/cup behavior, reliable caller units,
  edge cases, and reference trajectories; initial control flow/constants are
  now recovered.
- Native asset importer that validates indices, lengths, and source hashes.
- Representative reference screenshots and ball trajectories from an
  authorized reference runtime or original hardware.
- Native renderer comparisons, 2560 × 1600 output, and measured frame times.
- Keyboard/trackpad and physical Xbox controller validation.
- Save/load, all courses, game modes, animations, audio, and complete gameplay.

A native rewrite necessarily has different executable bytes and graphics API
code from a Windows x86 executable. Parity should be expressed as explicit
behavior, data, visuals, and performance obligations with evidence; byte
identity can be retained for unmodified source assets.
