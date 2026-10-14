# Ready-to-paste continuation prompt

Paste the following into Codex opened in a clone of `https://github.com/AnonUserDave/Game-Hub.git` on the son's Mac:

---

Continue building this native macOS Game Hub for my dad. Read `AGENTS.md`, `docs/M1_TARGET_CONSTRAINT.md`, `docs/STATUS.md`, `docs/HANDOFF.md`, and `docs/INTEGRATION.md` first. Use subagents for independent tasks where available and keep the repository updated with small commits and pushed checkpoints.

**Hard constraint:** I develop on an M5 MacBook Pro with 24 GB RAM, but the product must be optimized for my dad's **M1 MacBook Air, 8 GB unified memory, macOS 15.6, 2560 × 1600 display**. My M5 is a development machine only. Do not raise the baseline, choose defaults from its available memory, require newer GPU features, hide reduced rendering resolution, or call M5 performance M1 validation. Target sustained 60 FPS on his fanless Air and follow the acceptance record in the constraint document. Do not use or run background work on his laptop now.

Build one hub for all supplied games, rewriting them as native ARM64 macOS games without emulation, Wine or Rosetta. Start with Tiger Woods PGA Tour 2005. Preserve its visual style while improving fidelity at 2560 × 1600. Support keyboard/trackpad and my dad's wired BDA/PowerA XB1 Fusion Pro controller (`24c6:591a`). Make future native games easy to integrate. Faithfulness means verified assets, behavior, visuals and controls; an ARM64 executable cannot be byte-identical to the original Windows executable. Never label scaffolding as a completed port.

The original game ZIPs have already been AirDropped to this computer. Locate them and place or copy them into the cloned repository root as ignored local media. Start with `Tiger_Woods_PGA_Tour_2005_Win_ISO_EN.zip`. Do not upload original media or extracted game binaries/textures to GitHub. Run `python3 Tools/prepare_pga2005.py` to regenerate original Pebble Beach and Turnberry course assets. See `docs/MEDIA_SETUP.md`. Use this machine's toolchain and paths, not Alex's absolute paths in older environment notes.

The checkpoint includes a working native SwiftUI hub, 18 catalog entries, native launch/import integration, three generated practice golf holes, native USB controller input, explicit fullscreen Metal rendering, and an Original Course Lab displaying actual original PBL/TUR geometry and textures. The user physically verified A/B/X/Y, both triggers and both sticks; full game mappings, remaining buttons and reconnect/focus checks still need work. The latest optimized build passes **23 Swift XCTest tests and 18 Python tests**. A forest transform/camera obstruction fix has scene regression coverage across all three practice holes, but its final visual check is pending. Snapshot 55–60 FPS on the M1 is not sustained performance certification.

Original primary geometry decoding validates all 11 courses. Original TCR hole arrays, TCL textures/materials and exact triangle floor queries exist. Inch units are corroborated by original yardage conversion code. Generated practice physics and golfer remain provisional. Original-course gameplay and the other native rewrites do not yet exist.

First reproduce the build and tests with `./Tools/build.sh`, `./Tools/test.sh`, and `python3 -m unittest discover -s Tests -p 'test_*.py'`. Confirm the generated practice camera fix visually and load both original course viewers. Record M5 checks honestly as M5 checks.

Then implement a clearly labeled original Pebble Beach **18-hole development gameplay** option using existing original meshes/materials, authoritative TCR tees/pins/par and `PGAOriginalCollision.swift`. Inject an immutable terrain provider into the simulation instead of its procedural-only terrain assumptions. Reuse a single original course mesh/index across holes. Convert original inch positions consistently to meters with a documented origin and reversible transform; do not substitute INI coordinates, which have a different origin. Validate all tees/pins against original floor geometry before enabling play. Preserve source material IDs and label approximate surface mapping/physics as provisional. Exact floor sampling is not wall/object collision or proof of original physics parity. See the adapter plan in `docs/HANDOFF.md`.

Use the existing REA/Ghidra research ledger and source-bound evidence before repeating analysis. REA was installed on my dad's Mac; do not assume its MCP server, skill, Ghidra, JDK or local databases exist here. Configure reputable tools locally if useful. Research scripts and curated evidence are versioned; large local installations and analysis databases are not. Never execute the Windows installer as a way to import media. Keep static decompilation distinct from observed runtime behavior.

After original-course gameplay, reconstruct original flight/impact/rolling/cup behavior, visuals, characters, animation, audio, saves and modes, with meaningful fixtures and reference comparisons. Continue the remaining titles only with their own native implementation and completion evidence. The PGA 2004 archive currently contains only disc 1. The archive labeled Space Invaders contains Bally pinball firmware; my dad wants the classic 1978 Taito arcade shooter, so obtain/confirm the correct source rather than treating that archive as the shooter.

Preserve local changes, test meaningful changes, update `docs/STATUS.md` and `docs/HANDOFF.md`, and push progress to `AnonUserDave/Game-Hub`. Do not mark the overall project complete until all requested games are genuinely playable faithful native rewrites, integrated into the hub and validated on the M1 target.

---
