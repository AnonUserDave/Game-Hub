# PGA Tour 2005 audio: events, formats and import

Observed 2026-10-13 from the locally supplied media by static analysis only.
No installer, game executable or original code was run. Decompiler output is
Ghidra pseudocode from a copy of the physics project
(`Library/Research/ghidra-projects-audio/pga2005-audio`, read-only `-process`).
Raw exports are in `Library/Research/pga2005-audio/ghidra/`.

| Module | SHA-256 |
| --- | --- |
| Engine.dll | `94aa30bb645ea089fed6e98df0dce38d75c309e4531386cbe33c07f65bd19728` |
| CourseData.dll | `36664435b88646e6b96d55f81573e1fdb73ee88e7f54762c4a723c693832e82c` |
| Utils.dll | `2539899f22be0488d7b63783a988adc2b0a72f58d04984b955287fe257d85578` |
| basic.stn | `8088e85fbf1c5199b444063c9b36c286f72a0fc5bd9425a2a8daea289fc4288d` |
| gallery.stn | `73b552f334ca329d7cf397482c8d86ac8704b184acf7e922d8760acad8bae0dd` |
| music.stn | `e3ecb6bdfbc8a8792de90bdcfff747f4ce38260c7d0c0d7d04be54ee31144a05` |

## Summary

Almost all audio behavior is **data-driven**. Three EA "situation script"
files (`*.stn`) decide which sound plays for which game event. They are
binary rule tables, not Hitachi COFF objects as `file(1)` claims. Course
ambience is defined per course in `COURSES/<CODE>/SND.INI` and
`CLS/CLS.INI` on the courses disc, not in the TCR/TCL files. The Engine
holds the rule interpreter, the per-channel volume sliders, the 3D distance
constants and the interface-sound table.

