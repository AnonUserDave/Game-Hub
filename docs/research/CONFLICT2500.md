# Conflict2500: native translation of recovered BASIC rules

2026-10-13, son's ARM64 M5 Pro / 24 GB. This is **development gameplay**, not a verified faithful rewrite. M1 performance, physical Fusion Pro input and original-game comparison remain unverified.

## Source identity and recovery

`Tools/prepare_retro_media.py` verifies the root archive, nested archive and selected disk hashes against the existing retro inventory, then reads DOS3.3 catalog/track-sector chains offline. It never runs a source CPU, BASIC interpreter or game.

The selected143360-byte DOS-order image has SHA-256 `343ea10febc0f5fc4773424742a3843be23a6e17ede162beb35c09905494cfe3`. It contains three recoverable tokenized Applesoft programs:

- `H`: startup/instructions, 5836 bytes,131 lines.
- `CONFLICT`: actual game,11919 bytes,309 lines, SHA-256 `083826876c216b210d2ad779160711c03d7d29be0fa178a3a243066993fcb16a`.
- `AH SYMBOL`: startup symbol,418 bytes,9 lines.

Full original bytes and detokenized listings stay in ignored `Library/SourceMedia/retro/conflict-2500-apple-ii/`. This corrects the previous inventory claim that no high-level game logic was present. Line numbers below refer to that local `CONFLICT` listing. The offline reader validates BASIC next-line pointers and token/literal/REM/DATA handling. Token syntax is corroborated by the [Applesoft ROM disassembly](https://6502disassembly.com/a2-rom/Applesoft.html); gameplay evidence is the supplied file itself.

## Ported rule boundaries

| Original lines | Native behavior |
| --- | --- |
|3240–3290,1000–1100| Scenario counts1–10 friendly ships,1–20 enemy ships,1–10 bases and planets; two deployable mines per ship. Fleet initialization keeps the original random call order and ranges. |
|910| Integer attenuation `floor(20000/(10+(distance/10)^2))`. |
|60,1110–1450| Enemy orders occur once before the first player command and before each turn's movement. Manhattan-distance priorities2/1/5 select ships/bases/planets. First exact-coordinate ship intercepts an attack; otherwise all coincident planets/bases are hit separately, preserving RNG draw order. |
|1460–1640| Enemy movement/clamps and energy regeneration; friendly movement/clamps and post-clamp velocity energy charge. Integer assignments occur in the same sequence as the source. |
|1650–2040| Galactic map13×9; enemy ships hidden there. Tactical window filters at Manhattan distance<2000, scales original coordinates by50/40; original five ten-pixel symbols are decoded from DATA950–990 into ignored content JSON. |
|2120–2280| Mine blast radius500, attenuation distance floor175, cumulative enemy detection chance. Native preserves the source's inner-loop continuation after detonation. |
|2290–2520,3160| Fire angle0–360/power0–200,50energy per power, one shot per ship per turn; Manhattan prefilter<1290 and discrete path samples in original direction arithmetic; hit priorities and kill counts. |
|2530–2580| Course speed0–5000 with sufficient energy; heading0–359 using original divisor57, distinct from the firing divisor57.2957795. |
|2670–2910| Base/planet proximity and refuel limits; positive/negative ship energy transfers,0–30000 cap. The native UI currently selects the first nearby transfer recipient; the original prompts for every coincident ship. |
|2930–3010| SET increments mine index from1, ARM activates the latest mine; per-selection placement flag remains separate from per-turn firing. |
|3020–3230| Source status heading calculation and logical ship selection/NEXT/END/view commands. An exactly horizontal vector retains the source status calculation's edge case. |
|210–510| Turn/fleet exhaustion and percentage victory condition, including requirement for a surviving base or planet. |

`ConflictCore.swift` contains a first-party native state machine with explicit command methods. It does not interpret the recovered BASIC. `ConflictSnapshot` fences version and source hash, bounds arrays/scalars and preserves native RNG state. `RetroGameViews.swift` supplies scenario setup, map/tactical/status displays, parameter fields, keyboard/gamepad actions, bounded saves and return-to-library lifecycle.

## Approximations and incomplete fidelity

- Native RNG is a deterministic64-bit generator, not Applesoft RND. Native `Double`/`Int` arithmetic is not Applesoft's40-bit floating point or proven percent-array conversion parity. Native saves preserve native progression; they do not import original save data.
- Native display, colors, printing/flash delays and transitions are approximations. The original source fires animated tactical pixels; this native checkpoint resolves the shot directly and reports its result.
- Without locally prepared tactical data, the clean-clone fallback draws one point per object, rather than original symbols. That is distinct from original-asset rendering.
- Docking with multiple nearby ships uses one chosen transfer amount for the first eligible ship. Full source prompting still needs implementation.
- Native pause/save/restore are conveniences; original instructions/startup artwork and audio presentation are not reproduced.
- Controller buttons cover common turn actions; parameter entry uses keyboard/trackpad. Full controller-only text entry, physical focus/reconnect/action checks and additional devices remain unfinished.
- No running original was executed or compared; no M1 acceptance was performed.

## Verification

Tests use directly authored source-rule scenarios, rather than a running original. Coverage includes firing/prefilter/score/priority changes, per-turn fire state, course arithmetic and post-clamp charge, docking proximity/energy constraints, friendly mine blasts, coincident-target resolution, fleet/victory terminal behavior, source/version/bounds validation and deterministic snapshot continuation. The local preparer also verifies the actual supplied disk/file identity.

```sh
python3 Tools/prepare_retro_media.py --games conflict-2500-apple-ii
python3 -m unittest discover -s Tests -p 'test_retro_media.py'
./Tools/test.sh -XCTest GameHubTests.ConflictCoreTests
./Tools/test.sh -XCTest GameHubTests.RetroInputTests
```

Completion requires closing the specific fidelity gaps, original behavior/visual/audio comparisons, complete logical control coverage and native lifecycle checks, and the mandatory M1 sustained/input gates. Unit tests establish reconstructed rules and native repeatability only.
