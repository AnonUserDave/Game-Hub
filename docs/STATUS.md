# Project status

Updated 2026-10-13 (son's physics branch checkpoint). The long-term objective remains unfinished. No game is certified as a fully faithful rewrite. The checks below ran on the son's M5 Pro MacBook Pro (24 GB, macOS 26.3) and are **not** M1 acceptance. Work on the owner's M1 remains paused.

| Workstream | Verified progress | Remaining |
| --- | --- | --- |
| Hub | 19 catalog entries; the new Pebble Beach module has its own built-in entry; launch and return verified in the native UI on the M5 | Broader native import/launch QA on the M1 |
| Original Pebble Beach play | "Pebble Beach · Original Data" plays all 18 holes with original terrain, materials and textures, standard condition layers (`0x420`), TCR tee 3 and pin 0 (both floor-snapped), card yardage and original lie labels. Round save/restore works by course identity. Original-course shots now run through the reconstructed `CBallFlight` state machine at 60 Hz. | Running-game physics comparison, OB polygons, tee/pin choice rules, vegetation, golfer, audio, modes. M1 load and frame time. |
| Per-hole worlds | Each TCR hole is a separate overlapping world, selected by `PatchLayerInfoS` (`+0x61`). GHPC v3 keeps the per-patch layer table. The `0x420` selector loads 6,609 of 6,943 PBL patches, matching static analysis of `CHole::Load`. | Purpose of `0x8000` and composite (Tiger-Proofing) levels |
| Handedness | Source is left-handed; the native transform mirrors Z. The ocean lies right of holes 9–10 and left of 18, as at the real course (tested). | — |
| Surfaces and lies | Original flag bits, TCL c0–c9 coefficients and `StopBall` lie draws feed the reconstructed flight on original courses. The RNG is seeded and saved. Free drops happen only on 0x400 surfaces; other unplayable rests cost a stroke. | Running-game validation of coefficient interpretation, thresholds, random draw order and drop rules |
| Ball flight | Swift `CBallFlight` port covers launch, drag/lift/wind, impact, slip, roll and cup dynamics in original inches at 60 Hz. It matches the separately implemented Python static reconstruction across 125 golden scenarios; 122 are bit-identical. `PGASimulation` now uses it on original courses, and its development caddie uses recovered club distances. Generated practice keeps its provisional model. | The original game has not been run for comparison. Eight-club UI and swing mapping are approximations; live settings are Normal green/rough, Advanced, Solid Core and calm wind. Trees, objects and wall collisions remain absent. |
| Original Course Lab | Shows one mirrored hole world at a time (`[`/`]`, D-pad), with the same standard condition selection; 59–60 FPS windowed on the M5 after load | Whole-course buffers still use about 200 MB in the Lab |
| Rendering | MTKView now uses an sRGB attachment. The previous linear-to-unorm output was far too dark in all golf views; fixed and compared with offscreen snapshots on the M5. Opt-in `PGASnapshotTests` renders 2560 × 1600 4× MSAA tee views. | Visual check on the M1 at fullscreen; original sky, fog, lighting, shaders, water and vegetation |
| Retina | 2560 × 1600 fullscreen attachments verified on the M1 earlier. Windowed on the M5, the HUD reported a 2720 × 1782 Metal target, 4× MSAA, 59–60 FPS. | Sustained 30-minute M1 run at fullscreen |
| Memory (M5) | Hub idle 54 MB. Pebble loaded: 563 MB footprint (≈330 MB GPU, mostly 4× MSAA targets and drawables). Lab over golf: 776 MB. Back at the hub: 208 MB, 0 leaks (a session retain cycle was fixed). | Same measurements on the 8 GB M1 against the 3 GB budget; consider memoryless MSAA attachments |
| Exact floor index | Compact CSR index. PBL 9,110 and TUR 7,128 centroid queries, zero missing. Whole-course build 0.03 s, per-hole indexes for all 18 holes during load. | Wall/object and swept-ball collision |
| Practice course | Forest/camera fix visually confirmed in the native UI on the M5. Practice now renders with correct brightness. | Practice remains generated scaffolding |
| Wired controller | Native USB backend unchanged; earlier user report: buttons, triggers and sticks working | Other buttons, game actions, focus and hot unplug/replug, in the Pebble module too |
| Tests | 47 Swift XCTest (2 opt-in snapshot tests skipped) and 99 Python tests pass on the M5 Pro. Optimized native arm64 app build passes. | Original-game comparisons and M1 sustained acceptance |
| Other games | All supplied archives cataloged; Space Invaders source mismatch recorded | Full native rewrites; PGA 2004 needs discs 2/3 |
| GitHub | Checkpoint commits exist locally in the son's clone | **Not pushed.** The son's GitHub account `Pablo-Rogers` has read-only access to `AnonUserDave/Game-Hub` (push returns 403). |

See [HANDOFF.md](HANDOFF.md) for the next work and completion gates, [QA.md](QA.md) for the check log, and [the REA ledger](research/PGA2005-REA.md) for the static evidence.

The son's M5 MacBook Pro (24 GB) is for development only. [M1_TARGET_CONSTRAINT.md](M1_TARGET_CONSTRAINT.md) requires M1 Air / 8 GB / 2560 × 1600 acceptance, and nothing above is that acceptance.
