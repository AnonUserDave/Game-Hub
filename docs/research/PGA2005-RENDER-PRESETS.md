# PGA Tour 2005 render presets: blending, lighting, fog, flare and rain

Static investigation, October 13, 2026. The original game was **not run**.
This note extends [PGA2005-WEATHER-TIME.md](PGA2005-WEATHER-TIME.md). That note
already gives the preset selector: the 8 × 5 matrix, the weather row, the
time position (20 units per hole, 180 per slot), slot-4 clamping and the sky
comparison. That material is not repeated here. This note covers what happens
after two presets are selected: which fields `CGlobalRenderSettings::Lerp`
blends, and how the active values reach terrain, trees, fog, sky, lens flare
and rain.

## Inputs, method and confidence

- `Engine.dll` SHA-256
  `94aa30bb645ea089fed6e98df0dce38d75c309e4531386cbe33c07f65bd19728`;
  `Utils.dll` `2539899f22be0488d7b63783a988adc2b0a72f58d04984b955287fe257d85578`.
  Image base `0x10000000`.
- The tool was direct headless Ghidra 12.1.2 with Homebrew OpenJDK 21, using a
  separate project in ignored `Library/Research/ghidra-projects-render`. Auto
  analysis took 89 s. A small script (ignored
  `Library/Research/ghidra-render/scripts/RenderResearch.java`) wrote
  pseudocode, instruction listings with the referenced data, and xrefs to
  `Library/Research/ghidra-render/pass1` … `pass11` and `utils1`. This is
  **not REA Evidence** and not original source. Each critical condition was
  rechecked in the instruction listing.
- The INIs are the installed `render1.ini`–`render40.ini`.
  `Tools/decode_pga2005_render.py` decodes them with the engine's reader rules
  and writes the numbers-only `Library/Imported/pga2005/render/presets.json`.
  `Tests/test_pga2005_render.py` covers it.
- Hardware: the analysis and Python tests ran on the development Mac. Nothing
  was rendered and nothing was measured on the M1 target.
- **Confidence levels.** **High**: read directly from instructions and data.
  **Medium**: the data flow is clear, but the visual result or a runtime flag
  depends on code outside Engine.dll, such as the protected `TW2005.exe`.
  **Low**: inference.

## 1. Objects and reader semantics (high)

`RenderKernel::LoadTimeRenderSettings` (`0x1007b8a4`) keeps five slot objects
for the current weather row. For each slot it calls `CGlobalRenderSettings::Init`
(`0x101e6597`) and then `UpdateFromIni` (`0x101e87d0`). The scene reads one
**active** object at `0x1044f690`.

`RenderCommand::AdjustTimeOfDay` (`0x1005cde1`) does the following:

1. It copies the lower slot's `SKYTYPE` into active `+0x4` and into
   `CGameSettings+0x11` (the `SkyType` byte, accessor `0x1001abf0`). If the
   value changed, it calls `CRManager::ReCreateSkydome` (`0x1005ceb9`–`0x1005ceee`).
2. It calls `Lerp(active, lower, upper, blend)` (`0x1005cf29`).

Rules for INI reads (all addresses in Engine.dll unless marked Utils):

- **Floats** (`FUN_101e77bc`): the value is the C `atof` prefix. If
  `|v| <= 1e-5`, the target keeps its previous value. A written `0` therefore
  never overrides a default (for example `deltaU=0`, `ShadowMap Rotation=0`).
- **Ints** (`FUN_101e7798`): `GetInt`, using the current value as the default.
- **Colours** (`ProfileC::Get4Tuple`, Utils `0x10011ed0`): comma-separated
  tokens. A missing fourth component becomes **1.0**, so `.7,.7,.9` reads as
  alpha 1. The text `0,0,0,0` counts as absent.
- **Positions** (`ProfileC::GetPosition`, Utils `0x10011db0`): three values.
  If only two are given, they mean `(x, 0, z)`.
- **Pan fog fallbacks**: if `PanStart/End/Color` or `HPanStart/End/Color` is
  missing, the normal `Start/End/Color` is copied in (`0x101e8bf6`–`0x101e8d4a`).
