# Atari 2600 Breakout reconstruction

2026-10-13 development checkpoint. This is a native ARM64 development reconstruction of the supplied cartridge. The core contains no processor interpreter, emulation, Wine, or Rosetta. Static agreement with cartridge constants and native unit tests does not establish faithful gameplay, visuals, audio, controls, or release readiness. The current test host is the son's M5 Pro MacBook Pro / 24 GB; **M1 performance unverified**.

## Selected source and reproducibility

The archive is `Breakout_Atari-2600_ROM_EN.zip`, 3867 bytes, SHA-256 `15e02de8fcb47c31e3aa4081e921796027726ffdb038c0bce7e02f537869e7b2`. Its selected member is `Breakout_Atari-2600_ROM_EN/Game Files/Breakout.bin`, 2048 bytes, SHA-256 `376323f051c3c373c887fd83abead39d87d844ff283d435f4addbfc1710c6fd5`, CRC32 `3037638c`. This matches the existing [retro inventory](evidence/retro-inventory.json).

`Tools/prepare_breakout2600.py` verifies both identities before copying bytes to ignored `Library/SourceMedia/breakout2600/Breakout.bin`. It records table provenance in ignored `Library/Research/breakout2600/tables.json`. The checked-in [evidence record](evidence/breakout2600.json) contains first-party interpretations and small gameplay tables, with exact cartridge offsets; no original media or full disassembly is committed.

```sh
python3 Tools/prepare_breakout2600.py --evidence docs/research/evidence/breakout2600.json
python3 Tools/prepare_breakout2600.py \
  --ghidra /path/to/ghidra_12.1.2_PUBLIC \
  --java /path/to/native/jdk/Contents/Home/bin/java
./Tools/test.sh -XCTest GameHubTests.BreakoutCoreTests
```

The second command uses an existing analysis engine; it never installs one or executes the cartridge. Direct Ghidra 12.1.2 uses `6502:LE:16:default`, the Raw Binary loader, normalized base `$F000`, and `Tools/ExportBreakout.java`. The local project, log, command provenance, and disassembly remain under ignored `Library/Research/breakout2600`. The game uses `BRK` as a compact call to `$F1C6` and resumes at instruction address +2; ordinary control-flow traversal otherwise stops at the first `BRK`. The export script recovers those continuations explicitly. Neither the REA shared active target nor another title's analysis project is changed.

## Implementation spec

The scoped implementation is a Foundation-only deterministic core, first-party preparation/static-analysis tools, meaningful Swift tests, and this findings ledger. Parent integration owns the native renderer, input adapters, hub entry, status/handoff, and commits.

Acceptance for this development checkpoint:

- Select/hash the supplied revision and retain address/offset evidence for every recovered gameplay table.
- Port the original variations, discrete fixed-point speed values, serve seeds, brick points, five-ball limit, paddle sizes, split limits, catch and steering rules.
- Keep simulation independent of rendering speed; use one tick per nominal NTSC frame.
- Provide Codable snapshots fenced to source identity and validate loaded state before indexing or arithmetic.
- Exercise source constants and observable transitions through native ARM64 XCTest; inspect the final diff.
- Label remaining reconstruction choices and every missing comparison/acceptance gate.

No dependency, graphics baseline, OS minimum, source archive, or other title is changed by this scoped work. The M1 Air / 8 GB / 2560 × 1600 constraint still applies.

## Findings ledger

Addresses below are normalized cartridge addresses; subtract `$F000` for the 2048-byte file offset. Findings are static observations or explicit derived interpretations, never observed original execution.

