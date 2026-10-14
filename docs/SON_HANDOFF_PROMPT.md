# Ready-to-paste continuation prompt

Paste the following into Codex opened in a clone of `https://github.com/AnonUserDave/Game-Hub.git` on the son's Mac:

---

Continue building this native macOS Game Hub for my dad. Read `AGENTS.md`, `docs/M1_TARGET_CONSTRAINT.md`, `docs/STATUS.md`, `docs/HANDOFF.md`, and `docs/INTEGRATION.md` first. Use subagents for independent tasks where available and keep the repository updated with small commits and pushed checkpoints.

**Hard constraint:** I develop on an M5 MacBook Pro with 24 GB RAM, but the product must be optimized for my dad's **M1 MacBook Air, 8 GB unified memory, macOS 15.6, 2560 × 1600 display**. My M5 is a development machine only. Do not raise the baseline, choose defaults from its available memory, require newer GPU features, hide reduced rendering resolution, or call M5 performance M1 validation. Target sustained 60 FPS on his fanless Air and follow the acceptance record in the constraint document. Do not use or run background work on his laptop now.

Build one hub for all supplied games, rewriting them as native ARM64 macOS games without emulation, Wine or Rosetta. Start with Tiger Woods PGA Tour 2005. Preserve its visual style while improving fidelity at 2560 × 1600. Support keyboard/trackpad and my dad's wired BDA/PowerA XB1 Fusion Pro controller (`24c6:591a`). Make future native games easy to integrate. Faithfulness means verified assets, behavior, visuals and controls; an ARM64 executable cannot be byte-identical to the original Windows executable. Never label scaffolding as a completed port.

The original game ZIPs have already been AirDropped to this computer. Locate them and place or copy them into the cloned repository root as ignored local media. Start with `Tiger_Woods_PGA_Tour_2005_Win_ISO_EN.zip`. Do not upload original media or extracted game binaries/textures to GitHub. Run `python3 Tools/prepare_pga2005.py` to regenerate original Pebble Beach and Turnberry course assets. See `docs/MEDIA_SETUP.md`. Use this machine's toolchain and paths, not Alex's absolute paths in older environment notes.

The 2026-10-13 son's checkpoint includes:

- The native hub (19 entries) and generated practice holes, with the forest fix visually confirmed.
- An 18-hole **Pebble Beach · Original Data** module on the original per-hole terrain, textures, tees and pins.
- Statically recovered patch-selection and surface rules: lie records, c0 launch power and c7 rolling.
- A per-hole, correctly mirrored Original Course Lab.
- An sRGB rendering fix and a session leak fix.

It passes **32 Swift XCTest tests (one opt-in snapshot test) and 19 Python tests** on the M5. Read `docs/STATUS.md`, `docs/HANDOFF.md` and the REA ledger sections dated 2026-10-13: each TCR hole is its own overlapping world, the source is left-handed, and the standard condition selector is `0x420`. Flight, bounce and slip physics are still approximate native code, and nothing has been measured on the M1 yet.

First reproduce: `./Tools/build.sh`, `./Tools/test.sh`, `python3 -m unittest discover -s Tests -p 'test_*.py'`, `python3 Tools/prepare_pga2005.py`. If commits from the previous session are not on GitHub (the son's account had read-only access), publish them first.

Use the existing REA/Ghidra research ledger and its evidence before repeating analysis. The REA MCP server and a Ghidra provider are configured on the son's Mac; direct `Tools/analyze_pga2005_ghidra.py` runs work when REA's session times out. Keep static decompilation distinct from observed runtime behavior, and never execute the Windows installer as a way to import media.

Next, in order:

1. When the owner makes his laptop available, run M1 acceptance of the Pebble module at fullscreen 2560 × 1600.
2. Reconstruct the original `CBallFlight` flight, Collide, slip, rolling and cup model, with numeric fixtures.
3. Decode the INI OB polygons and the original drop and tee/pin rules.
4. Restore original sky, lighting, water, vegetation and the golfer.

After original-course gameplay, reconstruct original flight/impact/rolling/cup behavior, visuals, characters, animation, audio, saves and modes, with meaningful fixtures and reference comparisons. Continue the remaining titles only with their own native implementation and completion evidence. The PGA 2004 archive currently contains only disc 1. The archive labeled Space Invaders contains Bally pinball firmware; my dad wants the classic 1978 Taito arcade shooter, so obtain/confirm the correct source rather than treating that archive as the shooter.

Preserve local changes, test meaningful changes, update `docs/STATUS.md` and `docs/HANDOFF.md`, and push progress to `AnonUserDave/Game-Hub`. Do not mark the overall project complete until all requested games are genuinely playable faithful native rewrites, integrated into the hub and validated on the M1 target.

---