- **Contrast flags**: the flag at `+0x194` (terrain) or `+0x1a1` (trees) is set
  only when `Scale` is read and `|Scale − 1| > 1e-4` (`0x101e8a99`,
  `0x101e8b38`). The flag is never cleared, and `Shift`/`MidValue` are ignored
  when deciding it. For example, `render26` (Scale 1, Shift 0.5) does not set
  the flag.
- **Init defaults** (`0x101e6597`) used when keys are absent:
  - fog start/end 0;
  - fog colour 180/172/160 ÷ 255;
  - contrast Mid/Shift 0.85, Scale 1;
  - Diffuse and SkydomeDiffuse 1,1,1,1;
  - flare opacities 0.2/1/1, SunSize 1;
  - flare slot sizes and positions are **random** (`random(200)/100+0.1`,
    `random(500)/100−1`).

## 2. What `Lerp` blends (`0x101ea673`, high)

`t` is the blend value from the weather note. "Lower" means the earlier
preset. "Active" means the field keeps whatever the active object already held.

| Active offset | INI source | Behaviour |
| --- | --- | --- |
| `+0x004` | `[SKY] SKYTYPE` | Not in Lerp. AdjustTimeOfDay takes it from lower (above). |
| `+0x164`, `+0x174` | `[GlobalLightingValues] Diffuse`, `SkydomeDiffuse` | Lerp (RGBA). |
| `+0x188/+0x18c/+0x190` | `[TerrainContrast] Scale/MidValue/Shift` | Lerp. |
| `+0x195/+0x199/+0x19d` | `[TreeContrast] Scale/MidValue/Shift` | Lerp. |
| `+0x194`, `+0x1a1` | contrast-enabled flags | **Active** (not touched). |
| `+0x184` | `[TreeAmbient] value` | Lerp, then `ftol` (truncated toward zero) (`0x101eaec5`). |
| `+0x1a2…+0x1b6` | Fog `Start, End, PanStart, PanEnd, HPanStart, HPanEnd` | Lerp. |
| `+0x1ba/+0x1ca/+0x1da` | Fog `Color, PanColor, HPanColor` | Lerp (RGBA). |
| `+0x1ea` | `gFogNumParticles` | Lerp, truncated. |
| `+0x1ee…+0x23e`, `+0x248…+0x250` | other `gFog*` floats and the illumination colours | Lerp. Then `DefineFogParametersFromIni`. |
| `+0x246/+0x247` | `gFogScreenAligned`, `gFogUseDistanceFog` | From lower. |
| `+0x274/+0x278/+0x284`, `+0x294` | ShadowMap `Rotation/HeightScale/ClampValue`, BumpMap `Scale` | Lerp. |
| `+0x27c`, `+0x288` | ShadowMap `CenterUV`, `ShadowId` | **Active**. |
| `+0x290`, `+0x28c` | `[LensFlare] Enabled`, position-present flag | From lower. |
| `+0x298` | `[LensFlare] Position` | Lerp, only when lower is enabled. |
| `+0x2a4/+0x2a8/+0x2ac/+0x2b8` | `FlareOpacity, SunOpacity, CoronaOpacity, SunSize` | Lerp (always). |
| `+0x2b0/+0x2b4/+0x2bc` | `FlareCount, TextureCount, CoronaCount` | From lower. |
| `+0x2c0[32]` / `+0x340[32]` | `Flare{n}Size` / `Flare{n}Position` | Sizes from lower; positions lerp over **all 32 slots**. |
| `+0x3c0[41]`, `+0x464`, `+0x4e4`, `+0x4e8[8]`, `+0x508[8]` | flare textures, SunTexture, `Corona{n}Size`, corona textures | From lower. |
| `+0x008…+0x0dc` | golfer `Material*`, `Light{0-3}Direction/Diffuse/Ambient` (`[Golfer Shader Commmon]`) | Lerp. Directions are renormalised. |
| `+0x0ec/+0x0fc/+0x10c` | golfer light 0 direction/diffuse/ambient | Lerp. Sets D3D light 0 and `Render3D::SetSunPosition(−dir)`. |
| `+0x11c…+0x128`, `+0x04c` | depth bias, slope, self/ground shadow scales | Lerp. |
| `+0x12c[7]`, `+0x148[7]` | `[Fabric Shader]`, `[Skin Shader]` | Lerp. See the element 0 quirk below. |
| `+0x254/+0x264` | `[Flag] ambientColorShaft/Flag` | Lerp, then `WavingFlag2::SetAmbientTerms`. |
| `+0x551` | `[RainParameters] on` | From lower. |
| `+0x552/+0x556` | `[SkydomeAnimationControls] deltaU/V` | **Set to 0** (`0x101eb680`, `0x101eb690`). |
| `+0x528…+0x54c` | `[WaterParams]` | **Active**. |
| `+0x68a` | INI path | From lower. Used to reload rain. |

