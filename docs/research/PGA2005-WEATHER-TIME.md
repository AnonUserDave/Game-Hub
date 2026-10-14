# PGA Tour 2005 weather and time render presets

Static investigation, October 13, 2026. The original Windows game was **not
run**. These findings come from the supplied `Engine.dll` and its installed
`render1.ini`–`render40.ini` files. They describe original preset selection;
they do not establish visual equivalence or M1 performance for the native app.

## Inputs and confidence

- `Engine.dll` SHA-256:
  `94aa30bb645ea089fed6e98df0dce38d75c309e4531386cbe33c07f65bd19728`.
  Addresses below are image addresses with a `0x10000000` image base. Direct
  disassembly exists in ignored `Library/Research/ballflight-work/engine.dis.txt`.
  This is **not REA Evidence** or original source code.
- All 40 `engine/Executable/renderN.ini` files were compared byte-for-byte
  against the corresponding `install/Executable` copies; each pair matches.
  Original INIs and extracted binaries remain outside Git.
- **High confidence**: the selector arithmetic, file numbering, settings
  lookup, and data-file values below are visible in disassembly or INI bytes.
  **Medium confidence**: descriptions of the intended visual result, because
  the original executable was not run and the full render-setting interpolation
  and shader path have not been reconstructed.

## Selector reconstructed from the engine

`RenderCommand::UpdateWeatherAndTime` at `0x1005d09b` gets two normalized
values from the current course. The vtable pointer pairs in the binary match
`CCourse::GetTimeOfDay` / `GetWeather` and their `CompositeCourse` overrides at
virtual offsets `+0xa4` / `+0xa8`. The plain course reads game-setting bytes
at `+0x126` and `+0x125`, divides them by **4** and **7** respectively, and
caps each normalized value at 1 (`0x1017ad3b`, `0x1017ade7`). A composite
course can instead supply its condition values (`0x1017104b`, `0x101710a7`).

`RenderCommand::AdjustTimeOfDay` at `0x1005cde1` computes:

```text
weatherRow = min(7, trunc(weatherNormalized * 8))
position = (timeNormalized * 720 + 20 * (holeNumber - 1)) / 180
timeSlot = trunc(position)
blend = position - timeSlot
reportedPreset1 = 5 * weatherRow + timeSlot + 1
reportedPreset2 = reportedPreset1 + 1
```

This is a reconstruction of the instructions at `0x1005cdff`–`0x1005ce77`,
not a claim about all possible setting values. The constants `8.0`, `720.0`,
and `5` are present at `0x102d60dc`, `0x102d60d8`, and `0x10379f74`.
`UpdateWeatherAndTime` passes `(holeNumber - 1) * 20` at `0x1005d107`–
`0x1005d11c`; `StartHole` supplies the hole number at `0x1004223f`–
`0x10042248`. This means **20 units of time progression per hole**, where
**180 units span one neighboring preset interval**. Calling the units
"minutes" would be an inference; only the constants and effect are established.

`RenderKernel::LoadTimeRenderSettings` at `0x1007b8a4` loads five settings per
weather row using `5 * weatherRow + slot + 1` (`0x1007bb89`–`0x1007bbb4`).
`GetTimeRenderSettings` at `0x1007bbce` clamps a requested slot to the last
loaded slot. Therefore a late-round position past slot 4 keeps using that
row's fifth preset. `GetTimeOfDaySettings` at `0x1005d069` reports the raw
adjacent preset numbers, which can misleadingly extend into the next row;
the **actual lookup is clamped**. `CGlobalRenderSettings::Lerp` is called with
the two selected objects and `blend` at `0x1005cf18`–`0x1005cf29`.
The lower preset's sky type is compared at `0x1005ceb9`–`0x1005ceda` and can
recreate the skydome. The exact treatment of every other field in `Lerp`
remains open.

For discrete settings bytes 0–7 (weather) and 0–4 (time), this selects the
expected row and initial slot. A few calculation examples:

| Weather byte | Time byte | Hole | Selected settings | Blend |
| ---: | ---: | ---: | --- | ---: |
| 0 | 0 | 1 | `render1` then `render2` | 0 |
| 0 | 0 | 5 | `render1` then `render2` | 0.4444 |
| 0 | 2 | 1 | `render3` then `render4` | 0 |
| 0 | 2 | 18 | `render4` then `render5` | 0.8889 |
| 7 | 2 | 18 | `render39` then `render40` | 0.8889 |
| 0 | 4 | 18 | `render5` for both lookups | 0.8889 |

## Preset data matrix

Five files in each row are ordered by time slot: sunrise, morning, noon,
afternoon, sunset. The eight weather rows are identified by their file range,
sky type, and header comments. Several comments are stale: `render6.ini`
says "fair/Sunset" and `render7.ini`–`render10.ini` all say "Fair/Noon",
while `render12.ini` says "Pcloudy/Afternoon" and `render15.ini` says
"Cloudy/Sunset" despite having the same sky type as the partial-cloudy row.
The row-and-slot indexing is stronger evidence than those individual comments.

| Weather row | INIs | `[SKY] SKYTYPE` | `[LensFlare] Enabled` |
| --- | --- | ---: | ---: |
| Clear | 1–5 | 1 | 1 |
| Fair | 6–10 | 2 | 1 |
| Partly cloudy | 11–15 | 3 | 1 |
| Cloudy | 16–20 | 4 | 1 |
| Foggy | 21–25 | 5 | 0 |
| Overcast | 26–30 | 5 | 0 |
| Light rain | 31–35 | 5 | 0 |
| Heavy rain | 36–40 | 6 | 0 |

The presets contain more than a sky choice. For example,
`render1.ini` has fog start/end **3,000/125,000** source units and global
diffuse **0.7,0.7,0.9**, while clear noon `render3.ini` uses
**5,000/150,000** and **1,1,1**. Foggy sunrise `render21.ini` uses
**1,500/70,000** with the flare disabled. These are direct INI values;
which values are blended and how source units map through every original
render stage still need focused verification.

## Native-app gap and next bounded step

The current original-course call uses `PGAOriginalSceneBuilder.node` with its
neutral `.standard` style (`Sources/GameHub/PGAGame.swift` and
`PGAOriginalScenery.swift`), and `PGAGame.swift` sets fog from the generic
`render.ini`. It does not select the 40 condition presets. Preserve the
eight-by-five matrix and hole progression in first-party decoded metadata,
then feed the selected sky, fog, global diffuse, tree contrast/tint, and flare
values into the existing scene path. The shader behavior and visual comparison
need separate work; this note does not claim the current image is faithful.

Test selected settings at row boundaries and late holes, especially slot-4
clamping. Compare live original-game frames before qualifying colors, sky
transitions, rain, or lens flare. Measure sustained fullscreen 2560 × 1600
performance on the owner's M1 Air only when that machine is made available.