| Behavior | Evidence | Result and boundary |
| --- | --- | --- |
| Reset and compact positioning call | Vectors at offsets `$7FC..$7FF`; `$F237..$F25B`; `$F1C6..$F1E0` | Reset `$F237`, `BRK` handler `$F1C6`; handler positions TIA objects, then `RTI`. The port replaces hardware positioning with native geometry. |
| Brick wall | `$F1AB..$F1C5`; `$F4C8..$F502`; tables `$F798..$F7A9`, `$F7BE..$F7CF` | Six rows, 18 columns, 108 bricks. Packed playfield bytes are cleared with column-specific AND masks. Native storage expands each brick to a Boolean. |
| Brick points | `$F506..$F518`; `$F1F2..$F1FF`; table `$F78C..$F791` | Top-to-bottom `7,7,4,4,1,1`; one wall is `18×24 =432`, two total864. Cartridge arithmetic is BCD; native score is an integer. Timed modes skip source score accumulation; the native core retains a hidden score for wall bookkeeping. |
| Game selection | `$F3A4..$F3B1`; `$F730..$F744`; `$F7F0..$F7FB` | 48 console selections: 12 variation flag bytes × four player counts. Bits `0x10` steering, `0x08` catch, `0x40` invisible, `0x80` timer, `0x20` breakthrough. |
| Balls and team turns | `$F374`; `$F3D7..$F41C`; `$F749..$F76D` | Reset initializes five balls. A lost ball reaches Y≥208, clears motion, and swaps team score/wall data for multiplayer. Source decrements its shared round counter after a team pair; native keeps five explicit balls per team, with finished teams skipped. Terminal multiplayer tie/turn details require reconciliation. |
| Serve | `$F401..$F418`; table `$F788..$F78B` | Frame counter low two bits choose seeds `A0,40,C0,60`; shifting gives X `64,128,128,192`, directions right/left/right/left. Y112, horizontal and downward speed one pixel/frame. Fire is level-sensitive. |
| Fixed-point motion | `$F5C1..$F5DD`; `$F68C..$F6DA`; table `$F7DC..$F7EF` | Positions and signed velocities have eight fractional bits. Packed speed bytes use low two bits for integral units and high six for fraction. The port operates on Q8 integers rather than floating-point integration. |
| Speed tiers and rebound | `$F438..$F489`; `$F519..$F528`; `$F6A8..$F6DA` | Paddle-hit counter increases through12; groups of four select speed tier, and contact offset chooses one of two angle pairs. Hitting rows0–2 forces tier16. Exact magnitude pairs in pixels/frame: `(1.5,1),(1,1.5),(1.5,2),(.5,2),(2,1),(2,1),(2,2),(2,2),(2,3.375),(2,3.375)`. Native collision timing/contact position still differs from the TIA. |
| Paddle widths and ceiling | `$F4AB..$F4C2`; `$F55F..$F57A`; `$F7D6..$F7DB` | Beginner width16, advanced12; touching the ceiling shrinks to12/8 for that ball. Source glyphs `F0,E0,C0` use fourfold TIA pixels; half widths `8,6,4` enter rebound calculations. |
| Paddle bounds and split teams | `$F57C..$F5A5`; `$F6DB..$F706`; `$F782..$F787` | Cartridge X bounds full55–191, left55–126, right128–191. Three players: one full paddle against two split paddles; four: two split paddles per team. Native X is cartridge X−49. |
| Steering | `$F708..$F72B` | Enabled only while rising; a changed knob position moves the ball two pixels in the knob's direction. Native absolute knob values replace the source RC reading/filter, so response timing remains approximate. |
| Catch | `$F5A7..$F5F4` | Hold fire during paddle contact to retain the ball at Y178 and paddle-left+4; releasing fire resumes motion. |
| Breakthru | `$F52F..$F540` | Bit0x20 skips vertical reflection and the brick collision latch. Standard mode keeps the brick latch until the next paddle or ceiling contact. |
| Invisible wall | `$F2FC..$F326`; `$F50B..$F50D` | The brick sound counter reveals the wall for six frames after a hit. Idle/end screen rendering differs from active play. Native uses an explicit six-frame visibility counter. |
| Timer | `$F3C8..$F3D4`; `$F1F2..$F1FF` | BCD+1 every64 active frames, including waiting for serve and catching. No base-60 rollover was found in this bounded counter path; native preserves a 64-frame tick counter. Do not relabel it verified real-time seconds. |
| Sound controls | `$F2AF..$F2D5`; `$F41A`; `$F48C`; `$F50B`; `$F55B`; `$F792..$F797` | `AUDC0=12`, volume15 while low six event-counter bits are nonzero. Brick `AUDF0` values10,12,16,18,22,28 last six frames; serve/paddle last eight with `AUDF0`4/8; side hit six at4. Native TIA-equivalent audio is not implemented in this core. |
| Geometry | `$F03B..$F0F0`; `$F60A..$F657`; object positions `$F250..$F25B` | Derived 160-pixel raster; 8-pixel side strips, two-by-four ball, brick rows starting Y50 with six lines/row, paddle Y180, drain208. Native ceiling lower bound26 is inferred from the display kernel. These are static raster interpretations awaiting original capture comparison. |

The publisher's [Breakout instructions](https://atari.com/pages/breakout) independently describe the variation names and intended controls, five balls, two walls, the 864 maximum, and team comparisons. They support the product rules; they do not identify this ROM hash or establish frame-level agreement. The native second wall appears on the next paddle return after the first wall clears. The non-timed ROM explicitly rebuilds at score432 on paddle contact (`$F490..$F4A2`); the timed second-wall trigger and exact two-wall end transition remain unresolved. The native terminal rule follows the published instructions, and is an approximation pending reconciliation.

## Verification and limits

The first-party preparation command verified the current archive and ROM hashes and decoded all listed tables. Direct Ghidra static disassembly completed successfully. `BreakoutCore.swift` typechecked with the native ARM64 Swift 6.3.1 toolchain and macOS SDK.

An isolated native XCTest bundle built from `BreakoutCore.swift` and `BreakoutCoreTests.swift` passed **13 tests, zero failures** on the M5 development host. Coverage includes the source flag/speed/score tables, phase-dependent serve, row speed boost, collision latch, breakthrough, catch/release, ascent-only steering, ceiling/difficulty widths, second wall/864 completion, five-ball multiplayer alternation, split boundaries, 64-frame timer, six-frame visibility, deterministic JSON restore/replay, and invalid-save rejection. These tests use authored scenarios and ROM-derived expected values; they do not compare a running original cartridge.

Native rectangle collision replaces prior-frame TIA collision registers and raster phase. It can change edge contacts, brick choice, rebound timing, and speed progression. Team transition rotates 36 packed items in the ROM; native state swaps atomically. Color/B&W switch, exact NTSC palette, scanline layout, console select repeat/attract behavior, sound synthesis, and all four simultaneous physical paddle inputs remain outside this core. The parent renderer/input integration is a separate claim.

Required before a faithful-completion label: reconcile the unresolved timer/second-wall and terminal paths; obtain owner-supplied original reference recordings without introducing emulation; compare serves, edge/center rebounds, speed changes, each mode, team changes, graphics and sounds; verify saves and launch/return in the native UI; verify Fusion Pro focus/reconnect and supported multiplayer input; run the required sustained M1 Air / 8 GB / 2560 × 1600 acceptance session when the owner makes that laptop available. No work on the owner's paused M1 is authorized by this checkpoint.