Quirks found in the instructions:

- **Golfer diffuse applied twice.** `UpdateFromIni` already multiplies golfer
  `MaterialDiffuse` by that preset's global `Diffuse`. `Lerp` blends those
  products and then multiplies by the blended `Diffuse` again.
- **Skin/Fabric element 0.** For `Light0Intensity`, `Lerp` starts from the
  lower preset's `AmbientFactor` (element 6), not from element 0
  (`0x101eae99`–`0x101eaebe`).
- **Flare slots past the upper preset's `FlareCount`** lerp toward that
  object's random Init values. This happens in afternoon→sunset blends,
  where 15 flares meet 2. The decoder keeps the lower position for such slots
  and sets `upper_slot_unset`.
- **Cloud scrolling stops.** `Lerp` zeroes the scroll. The skydome reads the
  active `deltaU/V` (`0x101c0179`, `0x101c0200`), so cloud scrolling stops
  after any `AdjustTimeOfDay`. Two calls could restore it:
  `ReloadRenderSettings` (`0x1005cd70`, which reloads
  `render<CGameSettings+0x11>.ini`, that is `render<SKYTYPE>.ini`) and
  `LoadIniRenderSettings` (`0x101ea2ef`). Both are named in the protected
  `TW2005.exe`. Medium confidence on the visible result.
- **Time.** Time advances only at `StartHole`/`ResumeHole`, through
  `UpdateWeatherAndTime` (`0x1005d09b`), as the weather note describes.
  Engine.dll has no per-frame time-of-day animation. `TW2005.exe` also names
  `AdjustTimeOfDay`, so medium confidence that no other driver exists.

## 3. Terrain and tree vertex lighting (high for formulas, medium for the flag)

**Terrain.** The lighting is baked into the TCR vertex RGB (bytes 9–11 of the
20-byte vertex; see PGA2005-REA). `CRTerrain::CreateVertexBuffers_Terrain`
(`0x101c60ab`) calls `VBAddPolys_Terrain` (`0x101c4be2`) for:

- the primary polyObject `patch+0x81` with `false` (`0x101c73fe`);
- the secondary polyObject `patch+0x79` with `true` (`0x101c743a`). This call
  happens only when `CRData+0x94` is set.

Each vertex colour then passes through `GlobalDiffuseContrastScaleTerrain`
(`0x101e710a`) for `false`, or `…Trees` (`0x101e7422`) for `true`. The result
has alpha forced to `0xff` and is written into the vertex buffer
(`0x101c4fdf`–`0x101c4ff8`). For each RGB channel:

```text
x = byte * 0.003921569                       // 1/255 as a float
if contrastFlag: x = clamp((x - Mid) * Scale + Shift, 0, 1)   // contrast_func1/2 0x10055180/0x100551f0
out = trunc(x * Diffuse[channel] * 255) & 0xff
```

The channels are paired R with Diffuse.r, G with .g and B with .b. Alpha
without contrast is `trunc(a/255·Diffuse.a·255)`.

On the vertex-shader path, `CRTerrain::SetColorXfrmConstants` (`0x101c947e`)
sets two constants:

- `c7` = the same function applied to white, divided by 255;
- `c8` = `(Fog.Start, Fog.End, 1/(End−Start), 0)`.

The colours are fixed when the vertex buffers are built. A Metal port can
evaluate the same expression per vertex using uniforms.

**Trees.** `CRVegetation::FillDiffuseBuffers` (`0x101d2ab4`, checked in the
instruction listing at `0x101d2c8f`–`0x101d2d67`) does the following for each
baked lighting byte `b`:

