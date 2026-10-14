# Project status

Updated 2026-10-13 (son's checkpoint). The long-term objective remains unfinished. No game is certified as a fully faithful rewrite. Every measurement below that names the M5 was taken on the son's M5 MacBook Pro (24 GB, macOS 26.3) and is **not** M1 acceptance. Work on the owner's M1 remains paused.

| Workstream | Verified progress | Remaining |
| --- | --- | --- |
| Hub | 19 catalog entries; the new Pebble Beach module has its own built-in entry; launch and return verified in the native UI on the M5 | Broader native import/launch QA on the M1 |
| Original Pebble Beach play | New "Pebble Beach · Original Data" module plays all 18 holes. It uses each hole's own original terrain, materials and textures, the standard condition layers (`0x420`), TCR tee 3 and pin 0 (both floor-snapped), card yardage, and original lie labels. Round save/restore works by course identity. Loads in a few seconds on the M5. | Original physics (flight, Collide, slip), cup rules, OB polygons, tee/pin choice rules, golfer, audio, modes. M1 load and frame time. |
| Per-hole worlds | Each TCR hole is a separate overlapping world, selected by `PatchLayerInfoS` (`+0x61`). GHPC v3 keeps the per-patch layer table. The `0x420` selector loads 6,609 of 6,943 PBL patches, matching static analysis of `CHole::Load`. | Purpose of `0x8000` and composite (Tiger-Proofing) levels |
| Handedness | Source is left-handed; the native transform mirrors Z. The ocean lies right of holes 9–10 and left of 18, as at the real course (tested). | — |
| Surfaces and lies | Original flag bits (water, hazard, free drop, …), `StopBall` lie records (rough ⅔ Md / ⅙ Lt / ⅙ Dp, bunker entry rules), c0 launch power and `PureRolling` c7 deceleration are applied. The RNG is seeded and saved. Free drops happen only on 0x400 surfaces; other unplayable rests cost a stroke. | Collide/slip coefficients (c1–c5, c8, c9), runtime validation of thresholds and the random draw order |
| Provisional physics | Native flight, bounce and slip are labeled approximate. Bounce was retuned so drives roll out roughly 10–15% of carry. A development caddie aims along the authored TCR aim points. | Reconstruct the `CBallFlight` flight/impact/slip model with numeric fixtures |
| Original Course Lab | Shows one mirrored hole world at a time (`[`/`]`, D-pad), with the same standard condition selection; 59–60 FPS windowed on the M5 after load | Whole-course buffers still use about 200 MB in the Lab |
| Rendering | MTKView uses an sRGB attachment. The original sky dome, per-hole tree instances, three tree mesh LODs, distant billboards and panorama strips now draw from decoded data. Opt-in `PGASnapshotTests` rendered all 18 Pebble tee views and Turnberry 1/9/18 at 2560 × 1600, 4× MSAA on the M5. | M1 fullscreen visual and sustained performance checks; exact render-preset fog/lighting, baked tree lighting, water and animation. |
| Retina | 2560 × 1600 fullscreen attachments verified on the M1 earlier. Windowed on the M5, the HUD reported a 2720 × 1782 Metal target, 4× MSAA, 59–60 FPS. | Sustained 30-minute M1 run at fullscreen |
| Memory (M5) | Hub idle 54 MB. Pebble loaded: 563 MB footprint (≈330 MB GPU, mostly 4× MSAA targets and drawables). Lab over golf: 776 MB. Back at the hub: 208 MB, 0 leaks (a session retain cycle was fixed). | Same measurements on the 8 GB M1 against the 3 GB budget; consider memoryless MSAA attachments |
| Exact floor index | Compact CSR index. PBL 9,110 and TUR 7,128 centroid queries, zero missing. Whole-course build 0.03 s, per-hole indexes for all 18 holes during load. | Wall/object and swept-ball collision |
| Practice course | Forest/camera fix visually confirmed in the native UI on the M5. Practice now renders with correct brightness. | Practice remains generated scaffolding |
| Wired controller | Native USB backend unchanged; earlier user report: buttons, triggers and sticks working | Other buttons, game actions, focus and hot unplug/replug, in the Pebble module too |
| Tests | 34 ordinary Swift XCTest and 96 Python tests pass on this branch (two opt-in Swift snapshot tests skipped by default). The scenery opt-in snapshot asserts a sky node and visible tree draws. | Expand with reconstructed physics fixtures; M1 acceptance. |
| Other games | All supplied archives cataloged; Space Invaders source mismatch recorded | Full native rewrites; PGA 2004 needs discs 2/3 |
| GitHub | Checkpoint commits exist locally in the son's clone | **Not pushed.** The son's GitHub account `Pablo-Rogers` has read-only access to `AnonUserDave/Game-Hub` (push returns 403). |

See [HANDOFF.md](HANDOFF.md) for the next work and completion gates, [QA.md](QA.md) for the check log, and [the REA ledger](research/PGA2005-REA.md) for the static evidence.

The son's M5 MacBook Pro (24 GB) is for development only. [M1_TARGET_CONSTRAINT.md](M1_TARGET_CONSTRAINT.md) requires M1 Air / 8 GB / 2560 × 1600 acceptance, and nothing above is that acceptance.
