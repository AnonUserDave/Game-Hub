# THPS2 supplied original scene reconstruction

2026-10-13. Static source analysis, offline preparation and native scene construction were performed on the son's **M5 Pro / 24 GB development machine**. The mandatory target remains the owner's M1 Air / 8 GB / 2560 × 1600. **THPS2 is not a completed rewrite or a playable hub module.** No original executable, emulator, Wine or Rosetta was run. No source-game comparison or M1 acceptance follows from this checkpoint.

## Source identity and content coverage

The supplied `Tony_Hawks_Pro_Skater_2_Win_ISO_EN.zip` is 543,723,047 bytes, SHA-256 `fc3fcde2565e284e62a25925e9a1586df3621b601fc3253dfadcb4c089e329a8`. Its original `ALL.PKR` is 197,886,331 bytes, SHA-256 `7e2ae173577c41598dc644824b52f7eaf9664ea478e177a8703f77c0185207da`. The pre-existing PKR2 reader recovers 3,771 original assets. Original bytes and derived PNG/JSON remain ignored beneath `Library/SourceMedia/thps2/` and `Library/Imported/thps2/`.

[The compact content receipt](evidence/thps2-level-content.json) records exact per-layer and TRG identities, structural counts, and source files whose layouts remain unqualified. Source coverage is not playable content coverage. The scene selector does not silently exchange main level data for the smaller `_2` variants.

`Tools/decode_thps2.py --all-levels` prepares the eight career environments and two secret environments from the supplied files:

| Original environment | Scene / original texture library / object set | Native scene triangles / material groups |
| --- | --- | --- |
| Hangar | `SKHAN` / `SKHAN_L` / `SKHAN_O` | 4,706 / 127 |
| School II | `SKSL2` / `SKSL2_L` / `SKSL2_O` | 9,888 / 220 |
| New York | `SKNY` / `SKNY_L` / `SKNY_O` | 8,420 / 194 |
| Marseille | `SKMAR` / `SKMAR_L` / `SKMAR_O` | 6,080 / 191 |
| Venice Beach | `SKVEN` / `SKVEN_L` / `SKVEN_O` | 9,332 / 169 |
| Skatestreet | `SKSS` / `SKSS_L` / `SKSS_O` | 5,891 / 135 |
| Philadelphia | `SKPH` / `SKPH_L` / `SKPH_O` | 8,048 / 196 |
| Bullring | `SKBUL` / `SKBUL_L` / `SKBUL_O` | 6,577 / 109 |
| Chopper Drop | `SKB1` (contains its own textures) / `SKB1_O` | 1,267 / 66 |
| Skate Heaven | `SKHVN` / `SKHVN_L` / `SKHVN_O` | 8,039 / 93 |

These pairings were checked against the actual TRG startup spool/object-file strings and hexadecimal `newtex/` BMP IDs. In particular, `SKSCHL` is separate legacy content; it does not resolve School II's supplied texture IDs. `SKSL2` resolves those IDs. Chopper Drop's startup does **not** spool `SKB1_L`; using that unrelated texture library would be incorrect. Other actor spools, such as School II's `C_Kart`, New York's `C_Taxi`/`C_Cable`, Marseille's `C_Mar`, Philadelphia's `C_Bus` and Bullring's `C_Bull`, remain outside these static scene layers and must be reconstructed for the game.

The current native builder creates both original paletted and supplied PC BMP versions of all ten packages, with no unresolved visible texture IDs. This is **SceneKit object/buffer construction**, not rendered-pixel comparison. An isolated native probe found no available default Metal device; no screenshot or frame-rate result was produced. The material-group counts are submission structure, not measured FPS or sustained M1 performance.

## Qualified PSX v4 records

The independent Python and Swift readers accept the supplied `(4,2)` PSX header only. Both bound source size to 64 MiB, count tables, independent model extents, vertex/plane references, face lengths, texture extents and pixel expansion. Repeated model spans cannot multiply allocation. The Swift loader retains a mapped compact source buffer and only small record/face-offset tables. It does not expand every level or keep a whole-library cache.