```text
g = b + TreeAmbient
if !veg[+0x82e] && !veg[+0x82d]: g *= 2       // default path
if veg[+0x82d]: g += 0x37
colour = (0xff, g & 0xff, g & 0xff, g & 0xff)  // built BEFORE the clamp to 255, so it wraps
if !CCourse.IsInTPViewer: colour = GlobalDiffuseContrastScaleTrees(colour)
```

`IsInTPViewer` is `CCourse+0x574` (accessor `0x10019140`). `TreeAmbient` is 0
in all 40 presets, so the wrap needs a byte above 127.

`GlobalDiffuseContrastScaleTrees` is also called by these functions:

- `RenderHighGroupTreeMaterial` (`0x101d632d`);
- `RenderLowObjects` (`0x101d6b08`);
- `CreateLowLODBuffers` (`0x101cb811`).

`RenderLowObjects` also reads `Diffuse` directly.

**Other users of `Diffuse`.** The pan draw multiplies its texture factor by
it. `WavingFlag2::Draw` (`0x100a6fd4`) uses it too, as does the golfer
material (above). The skydome uses `SkydomeDiffuse` instead: `texture ×
TFACTOR` (`0x101bfe39`).

**Is contrast on in play? (medium–low).** The terrain and tree functions test
the flag in the **active** object. `Lerp` never writes that flag. In
Engine.dll, the only full INI load into the active object is
`InitUnivGolfer → LoadIniRenderSettings(99)` (`0x10070fb9`). `render99.ini`
has no contrast sections, so the flag would stay 0. The flag becomes 1 if the
protected front end calls `ReloadRenderSettings` or `LoadIniRenderSettings`
with any preset whose Scale ≠ 1. Five of the six `render<SKYTYPE>` files
qualify (all except render3), as do most presets. Recommendation: keep a
switch. Default it to "on when the blended `Scale` ≠ 1", which matches the
INI comments' intent, and settle it with an original-game screenshot.

## 4. Which objects get which fog (high)

| Fog | Objects | Code |
| --- | --- | --- |
| `[Fog] Start/End/Color`, D3D linear fog (mode 3) | Course scene: terrain, objects, golfer. The terrain shader uses `c8`. High-detail and faded trees read the same values. | `CRManager::SetRenderStates` `0x101b7e1d`; `0x101c9754`; `0x101d68b7`, `0x101d511d` |
| `PanStart/PanEnd/PanColor` | **Main panorama**: TCR pan block 0. Centred on its bounding box and rotated by `PanRotation(hole)`° at load. Each frame it is translated to camera x/z and `courseMinY − 12 + active[+0x586]`. Texture × `Diffuse`. | `CRPan` load `0x101b9978`, draw `0x101b8a48` (`SetFog` `0x101b8d0e`) |
| `HPanStart/HPanEnd/HPanColor` | **Per-hole panorama**: pan block `HolePanId(physical hole)` when non-zero. Drawn in world coordinates with an identity world matrix. | same draw, `SetFog` `0x101b9133` |
| none | Skydome: fog render state off, texture × `SkydomeDiffuse`. | `0x101c0035` |

After the pans are drawn, normal fog is restored (`0x101b9522`). Each colour
channel is clamped to 0..1 before ×255. This answers the panorama-placement
question left open in [PGA2005-OBJECTS.md](PGA2005-OBJECTS.md) §8. PBL's
blocks 1–18 are therefore the HPan meshes.

**Particle fog.** It applies when `gFogNumParticles > 0`: 250 in the foggy row,
9 in both rain rows. `DefineFogParameters` (`0x100ad13f`) clamps the count to
0..40. It scales particle alpha by 0.68 in 32-bit colour, or by 1.54 (capped
at 1) in 16-bit. `Fog1Manager::NextFrame` (`0x100ae769`) does two more things:

- When `gFogUseDistanceFog` is set, it **overwrites** the active fog Start/End
  with `gFogNearFogPlane/FarFogPlane` (`0x100aea28`). In every shipped preset
  with particles, these equal Start/End. The decoder test checks this.