The terrain **sound id** (TCL surface `+0x2c`, falling back to the texture
section's word at `+0x23`) is matched against `basic.stn` collision rules. It
is not a file index. Ids 801–919 are rule keys.

## Formats

| Source | Codec | AVFoundation | Importer action |
| --- | --- | --- | --- |
| `Sounds_-_Basic` (146 WAV) | PCM s16 mono, 22.05 kHz (one at 44.1 kHz) | yes | copy |
| `Sounds_-_Gallery` (57 WAV) | PCM s16 mono 22.05 kHz; one has `cue `/`LIST` chunks | yes | copy/rewrite |
| `Sounds_-_Interface` | 13 PCM WAV (6 stereo `TPCamTrans*`), **`scale.wav` is MS-ADPCM (tag 2)**, `KaChing.mp3` | MS-ADPCM uncertain | decode to PCM |
| `Courses_-_Generic/Sounds` (360 WAV) | PCM s16 at 6/8/11.025/12/14/16/22.05 kHz; many carry `wsmp`/`LIST`/`smpl` or zero-filled junk after `data` | yes after cleanup | rewrite as canonical fmt+data |
| `Sounds_-_Music` | MPEG-1/2 layer III, `music.stn`, `gameface.mus` | MP3 yes | copy MP3 (opt-in) |
| `Sounds_-_Commentary` (3,288 MP3 + `announcer.stn`/`analyst.stn`) | MP3 | yes | 3,216 referenced MP3s copied unchanged to `commentary/`; rules in `commentary.json` ([PGA2005-COMMENTARY.md](PGA2005-COMMENTARY.md)) |
| `Sounds_-_Career` (37 MP3) | MP3 | yes | not imported |
| `Miles_Sound_components` | Miles 6 providers (`mssmp3.asi`, `msseax.m3d`, …) | n/a | none |

There is no IMA-ADPCM and no EA-proprietary codec (SCHl/ASF) among the WAVs.
The importer still has an IMA/DVI decoder (tag 0x11) for provided directories.
The MS-ADPCM decoder matches Core Audio's `afconvert` output for `scale.wav`
in all 1,804 samples. The `fact` chunk gives 1,804 frames; `afconvert` ignores
it and pads to 2,024. Core Audio on this Mac can decode MS-ADPCM, but the
importer converts it anyway so playback does not depend on that codec.

`gameface.mus` (3,446,073 bytes) begins with 0x17c bytes of `0xAA` padding and
then contains high-entropy data with no RIFF, MPEG frame chain, Ogg or EA
SCHl signature. No string in Engine.dll, TW2005.exe or the front-end
`FEnd.xbx` names it. It is probably unused GameFace-mode music in an unknown
format. **Not decoded.**

## Situation script format (`*.stn`)

`Script::LoadSituationFile` 0x10207822 reads a 0x1c-byte header of seven
u32 values: version, situation count/offset, action count/offset and
response count/offset. All three files are version `0x00010005`.

* **Situation**: 0x5b bytes for versions 0x10002–0x10005, otherwise 0x56
  (`LoadSituations` 0x10207d65; ctor 0x102158fd). The fields are:
  * `+0` event class (u8) and `+1` event sub-type (u8, 0 = any);
  * `+2` u32 condition mask, with bit 31 meaning "match any bit";
  * `+6` 10 × u16 operators and `+0x1a` 10 × u32 values, in mask-bit order;
  * `+0x42` 10 × u16 action ids, ended by `0xfff0`;
  * `+0x56` u32 flags, where bit 0 means "choose one action at random"
    (`IsSingleAction` 0x1020d885);
  * `+0x5a` u8 priority, where **lower wins**.
* **Operators** (0x10215b87): 1 `==`, 2 `!=`, 3 event > value, 4 event < value,
  5 `event & v != 0`, 6 either is non-zero, 7 `~event & v != 0`,
  8 `event & v == 0`.
* **Action**: 0x57 bytes (`LoadActions` 0x102080bd; ctor 0x10215e27). Fields
  are `+0` type (u8), `+1` probability percent (u8), `+2` u32 flags and `+6`
  30 × u16 response ids. Type 12 is a link to another script.
* **Response**: 63 bytes (`LoadResponses` 0x1020b3e4; `BuildResponseObject`
  0x10209157). Fields are `+0` type, `+1` u32 mode and `+5` a NUL-terminated
  file name. Mode 1 means static/preloaded, mode 2 means loop and mode 0 means
  stream (`SoundResponse::Init` 0x102171bc). Types 1, 9 and 13 are non-audio
  commands, 8 is an SND.INI index and 16 links into another `.stn`.
* After the tables come the editor descriptions, NUL-separated, **in record
  order** (situations, actions, responses), then zero padding. The importer
  uses these descriptions to name events, so no table order is assumed.

### Event classes and value bits

Each event class builds a compact value array; condition *n* compares the
value for the *n*-th set mask bit.

| Class | Producer | Bits |
| --- | --- | --- |
| 1 swing (sub 3) | `ClubSwing` 0x1006e370, builder 0x1021424d | bit 0 club mask (0x1021038a: 1 driver, 2 wood, 4 iron/wedge, 0x10 putter); bit 1 swing flags (0x10 toe, 0x20 heel, 0x2000 flop); bit 2 lie flags (0x9000 = tee box \| on tee, 2 rough, 8 bunker, 0x80000000 weed/pine); bit 5 power % (= swing+0x305 / 14 × 100) |
| 2 shot (sub 1 in flight, 2 stopped, 19 before the shot) | `ShotEvent` builder 0x102146cb (decoded in [PGA2005-COMMENTARY.md](PGA2005-COMMENTARY.md)) | compact values (mask 0x6fffffdf): bit 3 = bit 15 inches to pin, bit 4 = bit 22 shot length, bit 6 hole, bit 7 par, bit 8 strokes, bit 9 score code, bit 10 miss side, bit 12 **flight index**, bit 21 terrain at the (precalculated) end |
| 3 ball collision (sub 4) | `CGolfBall::CheckForCollisionSound` 0x10136ed0, builder 0x102137ad | bit 2 sound id, bit 5 impact % (= magnitude / 0.5 × 100), bit 21 terrain flags at the impact |
| 5 background (sub 6/7/8) | `SituationCommand::BackgroundNoise` 0x1006d5c3, builder 0x1021502f | bit 6 hole number, bit 13 wind speed, bit 14 rain state |
| 6 music state | `CSoundCommand::StartMusic` 0x100707e5 | sub = state (9 menus/intro, 20 end of game) |

The collision FIFO types pick the sound id this way:

* Type 1 (terrain) uses `GetTerrainSound(material, 0)`.
* Type 3 (structure) uses `StructureProps+0x2c`.
* Type 4 (flagstick) uses the hard-coded id 804 (0x324).
* Type 2 sends sub 5 with an object-supplied id. No `basic.stn` rule uses
  sub 5.

### Rule selection and randomization (hard-coded interpreter)

1. `FindSituationsMatching` 0x1020bfe3 collects the enabled situations of the
   event class whose sub-type and conditions match.
2. `DoSituationsMatching` 0x1020c1df chooses among them:
   * the lowest priority byte wins;
   * on a tie, the situation with **more** conditions wins;
   * then the least-fired one wins, and any remaining tie is broken at random.
3. Each action runs, or only one random action if situation flag bit 0 is set.
   The action runs only if `random(100)+1 <= probability`
   (`ScriptAction` exec 0x102160a5).
4. One response is picked **uniformly among the variants with the fewest plays
   so far** (0x10216d78, using `random()` from Utils.dll). This is how
   BallFWay1/2/3 rotate: no variant repeats until every variant has played.
   Action flag 0x4000 plays all responses as a sequence instead.

## Event table (imported into `audio.json`)

All `basic.stn` responses are type 2, which uses the **Ambient** slider, and
have a volume scale of 1.0. Swing and collision sounds are 3D at the
player/impact position.

| Event | Files (variants) | Condition (decoded) |
| --- | --- | --- |
| swing.driver.tee / _25 / _50 / _75 / _perfect / _heel / _toe | DrTee100EA01 / Dr25EA01a / Dr50EA01 / Dr75EA01 / DrTee100PEA02 / DrHeelEA01 / DrToeEA01 | driver on tee; power > 90 / > 0 / > 89 / > 94 / > 99; heel/toe flags; priorities 97/100/99/98/96/99/99 |
| swing.driver.generic, swing.wood.generic | WdFWayEA02 | driver or wood off the tee |
| swing.wood.tee / tee_perfect / generic_perfect | WdTee100 / WdTee100PEA01 / WdFWayPEA01 | wood; power > 0 / > 99 |
| swing.iron.tee* (5) | IronTee100EA01, Iron25/50/75EA01, IronTee100PEA01 | iron on tee; power thresholds 0/60/75/90/99 |
| swing.iron.generic, unknown_lie | IronFWay | iron (priority 101), lie flags == 0 |
| swing.iron.rough / rough_hard / sand / pine_needles | WdgRuf1-3 / IronRuf1-2 / WdgSand1-3 / IronPine1-3 | lie 0x2 with power < 50 or > 49 / lie 0x8 / lie 0x80000000 |
| swing.putt.hard / soft | PuttHard1-3 / PuttSoft1-3 | putter, power > 3 / < 3 |
| swing.flop | Iron75EA01 | swing flag 0x2000 |
| ball.cup | BallCup1 | class 0 sub 16 |
| ball.hit.fairway (generic fallback) | BallFWay1-3 | any collision with impact > 40 %, priority 101 |
| ball.hit.green_hard / green_soft | BallGreen{1-4}a / {1-4}b | id 902, impact > 40 / < 40 |
| ball.hit.rough / sand | BallRufEA1-4 / BallSand1-3 | id 905 / 904, impact > 40 |
| ball.hit.water | BallWater1-4 | id 903 **and** terrain flag 0x40 |
| ball.hit.cartpath / cement | BallPath1-2 | id 908 / 813 |
| ball.hit.branches | BallBranch1-9 **plus** BallLeaf1-2 (both actions) | id 914 |
| ball.hit.brush / trunk | BallBrush1-5 / BallTrunk1-6 | id 910 / 801 |
| ball.hit.flag / pin | BallFlag / BallPin | id 803 / 804 (flagstick FIFO type 4) |
| ball.hit.metal / pipe / glass / wood / wooden_sign | BallMetal1-5 / BallMetal1-5 / BallGlass1-3 / BallWood / BallWdSign | id 814 / 919 / 812 / 906 / 808 |
| weather.wind_strong / gusty | wind_strong / wind_gusty (loop) | class 5 sub 6: wind > 19 (with hole > 0) / > 11 |
| weather.rain_light / heavy | rain_light / rain_heavy (loop) | rain state 1 / 2 |
| camera.gamebreaker | gamebreaker_start | class 2 shot-result rules (the "Bling Bling" and "Drama" camera transitions) |

Rules that require "not fairway" (`~flags & 1`) push fairway impacts to the
generic BallFWay rule. In PBL/TUR the surfaces map as follows:

* Fairway is 901, which no rule names.
* Green, fringe and tee box are 902; sand is 904 and rough is 905.
* Roads, cliffs and rock are 908.
* Wood structures are 808, glass 812, stucco 813, metal 814 and railings/poles
  804. The rail ties are 906.
* The ocean is **−1 on PBL** (no water rule can match) and 903 on TUR.

The full per-course `surface_sound_ids` table is in `audio.json`.

**Crowd (`gallery.stn`, 199 rules)**: type-12 responses use the **Crowd**
slider. Gallery file names encode the start and end of the crowd animation
in milliseconds. For example, `PGAChrHg06_0250013400` gives
`GalleryManager::SetStateIndirect(5, 2500, 13400)` (0x102160a5 case 9). The
curated events are:

* `hole_out`, `chip_in`, `putt_made`, `putt_made_long`;
* `approach_close`, `approach_good`, `approach_green`;
* `drive_long_fairway`, `drive_fairway`, `drive_bunker`, `drive_out_of_bounds`;
* `water`, `mishit`, `putt_near_miss`, `putt_big_miss`;
* `background_cheer`, which is class 5 sub 7 at 15 % and is placed 750–3000
  units from the listener.

All 31 crowd files that the rules can play are imported.

**Interface**: these sounds are hard-coded in `CSoundCommand::Play(InterfaceSounds)`
0x10070247. The enum values are 1 select, 2 accept, 3 back, 4 highlight,
5 click, 6 scale (MS-ADPCM), 7 back again and 8 KaChing.mp3. Each uses type 2
and mode 1. `Cancel.wav`, `chat.wav` and `TPCamTrans1-6` are referenced
nowhere. Linking "scale" to a swing meter is **unverified**: PGA 2005 has no
classic three-click meter.

**Music (`--music`)**: `music.stn` class 6 sub 9 picks the least-played of
Shell1–5.mp3 (looping, **Music** slider). Sub 20 (end of game,
`PlayEndGameMusic` 0x10070b77) picks between `endmus.wav` and EndMus1.mp3.
`endmus.wav` resolves to EndMus.mp3 through the engine's `.wav` → `.mp3`
fallback in `SetAbsolutePath` 0x10217277. Shell6–10 are referenced but absent.
Legends.mp3 is unreferenced.

## Course ambience (Pebble Beach and Turnberry)

`Script::BuildLookupFromIniData` 0x1020a045 loads `<course>\snd.ini` (TUR's
`XSND.INI` is ignored). It reads three kinds of section:

* **Folder sections** such as `[amb_ocean_loop]` set `frequency` (default
  100), `volume` (default 100) and `loop`.
* **`[Sound N]` sections** become one class-5 situation each, with condition
  `hole == N`, and one type-2 action with probability = frequency.
  `volume/100` becomes the response volume scale, and `loop=1` gives mode 2.
* **Type 4 emitters** (all PBL/TUR entries) use `point0` as the centre in INI
  feet. World = `(x·12 − origin.x, y·12, z·12 − origin.z)`, with the origin at
  TCR `0x318`. `point1.x` is a **radius in inches** and is not converted.
  `GetCourseIniSoundPosition` 0x1020ef78 plays the sound at the centre only if
  the listener (camera) is within the radius.
* A centre of (0,0,0) is never converted. It skips the radius test and becomes
  a 2D sample: a hole-wide ambience bed.

| Course | Emitters | Global beds | Folders (frequency %, volume %, loop) |
| --- | ---: | ---: | --- |
| PBL | 606 | 18 (`amb_generic`) | amb_generic 100/70 L, amb_ocean_loop 100/75 L, Snd_Vol2_Ocean 100/80 L, Amb_RandBirds 20/85, Amb_RandCrows 10/90, Amb_RandSeagulls 10/90, Amb_Leaves_Wind 20/80, Amb_RandWaves 25/70, amb_RandOcean 10/50, Seals&Whales 10/90, Amb_RandDogs 10/100, Amb_RandDogs02Louder 10/95 |
| TUR | 399 (5 silent) | 18 | amb_generic 100/70 L, amb_ocean_loop 100/70 L, Amb_Stream_Loop 100/20 L, Amb_TUR_Birds_Generic 20/90, Amb_TUR_Birds_Solo 15/90, Amb_RandSeagulls 15/85 (duplicate section; first wins), Amb_Leaves_Wind 20/90, Amb_RandWaves 20/80, Amb_ScottishSheep 10/80, Amb_TUR_Otter_Solo 10/75, Amb_Town02_NoBell 15/80, Amb_ScottishBagpipes 8/90, Amb_Scottishfoghorn 2/75, Amb_ScottishMonster 10/80, Amb_bees 30/70 |

The radii used are 2520, 3600, 4320, 5400, 7200, 9000, 10800 and 18000
inches. TUR `Sound 135`–`139` have `points=2` but no `point1`.
`ProfileC::GetPosition` (Utils 0x10011db0) zeroes the missing point, so the
radius is 0 and those emitters are silent in the original.

**Course Life System** (`CLS/CLS.INI`, PBL only) attaches sounds to animated
actors: BuzzSound (Bees1, insects), DuckQuack (bird_duck_05, ducks) and
RobinChirp (EDG_Robin_02, robins). `ActorSound::InitFromIniFile` 0x1008ad17
reads these keys:

* `Volume`;
* `RepeatLow`/`RepeatHigh` in ms;
* `DistanceLow`/`DistanceHigh` in feet × 12, as Miles 3D minimum and maximum
  distances.

`UpdateActorSounds` 0x10097c8e plays a sound only when all of these hold:

* the sound is idle;
* the cooldown has elapsed;
* the actor is within `DistanceHigh` and visible;
* a **1/512 chance per frame** passes (hard-coded).

## Volume and distance model

* Gain is `clamp(slider% × volumeScale / 100, 0, 1)`
  (`SoundResponse::getVolume` 0x102175de). The channel is set by response
  type:
  * 2/8 Ambient (+0x47);
  * 3–6 Golfer (+0x4b);
  * 7 Music (+0x53);
  * 10/11 TV announce (+0x57);
  * 12 Crowd (+0x5b);
  * 14 Caddie (+0x4f);
  * 15 UsrInit (+0x5f).
* Collision impact magnitude **only gates** playback (skipped below 0.1,
  `SoundResponse::Invoke` 0x102173e2) and selects rules (> 40 %). It does not
  scale volume.
* 3D uses the Miles DS3D-style inverse rolloff. The constants are hard-coded:
  * minimum distance 150 in and maximum 10,800 in (globals
    0x1037e30c/0x1037e310, used when a sample gets distances 0,0 in
    `Sample3D::SetDistances` 0x100f1cad, never written);
  * rolloff 0.8 (0x1037a09c, `AIL_set_3D_rolloff_factor` at 0x1007eceb);
  * distance factor 0.0254 m per unit at 0x1007ed3a, which confirms that
    world units are inches.
* A response with position (0,0,0) is 2D (`CreateSoundFile` 0x1007fc5d).
* For AVFoundation, use `AVAudioEnvironmentNode` with the `.inverse` model,
  `referenceDistance` 3.81 m, `maximumDistance` 274.32 m and `rolloffFactor`
  0.8.

### Data-driven vs hard-coded

| Behavior | Source |
| --- | --- |
| Event → file lists, variants, priorities, conditions, probability, loop/static | data: `basic.stn`, `gallery.stn`, `music.stn` |
| Ambient placement, radius, frequency, volume, loop | data: per-course `SND.INI` |
| Creature sounds: volume, repeat interval, 3D distances | data: `CLS.INI` |
| Surface → sound id | data: TCL `+0x2c` / texture `+0x23` |
| Interface table, music state numbers, flagstick id 804 | code: 0x10070247, 0x100707e5, 0x10136ed0 |
| Variant choice (least-played uniform), priority resolution | code: 0x10216d78, 0x1020c1df |
| Impact gate 0.1, impact % scale 0.5, power % scale 14.0 | code: 0x102173e2, 0x102137ad, 0x10210c12 |
| 3D min/max/rolloff, CLS 1/512 per-frame chance | code: constants above, 0x10097c8e |
| Background tick cadence | code in **SafeDisc-protected TW2005.exe** (calls `ScriptCommand::BackgroundNoise(counter)`; sub 6 on even counts, 7 when `%7`, 8 when `%121`) — interval not recovered |

## Importer

```sh
python3 Tools/import_pga2005_audio.py            # lean set: gameplay, crowd, interface, PBL+TUR ambience
python3 Tools/import_pga2005_audio.py --music    # also menu/end-of-game MP3s (+22.6 MB)
python3 Tools/import_pga2005_audio.py --no-commentary  # skip the 156 MB of TV commentary MP3s
python3 Tools/import_pga2005_audio.py --dry-run --strict
```

The options are `--source DIR` (install tree or any directory with the same
file names), `--course-data DIR`, `--courses-image B6I`, `--courses PBL TUR`,
`--output DIR` and `--materials-root DIR`.

If `SND.INI`/`CLS.INI` are not in `--course-data`, the importer reads them
directly from the B6I through the read-only `inspect_pga2005.ISO9660` reader.
Nothing is written into `Library/SourceMedia`.

Output in `Library/Imported/pga2005/audio/`:

* Audio files under `gameplay/`, `crowd/`, `interface/` and
  `ambient/<folder>/`. The default run imports 238 files.
* `audio.json` (0.7 MB) contains:
  * `events`: files, `action_groups`, gain, channel, loop, preload,
    `random`, positional, probability, decoded conditions and the rule
    reference;
  * `surface_sound_ids` and `courses` (folders, emitters with world centres
    and radii, CLS sounds, per-surface ids);
  * `files`: format, frames, bytes, SHA-256, `preload` (≤ 256 KB) and source
    path/SHA-256;
  * `playback_model`, `missing_sources` and `warnings`.
* `audio-rules.json` (0.3 MB): the complete decoded rule tables, for a faithful
  rule engine.
* `commentary.json` (0.8 MB): announcer, analyst and gallery class-2 rules for
  the native script interpreter; `commentary-files.json` lists the copied
  commentary MP3s with hashes (see [PGA2005-COMMENTARY.md](PGA2005-COMMENTARY.md)).

| Category | Files | MB |
| --- | ---: | ---: |
| gameplay (basic.stn) | 98 | 4.03 |
| crowd (gallery.stn) | 31 | 13.83 |
| interface | 7 | 0.09 |
| ambient PBL+TUR (+CLS) | 102 | 10.02 |
| **total (default)** | **238** | **27.96** |
| music (`--music`) | 7 | 22.56 |

Of the default set:

* 217 files are byte-identical copies;
* 20 are rewritten as canonical PCM (extra chunks or junk removed);
* 1 is MS-ADPCM decoded to PCM.

All 238 outputs open with `afinfo`. 200 files (6.2 MB) are marked for
preloading; the long loops and crowd beds should stream.

Seven gallery files that `gallery.stn` references are absent from the
original media:

* `PGASS202.wav`
* `PGAMssd99b/99c`. `99x/99y` exist on disk but are never referenced.
* `01503_…`, `02008_…`, `02109_…` and `02311_…`

The original would fail to load these and stay silent when one was picked. The
native game should drop them from candidate lists.

Tests are in `Tests/test_pga2005_audio.py`. The ADPCM tests use hand vectors,
check stereo interleave and run an IMA reference-encoder round trip. Other
tests cover WAV chunk cleanup, MP3 headers, STN/SND/CLS parsing and an
end-to-end synthetic tree. Real-media tests are skipped when the media are
absent; they check script counts, `scale.wav` and the hash of every imported
file.

## Confidence

| Claim | Confidence |
| --- | --- |
| STN layout, operators, selection, least-played variant choice | High (decompiled loader + all three files parse with exact description counts 223/1,182/16) |
| Collision event fields, sound-id rules, impact gating | High |
| Swing event fields (club mask, lie flags, power %) | High for bits 0/1/2/5; others medium |
| Gallery (class 2) field meanings | High: builder 0x102146cb decompiled ([PGA2005-COMMENTARY.md](PGA2005-COMMENTARY.md)); native play evaluates gallery.stn's class-2 rules on original courses |
| SND.INI semantics, radius in inches, global 2D beds | High |
| 3D constants and inverse rolloff | High for values; the exact Miles curve beyond max distance is medium |
| Swing "power %" threshold meaning in play | Medium: the ">94 → 75 %" rule can never win, because ">90" has a better priority (97 < 98). This is faithful to the data |
| Interface "scale" = swing meter | Low |
| gameface.mus purpose/format | Low (unknown) |

## Open questions

1. The cadence of `ScriptCommand::BackgroundNoise` lives in the SafeDisc'd
   TW2005.exe, and the call site was not found. Until it is, the native game
   should assume a 1 Hz tick. This tick drives the ambient and weather
   frequencies.
2. On PBL the ocean surface has sound id −1, so `ball.hit.water` cannot
   match. Whether the original plays a splash through another path (FIFO
   type 2/sub 5, effects) needs runtime evidence. For a water hazard (flag
   0x40) the native port should play `ball.hit.water`; this is a flagged
   deviation.
3. The units of the collision magnitude (`BallFIFOEntry+0x1e`) need the
   physics work to confirm.
4. No rule triggers BallJumpCup1-3, BallSandRoll1-5, BallCup2-3,
   WdChipFringe, WdgChipFWay/Ruf or WdgSandFat. They are not imported.
5. When looping SND.INI emitters stop is unknown.
   `CSoundManager::StopLoopingSounds` 0x1007fbc2 exists but its caller was not
   traced. The suggested behavior is to fade a loop out when the listener
   leaves its radius or the hole changes.
6. There is no course `.stn` on the disc for PBL/TUR, and PBL.TCR has no
   embedded situation file. `BuildLookupFromCourseData` (TCL library sounds)
   therefore adds nothing for these courses. This was checked by string scan
   only.