- Placements are 36-byte records; all flags, unknown fields, model indices and RGB-pointer values are retained. Coordinates are signed **s7.24** integers.
- Model vertices are signed **s3.12** values with their fourth word retained. Planes retain their raw signed components/fourth word. Model flags, radius, six bounds in source `max,min` order and the final unknown word remain accessible.
- Source world position is exactly `placement / 16777216 + vertex / 4096`. This is an original fixed-point coordinate space; a physical meter/foot interpretation has not been established.
- Faces retain raw base flags, four source indices, flat RGB/GPU-command or gouraud color-index bytes, source plane index, surface flags, indexed texture reference, four byte UV pairs and all extension bytes. Invisible polygons remain in the loader for future source collision reconstruction; only the visual builder omits base flag `0x80`.
- The tagged `RGBs` palette is **not always 256 entries**. Hangar's level has 1,024 bytes, while its object set has 456 bytes. References are checked against the actual palette length.
- Tagged chunks, including subdivision/culling records, remain source addressed. The blockmap tag `0x0a` is decoded as its original bounds, grid dimensions and cell object memberships. Hangar has a 20 × 20 grid and 1,805 object references. Native grid queries enumerate source object IDs; they are not a collision solver or proof of original edge handling.
- Texture tables are indexed; duplicate texture IDs are valid. The native builder prefers the exact index where the source tables agree, otherwise resolves IDs. It merges same-ID candidates only when their decoded image bytes/dimensions agree. A conflicting same-ID image is rejected until engine selection semantics are reconstructed. Philadelphia has one byte-identical image alias whose raw texture flags differ; both source descriptors are retained, and those flags' shader semantics remain unqualified.
- Texture **row width** pads to four pixels (4 bpp) or two (8 bpp). **Height is not rounded.** Actual `ITEMS.PSX` 128 × 42 textures and `SKWARE_L.PSX` 54 × 54 textures contradict the public converter's rounded-height assumption.
- Palette pixels decode low nibble first. Palette value zero is transparent in the development image. Other values are opaque, with raw bit 15 retained in source palettes. Original PS1 STP/blend rules are not reconstructed.

Hangar's main source SHA-256 is `56cc7f02ac45e0772621e6d9866fda4562e8a71669a0dee826bd93512fe9e6f8`: 470 placements, 471 models, 5,368 vertices and 3,231 faces. Its texture library SHA-256 is `d4b3c2ea67f95a00faa79076709381c34da73b9cb18dff069ffeca70e9b1a64a`: 105 textures, 64 four-bit palettes and 39 eight-bit palettes. Geometry and library texture-table order differ despite sharing IDs; array-position pairing is wrong. The object set adds 20 placements and 640 faces.

The offline corpus reader currently qualifies 263 of 282 PSX files. Nineteen other sources fail explicit extent/layout checks; the evidence receipt lists them and their hashes. This is not a claim of complete actor, animation, editor or legacy-content coverage. The ten selected environment packages above pass their individual parsers.

## Qualified TRG v2 records

The supplied `data/SYMBOLS.TDF` is a 31,865-byte original symbol-definition file, SHA-256 `decfecaf33159458d1d13671d9c9dedb7c63e4b0798272d963dc2d23e9ef7190`. It independently confirms the node IDs, `SpoolIn=126`, `SetRestart=140`, `SetObjFile=142`, `SetGameLevel=147`, and that type 15 is the two-player autoexec. These are source declarations, not an inference from public parser names. The file also names VM commands and variables; declaration identities do not establish their runtime implementation. Its original contents remain ignored.

All 32 supplied TRG files pass bounded node-table framing, totaling 20,220 nodes. Tables begin directly after the `_TRG`, version-2 and node-count header. Node offsets are ordered, independent extents; the final record is exactly the two-byte type-255 terminator. Hangar's TRG SHA-256 is `3946dc1ef6c7393512de65153cdbeea147f1433bc2976ba3d7c944c60cf7ae81`, with 713 nodes, including 14 restarts and 181 rail points.