- When the fog flag (`[Fog] Enabled`, render-settings flag `0x400`) or the
  user fog option is off, it writes Start 1000 / End 115000 instead
  (`0x100ae85f`).

## 5. Lens flare (high for geometry, medium for occlusion use)

**Enable.** The flare is drawn only when all of these hold:

- active `Enabled` is set (taken from the lower preset);
- the global flag at `0x1037bcc0` is set (initially 1);
- the sun texture is loaded;
- the user's `CRenderSettings::LensFlare` option is on (`0x100bf219`).

Rows 1–4 (clear to cloudy) are enabled. Rows 5–8 are not.

**Sun world point (normal play).** The skydome draw (`0x101c0739`–`0x101c0790`)
transforms the preset `Position` through the **dome world matrix**. The
result is stored at `CRData+0x9a`, and `LensFlare::NextFrame` reads it
(`0x100bf38f` branch):

```text
P = Position if present else (74831.23, 18868.85, 156948.27)
sun = (P.x*ScaleX + cam.x - domeCentre.x,  P.y + courseMinY + SkyDome.YOffset,  P.z*ScaleZ + cam.z - domeCentre.z)
```

The sun therefore follows the camera in x/z, like an infinitely distant
direction, but sits at a fixed height above the course's lowest point. Seen
from course-minimum height, the shipped positions are low suns:

| Position | Elevation | Azimuth (from +Z toward +X) |
| --- | ---: | ---: |
| 40000,12000,50000 (sunrise and sunset) | 10.6° | 38.7° |
| 75000,25000,160000 (morning, afternoon) | 8.1° | 25.1° |
| 75000,40000,160000 (noon) | 12.8° | 25.1° |
| cloudy row 75000,{12000/25000/40000},50000 | 7.6° / 15.5° / 23.9° | 56.3° |

In the TP course viewer (`CCourse+0x574`) the sun is instead placed at
`camera − 180000 · Render3D sun position`, using the golfer light-0 direction.

**Screen projection** (`NextFrame`). The steps are:

1. Reject the flare if `dot(sun − cam, camForward) < 0`.
2. Project with `TransformGlobalToScreen`.
3. Reject if the projected point lies outside the screen expanded by `W/8` on
   every side.
4. The sun quad is `(x ± 8·SunSize, y ± 8·SunSize)` in **absolute pixels**
   (`0x100bf7e5`–`0x100bf8a0`). A 2560 × 1600 port must choose a scale. The
   occlusion code's `/800` suggests an 800-pixel-wide reference.

**Layout** (`LensFlare::Draw` `0x100be5c6`). Let `S` be the sun's screen point
and `C = (W/2, H/2)`. All quads are white-tinted.

| Element | Count | Centre | Half size | Blend | Alpha |
| --- | --- | --- | --- | --- | --- |
| Sun | 1 | S | `8·SunSize` px | SRCALPHA / INVSRCALPHA, Z test on | `SunOpacity` |
| Corona i | `CoronaCount` | S, rotated by `(i+5)·θ`; θ comes from `APosition::Rotate(camera orientation)` | `tex.wh · Corona{i}Size · 0.5` | SRCALPHA / ONE | `CoronaOpacity` |
| Flare i | `FlareCount` | `C + (C − S)·Flare{i}Position`: −1 = sun, 0 = centre, +1 = mirror | `tex.wh · Flare{i}Size · 0.5` | SRCALPHA / ONE | `FlareOpacity` |

Texture numbers are 1-based into `Texture1..N`. The engine stores
`min(n−1, 40)` and has no lower clamp. `Flare{i}Texture` keys that are
missing reuse the previous index.

**Occlusion** (`CalculateOcclusionFactor` `0x100c03d9`,
`GetSunOcclusionFactor` `0x100c0ec8`). The engine renders 16 × 16 targets
looking from the camera at the sun, with the field of view scaled by
`16/800`:

- a cached pass draws trees and/or terrain in black on white, controlled by
  the "occlusion by trees/terrain" options. It redraws when the camera moves
  or turns, or when forced;
- a per-frame copy adds the golfers;
- a third pass accumulates the result additively.

