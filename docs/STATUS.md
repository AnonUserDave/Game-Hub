# Project status

Updated 2026-10-13. Long-term goal remains active.

| Workstream | Current evidence | Remaining |
| --- | --- | --- |
| Hub | SwiftUI source, native launch contract, game catalog, direct ARM64 build | Final integrated runtime/launch/import validation |
| PGA native development | Original practice simulation and native renderer under integration | Runtime QA; this is not the original game |
| PGA original assets | 11 course settings, 198 holes, 236 decoded original images; sample pixel checks pass | TCR/TCL mesh/material/placement decoding |
| PGA original engine | Extracted DLLs, named physics/terrain/render exports, REA/Ghidra research | Behavioral reconstruction and original-runtime comparisons |
| Retina/performance | Native backing-size architecture | Measured 2560 × 1600 rendering and sustained M1 profiling |
| Wired controller | BDA XB1 Fusion Pro USB detected; zero native profiles initially | Actual button input and full game mapping |
| Other supplied games | Cataloged; source-edition issues recorded | Full native rewrites and fidelity tests |
| Repository | Local main initialized with requested GitHub remote | Commit/push checkpoint and verify remote |

No game is currently certified as a fully faithful native rewrite. See [HANDOFF.md](HANDOFF.md) for the next concrete work and completion gates.