The Python preparer and native loader retain raw node payloads and decode linked-node arrays, restart/point/rail positions in **s19.12**, parameter words, restart names, object checksums and camera records. Original names such as `Start` remain local media, not checked-in extracted listings. Restart angle/parameter semantics remain unqualified; the renderer does not use them as an invented gameplay camera.

The Python preparer additionally frames known **command-list** opcodes on autoexec, command-point and restart nodes. It records startup spool filenames, object-file selections, camera/fog words and career conditions. This is static framing, not script execution. Unknown opcodes stop decoding at their source address. The public disassembler's cheat-restart string-list termination assumption fails on supplied records; opcode 2 therefore remains explicitly unqualified. Arbitrary 16-bit payload words are never scanned as opcodes. Baddy scripts and their expression VM are still undecoded.

## Native scene and fidelity boundaries

`THPS2OriginalLevel.swift` hash-checks each selected source layer/TRG against the local preparation receipt and fences all original/prepared paths. `THPS2OriginalBlockMap.swift` retains bounded original spatial membership. `THPS2OriginalScene.swift` builds a scene from original placements and source face triangles, batches by source texture/flat transparency, and applies only the documented display conversion `(x,-y,z)`. Source integers remain unchanged.

Original normals, UVs and per-corner baked colors reach native geometry. The display reflects source Y: the sampled horizontal source normals point toward negative Y, and most source index cross products oppose their stored plane normal. The original raster/GPU quad diagonal and flags remain recorded; exact backface, subdivision, culling, ordering-table, blend, saturation and draw-order behavior require engine reconstruction and original-frame comparison. Flat half transparency and 128-neutral textured color modulation are development rendering interpretations, not fidelity-qualified shaders. PC BMPs are a separate explicit choice; no cross-platform replacement is silently substituted for the original paletted library.

There is no generated skatepark, no approximate generic skating model and no playable THPS2 registry entry. Static object-set placements do not execute original visibility pulses, moving vehicles, breakable objects, pickups or goals. Source skating locomotion/collision, jumps/grinds/manuals/tricks/combos, cameras, animation rigs and clips, audio/music, career/multiplayer/editor modes and saves remain unfinished.

## Verification and next concrete work

```sh
python3 Tools/decode_thps2.py
python3 Tools/decode_thps2.py --all-levels
python3 -m unittest Tests/test_thps2.py
./Tools/test.sh -XCTest GameHubTests.THPS2OriginalLevelTests
```

Six Python tests cover synthetic fixed-point/UV/flag/color records, compact palettes, odd-height texture rows, malformed spans/counts/indices, original source identities, all supplied TRG tables, blockmap memberships and unknown-command framing. Eight native tests cover independent source parsing, byte-fenced Hangar data, blockmap boundary/membership checks, malformed source data, bounded path handling, and actual ten-package original/PC SceneKit construction. The isolated optimized ARM64 probe passed all ten original and PC scene constructions on the M5. Run the shared XCTest command for final integrated results; those are recorded by the parent checkpoint.

Next reconstruct `THAWK2.EXE`'s PSX/TRG loading and skater/controller state routines statically, starting with the actual source floor/plane classes and restart/rail graph. Preserve invisible quarterpipe classification instead of using only rendered triangles. Recover expression/command VM semantics and actor spools before reproducing career goals and moving scene content. Add a clearly labelled original scene lab only if useful for visual/source qualification; a viewer cannot satisfy the requested game rewrite. Obtain meaningful original-game behavior/frame comparisons and physical controller checks, then sustained M1 acceptance when the owner makes the laptop available. Work on the paused M1 remains unauthorized.

## Primary research references

- [GreaseMonkey's PSX format research](https://gist.github.com/iamgreaser/b54531e41d77b69d7d13391deb0ac6a5), including the correction that texture data has a pointer table. It provides starting hypotheses; actual supplied bytes determine accepted layouts.
- [JayFoxRox's PSX reader](https://github.com/JayFoxRox/thps2-tools/blob/master/convert-psx.py) and [TRG disassembler](https://github.com/JayFoxRox/thps2-tools/blob/master/disassemble-trg.py), used as primary research references. No third-party parser package was installed, executed or copied into the runtime. The first-party readers add independent bounds and source-specific corrections described above.