The CPU function returns a constant 1.0, so nothing is read back. In `Draw`,
coronas and flares sample a stage-1 texture (`this+0x73`) multiplied into
their colour when `0x103854fc == 0`. This is the GPU occlusion path. No
temporal fade was found. Medium confidence on the exact use of the
accumulated texture.

## 6. Rain (high)

- **On/off** comes from the lower preset (rows 7–8). `AdjustTimeOfDay`
  (`0x1005cf3d`–`0x1005cfe8`) re-reads `[RainParameters]` from the lower
  preset's file each time the slot changes. Values are **not** blended.
- **Drop pool.** `m_density` sets the pool size: `trunc(m_density · 10000)`
  drops (`0x100cd0d4`). Light rain gives 1,500 drops, heavy rain 9,500.
- **Active count per frame** (`0x100cd61c`–`0x100cd74b`). `L` is the user
  rain-detail byte and `m` is whole minutes of tick time:
  `clamp(trunc(trunc(pool·L/4) · (0.2·cos 3m + 0.6·sin m + (pool > 6000 ? 1 : 0.5))), 1000, 10000)`.
- **Spawn** (`0x100ce02b`). Drops are placed around the camera:
  - radius `U(20, rainDistance)`, angle `U(0, 2π)`;
  - `y = U(0, rainDistance)`; on respawn, `U(rainDistance/2, rainDistance)`;
  - wind factor `U(0.9, 1.1)`;
  - colour = `m_color` RGB, ignoring its alpha.
  - alpha = `min(1, 0.4 + 0.6·(1 − d²/rainDistance²))`, where `d` is the
    drop's spawn distance.
- **Update** (`0x100cd2c7`). Each frame, `x += dt·windX·f`,
  `y −= dt·dropVelocity` and `z += dt·windZ·f`. Below `rainBottom`, a drop
  makes a ripple (at most 100 per frame) and respawns. The wind vector is
  `normalize(windDir) · mph · 17.6 · 0.468` in inches per second
  (`0x101ba010`).
- **Draw** (`0x100cdced`, `0x100cd5e5`). Each drop is a line from `p` to
  `p + (windX·f·dropLength/dropVelocity, −dropLength, windZ·f·…)`. The lines
  use alpha blending, a camera-centred view and no world translation.
  `dropSize`, `minDensity` and `maxDensity` are stored, but no reader was
  found in these routines.

## 7. Front-end option names (high)

Language.dll string IDs 33050–33054 hold the time names sunrise, morning,
noon, afternoon and sunset. IDs 33060–33067 hold clear, fair, partly cloudy,
cloudy, foggy, overcast, light rain and heavy rain. This is the same order as
the preset rows and slots. Help strings 20266 and 20267 describe a round
weather and a **starting** time of day, which fits per-hole advancement.
Event weather (29960–29963) and the course-condition lists (29724–29762) are
separate menus. Their mapping to the setting bytes is in the protected exe.

## Preset table (decoded effective values)

Generated by `python3 Tools/decode_pga2005_render.py --table`. "Terrain
contrast … on" is the per-file flag rule from §1. All presets have
`[Fog] Enabled=1` and `TreeAmbient=0`. The tree contrast is 1/1/1, so it is
off everywhere.

| # | Weather / time | SKY | Fog start–end | Fog colour | Diffuse | Terrain contrast (mid/shift/scale, on) | Flare | Flare position | Rain |
| ---: | --- | ---: | --- | --- | --- | --- | ---: | --- | ---: |
| 1 | clear / sunrise | 1 | 3000–125000 | 0.43,0.43,0.5 | 0.7,0.7,0.9,1 | 1/1/0.5, yes | 1 | 40000,12000,50000 | 0 |
| 2 | clear / morning | 1 | 4000–137000 | 0.43,0.43,0.5 | 0.9,0.9,0.95,1 | 1/1/0.5, yes | 1 | 75000,25000,160000 | 0 |
| 3 | clear / noon | 1 | 5000–150000 | 0.43,0.43,0.5 | 1,1,1,1 | 1/1/1, no | 1 | 75000,40000,160000 | 0 |
| 4 | clear / afternoon | 1 | 4000–137000 | 0.53,0.53,0.4 | 1,1,1,1 | 1/1/0.5, yes | 1 | 75000,25000,160000 | 0 |
| 5 | clear / sunset | 1 | 3000–125000 | 0.53,0.53,0.4 | 1,0.85,0.8,1 | 1/1/0.5, yes | 1 | 40000,12000,50000 | 0 |
| 6 | fair / sunrise | 2 | 5000–125000 | 0.43,0.43,0.5 | 0.7,0.7,0.9,1 | 1/1/0.5, yes | 1 | 40000,12000,50000 | 0 |
| 7 | fair / morning | 2 | 4000–100000 | 0.43,0.43,0.5 | 0.9,0.9,0.95,1 | 1/1/0.5, yes | 1 | 75000,25000,160000 | 0 |
| 8 | fair / noon | 2 | 3000–85000 | 0.43,0.43,0.5 | 1,1,1,1 | 1/1/1, no | 1 | 75000,40000,160000 | 0 |
| 9 | fair / afternoon | 2 | 4000–100000 | 0.5,0.5,0.4 | 1,1,1,1 | 1/1/0.5, yes | 1 | 75000,25000,160000 | 0 |
| 10 | fair / sunset | 2 | 5000–135000 | 0.47,0.47,0.4 | 1,0.85,0.8,1 | 1/1/0.5, yes | 1 | 40000,12000,50000 | 0 |
| 11 | partly_cloudy / sunrise | 3 | 3000–100000 | 0.43,0.43,0.5 | 0.7,0.7,0.9,1 | 1/1/0.5, yes | 1 | 40000,12000,50000 | 0 |
| 12 | partly_cloudy / morning | 3 | 3500–107000 | 0.43,0.43,0.5 | 0.9,0.9,0.95,1 | 1/1/0.5, yes | 1 | 75000,25000,160000 | 0 |
| 13 | partly_cloudy / noon | 3 | 4000–115000 | 0.43,0.43,0.5 | 1,1,1,1 | 1/1/1, no | 1 | 75000,40000,160000 | 0 |
| 14 | partly_cloudy / afternoon | 3 | 3500–107000 | 0.53,0.53,0.4 | 1,1,1,1 | 1/1/0.5, yes | 1 | 75000,25000,160000 | 0 |
| 15 | partly_cloudy / sunset | 3 | 3000–100000 | 0.53,0.53,0.4 | 1,0.85,0.8,1 | 1/1/0.5, yes | 1 | 40000,12000,50000 | 0 |
| 16 | cloudy / sunrise | 4 | 5000–125000 | 0.33,0.33,0.5 | 0.72,0.7,0.8,1 | 1/1/0.5, yes | 1 | 75000,12000,50000 | 0 |
| 17 | cloudy / morning | 4 | 3500–100000 | 0.43,0.43,0.5 | 0.75,0.73,0.8,1 | 1/1/0.5, yes | 1 | 75000,25000,50000 | 0 |
| 18 | cloudy / noon | 4 | 3000–85000 | 0.43,0.43,0.5 | 0.85,0.85,0.85,1 | 1/1/0.5, yes | 1 | 75000,40000,50000 | 0 |
| 19 | cloudy / afternoon | 4 | 3500–100000 | 0.53,0.53,0.4 | 0.82,0.8,0.9,1 | 1/1/0.5, yes | 1 | 75000,25000,50000 | 0 |
| 20 | cloudy / sunset | 4 | 5000–125000 | 0.53,0.53,0.4 | 0.75,0.7,0.7,1 | 1/1/0.5, yes | 1 | 75000,12000,50000 | 0 |
| 21 | foggy / sunrise | 5 | 1500–70000 | 0.3,0.3,0.35 | 0.7,0.7,0.8,1 | 1/1/0.5, yes | 0 | – | 0 |
| 22 | foggy / morning | 5 | 1700–80000 | 0.4,0.4,0.4 | 0.8,0.8,0.8,1 | 1/1/0.5, yes | 0 | – | 0 |
| 23 | foggy / noon | 5 | 2000–100000 | 0.5,0.5,0.5 | 0.8,0.8,0.8,1 | 1/1/0.5, yes | 0 | – | 0 |
| 24 | foggy / afternoon | 5 | 1700–75000 | 0.4,0.4,0.4 | 0.8,0.8,0.8,1 | 1/1/0.5, yes | 0 | – | 0 |
| 25 | foggy / sunset | 5 | 1500–60000 | 0.35,0.3,0.25 | 0.9,0.75,0.5,1 | 1/1/0.5, yes | 0 | – | 0 |
| 26 | overcast / sunrise | 5 | 5000–125000 | 0.43,0.43,0.5 | 0.82,0.8,1,1 | 1/0.5/1, no | 0 | – | 0 |
| 27 | overcast / morning | 5 | 3500–100000 | 0.43,0.43,0.5 | 0.9,0.9,0.95,1 | 1/1/1, no | 0 | – | 0 |
| 28 | overcast / noon | 5 | 3000–85000 | 0.48,0.48,0.5 | 1,1,1,1 | 1/1/1, no | 0 | – | 0 |
| 29 | overcast / afternoon | 5 | 3500–100000 | 0.5,0.5,0.45 | 1,1,1,1 | 1/1/1, no | 0 | – | 0 |
| 30 | overcast / sunset | 5 | 5000–125000 | 0.51,0.51,0.42 | 1,0.85,0.8,1 | 1/1/1, no | 0 | – | 0 |
| 31 | light_rain / sunrise | 5 | 1500–70000 | 0.4,0.4,0.37 | 0.7,0.7,0.67,1 | 1/1/0.5, yes | 0 | – | 1 |
| 32 | light_rain / morning | 5 | 1700–80000 | 0.6,0.6,0.6 | 0.8,0.8,0.75,1 | 1/1/0.5, yes | 0 | – | 1 |
| 33 | light_rain / noon | 5 | 1700–75000 | 0.6,0.6,0.6 | 1,1,1,1 | 1/1/1, no | 0 | – | 1 |
| 34 | light_rain / afternoon | 5 | 1700–80000 | 0.6,0.6,0.6 | 0.8,0.8,0.85,1 | 1/1/0.5, yes | 0 | – | 1 |
| 35 | light_rain / sunset | 5 | 1500–70000 | 0.4,0.4,0.37 | 0.7,0.7,0.67,1 | 1/1/0.5, yes | 0 | – | 1 |
| 36 | heavy_rain / sunrise | 6 | 2000–100000 | 0.15,0.15,0.15 | 0.7,0.7,0.7,1 | 1/1/0.5, yes | 0 | – | 1 |
| 37 | heavy_rain / morning | 6 | 1700–75000 | 0.3,0.3,0.3 | 0.78,0.78,0.78,1 | 1/1/0.5, yes | 0 | – | 1 |
| 38 | heavy_rain / noon | 6 | 1500–70000 | 0.4,0.4,0.4 | 0.9,0.9,0.9,1 | 1/1/0.5, yes | 0 | – | 1 |
| 39 | heavy_rain / afternoon | 6 | 1700–75000 | 0.3,0.3,0.3 | 0.78,0.78,0.78,1 | 1/1/0.5, yes | 0 | – | 1 |
| 40 | heavy_rain / sunset | 6 | 2000–100000 | 0.15,0.15,0.15 | 0.7,0.7,0.7,1 | 1/1/0.5, yes | 0 | – | 1 |

The full data is in `presets.json`, including SkydomeDiffuse, Pan/HPan fog,
particle fog, all flare elements, rain, skydome scroll, ShadowMap and the
golfer light 0. The `lerp` block in that file lists the §2 categories in a
form a renderer can read.

## Open questions

- Whether the protected `TW2005.exe` calls `ReloadRenderSettings` or
  `LoadIniRenderSettings` during play. Its strings name both. The answer
  decides whether terrain contrast is on and whether clouds scroll (§2, §3).
- The default weather and time bytes (`CGameSettings+0x125/+0x126`) for a
  quick round. They are set by the front end, not by Engine.dll.
- The `CRVegetation+0x82d/+0x82e` tree modes, and the stage-1 occlusion
  texture binding (`this+0x73`) together with its `0x103854fc` gate.
- Rain `dropSize`, `minDensity` and `maxDensity` consumers.
- Visual confirmation of every formula against original-game frames. Any
  2560 × 1600 Metal implementation still needs **M1 performance
  verification**.
