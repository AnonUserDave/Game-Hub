# PGA Tour 2005 commentary and shot-result events

Static reverse engineering, October 13, 2026. The original game and its
Windows code were **not run**. Every claim comes from the original bytes,
Ghidra 12.1.2 decompilation or disassembly of Engine.dll, or a cross-check
between decoded data and the designers' own record descriptions. These are
direct Ghidra observations, **not REA Evidence**.

Confidence labels:

- **High**: read from decompiled code and confirmed by assembly, a second
  function or the script data.
- **Medium**: read from one source, or inferred from consistent data.
- **Low**: plausible, not established.

| Input | SHA-256 |
| --- | --- |
| Engine.dll | `94aa30bb645ea089fed6e98df0dce38d75c309e4531386cbe33c07f65bd19728` |
| announcer.stn (842,800 bytes) | `3a074dc101895ba8e99858497654a1ab02306b10b3c88fe477eeaa377567f6c9` |
| analyst.stn (430,273 bytes) | `e9f67ba084ab3a473cb3f762136059b8a44fb481d71eebc52a992f06008b071e` |
| gallery.stn | `73b552f334ca329d7cf397482c8d86ac8704b184acf7e922d8760acad8bae0dd` |

Tooling: a private copy of the presentation project in the ignored
`Library/Research/ghidra-projects-commentary/pga2005-commentary`, opened
read-only (`-process Engine.dll -noanalysis -readOnly`). Exports for passes
1–24 are in `Library/Research/ghidra-commentary/passN/` (`f-<address>.c.txt`
pseudocode, `.asm.txt` listings with referenced data, `index.txt`). The
helper script was a scratch GhidraScript that decompiles functions, lists
references, finds RTTI vtables and dumps bytes. The `.stn` format,
operators and the situation choice are documented in
[PGA2005-AUDIO.md](PGA2005-AUDIO.md) and
[PGA2005-PRESENTATION.md](PGA2005-PRESENTATION.md).

## 1. Summary

- The class-2 "shot" event is `ShotEvent` (vtable `0x102d9ac0`, ctor
  `0x10214632`, value builder `0x102146cb`). The commentary uses the
  subclass `CommentatorShotEvent` (vtable `0x102d9b68`, ctor `0x1021574f`),
  whose builder only calls `0x102146cb`. The gallery, the announcer and the
  analyst therefore see **the same values**. Sub 1 is raised in flight, sub
  2 when the ball stops and sub 19 before the shot (high).
- Each event stores its values **compactly**. Condition bit *b* reads value
  number popcount(mask & (2^b − 1)), where *mask* is the event's
  "available values" mask. A rule on a bit the event does not provide reads
  the next provided value. The class-2 mask is `0x6fffffdf`, so bits 5 and
  28 are missing and every other bit is shifted against the builder's
  storage order. This is why `bit 7` is par and `bit 8` the stroke count,
  and why the earlier inferred tables looked off by one (high).
- **Bit 12 is the flight index.** It is not a shot-category code. The
  in-flight raisers set it to `min(20, trunc(progress × 20))`, so the values
  4…18 seen in the rules mean 20 %…90 % of the precalculated flight
  (high).
- Bits 3 and 15 receive **the same number** (assembly `0x10214a94` and
  `0x10214dd1` both store `[EBP-0xcc]`). Rules that need different values,
  such as gallery "In Flight - Approach <4ft to pin" or analyst "React:
  Approach/CloseToPinV", can never fire (high).
- During flight, "the ball" is `CGolfBall::EndPosition` (vtable +0x58,
  `this+0x677`), the end of the shot precalculated at impact. Rules like
  "lands in water" or "on the green 3 ft away" are decided early in the
  flight from the known outcome (high).
- Only one commentary line plays at a time, across both commentators. A
  commentary action is **dropped, not queued**, while the previous
  commentary sample still plays. A file is not repeated within 20 s. The
  commentary option switches lines on or off; there is no frequency level.
  Everything else is per-rule probability (high).
- The executable that decides **when** each commentator is asked (calls to
  `ScriptCommand::BeginShot`, `EndShot`, `CommentatorBallInFlight`,
  `BeginHole` and so on) is the SafeDisc-protected `TW2005.exe`. The
  ordering between announcer and analyst is therefore not recoverable
  statically. The native port uses a labelled policy (§7).

## 2. Event classes (RTTI, high)

Base `SituationEvent` (vtable `0x102d99d0`, ctor `0x1020fdd5`). Layout:

| Offset | Meaning |
| --- | --- |
| +0x26d | game/kernel context pointer (set by the fill) |
| +0x271 | player index |
| +0x275 | event class (situation type) |
| +0x279 | event sub (situation event id) |
| +0x27d | available-value mask |
| +0x281 | event position |
| +0x333/+0x337/+0x33b | last situation, action and response ids (+0x33b holds the played sample handle) |
| +0x33f | 32 × u32 values (memset by `0x1020ff9e`) |
| +0x3bf | chosen situation |
| +0x3c7/+0x3cb | in-flight distances set by the raisers, unused by the builders |
| +0x3cf/+0x3d3/+0x3d7 | lateral miss, depth miss, miss flags (`0x10212c19`) |
| +0x3e3 | club (−1 = ask `CPlayer::GetLastClub`) |
| +0x3f3 | flight index (`0x10212c00`) |
| +0x3f7 | `CPlayer*` |

`GameEvent` (vtable `0x102d9a04`, ctor `0x10210248(class, sub)`) derives
from it. The value fill is vtable slot 1, called by `Script::SetupCurrent`
(`0x1020bdb9`) before matching.

| Class | Event | Mask | Ctor | Fill | Scripts |
| --- | --- | --- | --- | --- | --- |
| 1 | SwingEvent / CommentatorSwingEvent | `0x0830512f` | `0x102141db` / `0x102157b3` | `0x1021424d` | basic, analyst |
| 2 | ShotEvent / CommentatorShotEvent | `0x6fffffdf` | `0x10214632` / `0x1021574f` | `0x102146cb` | gallery, announcer, analyst |
| 3 | CollisionEvent | `0x00200024` | `0x1021373d` | `0x102137ad` | basic |
| 4 | ScoringEvent | `0x00000380` | `0x1021365d` | `0x102136b3` | — |
| 5 | BackgroundEvent | `0x00006040` | `0x10214fd0` | `0x1021502f` | basic, gallery |
| 7 | DelayEvent | `0x08005000` | `0x10215346` | `0x102153a6` | — |
| 8 | ShotPrepEvent (golfer motion) | `0x6fffffdf` | `0x10214f9e` | `0x102146cb` | — |
| 9 | LocationEvent / CommentatorLocationEvent | `0x778a62ca` | `0x102150e8` / `0x10215781` | `0x10215126` | announcer |
| 10 | UserEvent / CommentatorUserEvent | 0 / `0x0c004005` | `0x102152fb` / `0x102157f2` | `0x10215824` | announcer |
| 11 | CameraEvent | `0x77ffffff` | `0x1021387a` | `0x102138df` | cameras |
| 12 | CommentatorIntroEvent | `0x7c822246` | `0x102154a1` | `0x102154d5` | announcer, analyst |

The commentator subclasses' vtable slot 0 returns 0 (`0x10215774` and
others). The action executor uses that value as the response-type filter, so
every response of a commentary action is eligible. Plain events return golfer
voice types 3–6 (`0x1021006f`).

Matching (`Script::FindSituationsMatching` `0x1020bfe3`, condition loop
`0x10215b0b`, operators `0x10215b87`). A situation qualifies when:

- its class equals the event class;
- its sub equals the event sub, or is 0;
- it has at least one action;
- its condition bits intersect the event mask (all of them if mask bit 31
  is set; no rule in these scripts uses bit 31);
- every condition holds. The value is read compactly through `0x10215da1`
  (+0x33f) and `0x10215dc7` (+0x27d).

## 3. Class-2 values (`0x102146cb`)

Positions: *golfer* = `CPlayer::GetPosition` (the address). *Ball* is
`CPlayer::GetBallPosition`, replaced by `CGolfBall::EndPosition` when a ball
object exists; in flight that is the precalculated end. All distances are
`ftol` (truncated) inches. `APosition` is horizontal (x, z), so distances
are 2D (medium).

| Bit | Value | Confidence |
| --- | --- | --- |
| 0 | club mask (`0x1021038a`) from the original club index: 4 for 8–44 except 20, 2 for 0–7, 1 for drivers 0–1, 8 for 21–32, 0x10 putter (20), 0x40/0x80/0x100 long/mid/short iron groups, 0x20 wedges 17–19 and 30–32 | High |
| 1 | shot flags (`0x102104f9`): 1 when `GetStrokesThisHole` is 0 or the ball has the on-tee attribute 0x8000. The shot style at `CPlayer+0x78dd` adds 0x400 (styles 0–2), 0x800 (3), 0x1000 punch (4), 0x2000 lob (5), 2 putt (6), 4 chip (7), 0x4000 pick (8) or 0x8000 (9). Toe/heel and launch-band flags are filled only for subs 3 and 17 | High (style names from rule descriptions: medium) |
| 2 | terrain flags at the golfer (`Position::TerrainTypeFlags`) | High |
| 3 | inches to the pin. From *ball* when sub = 2 or *ball* is on the green (flag 4); otherwise `CPlayer::GetDistanceFromHole(false)`, from the lie the shot was played from (0 once holed) | High (lie position in flight: medium) |
| 4 | inches golfer → *ball* (the predicted shot length in flight). If bit 1's value is exactly 3, `GetDistanceFromHole(true)` instead | High |
| 5 | not provided; a rule on it would read bit 6 | High |
| 6 | hole number (`CPlayer` vtable +0xdc) | High |
| 7 | par | High |
| 8 | strokes this hole (`GetStrokesThisHole`). Before the shot during subs 1/19 and after it at sub 2 (rule data: "Par4/Shot2" uses 1 in flight, "1PuttPar/Par4" uses 4 holed) | High |
| 9 | score (`0x1021088a`). Stroke formats: team total to par, plus strokes − par once holed at sub 2. Match formats: 1 up, 2 down, 4 dormie, 8 won, 0x10 lost (and 0x80 at hole end when a per-hole check fails, not decoded) | High |
| 10 | miss against the ideal line (`0x10212c19`): 1 left / 2 right, 4 short / 8 long | High |
| 11 | lateral miss, inches | High |
| 12 | flight index `+0x3f3` (0 except in flight) | High |
| 13 | course wind speed `ftol(course+0x581)` | High |
| 14 | golfer model flags: 1 male, 2 female | High |
| 15 | same value as bit 3 | High |
| 16 | wind (`±0.65` of the normalised wind vector, `0x102d9a90/98`). Against the aim: 1 left-to-right, 2 right-to-left, 4 headwind, 0x10 tailwind. Against the ideal line: 0x20 head, 8 tail (the second test reuses the first block's x; it only reads z) | High (names from rules: medium) |
| 17 | depth miss, inches | High |
| 18 | `CPlayer+0x15ff`: putts this hole (rules: "1PuttPar" = 1 at sub 2, "first putt" < 2 before) | Medium |
| 19 | `0x10210ae3`. Stroke: strokes behind the leader. Match: holes left when dormie, else the match margin | High |
| 20 | on the green: `0x10212e7b` slope. Rise pin − ball over 7 in → 4, over 3 → 1, ±3 → 0x100, down to −7 → 2, else 8. Break from 0.3·n(pin) + 0.4·n(midpoint) + 0.3·n(ball) across the putt line: left 0x80/0x400/0x20 and right 0x40/0x200/0x10 at 0.065/0.02/0.007. Off the green: `Position::GetSubTerrainType` (lie record) | High (left/right sense from rule names: medium) |
| 21 | terrain flags at *ball* (0x4000 in the hole); −1 becomes 0 | High |
| 22 | same value as bit 4 | High |
| 23, 24 | `0x102135c1`: `ftol(ideal elevation − ball elevation)`; bit 23 is its magnitude, bit 24 is 1 if ≥ 0 and 2 if negative | High |
| 25 | constant 18 (`0x10212b9f`) | High |
| 26 | game format, settings+0x13: 1 stroke, 2 match, 3 Stableford, 4 medal four-ball, 5 match four-ball, 6 Stableford four-ball, 7 skins, 8/9 scramble, 0xa cup, 0xb greensome, 0xc bloodsome, 0xd shootout, 0xe skills. Match-based formats: 2, 5, 7, 0xa, 0xb, 0xc (`0x1022fc24`) | High (names from rules) |
| 27 | golfer model type; Tiger Woods is 1 ("IntroPlayer: 1stTee/Woods1V") | High |
| 28 | not provided; reads bit 29 | High |
| 29, 30 | game flags (`0x102124e8`) | High for the tests, medium for meanings |

Game flags in detail:

- 1: more than 7 players;
- 2: format 0x10;
- 4: season event, with 8 for event type 0 and 0x4000000 for the final round;
- 0x10: match-based format;
- 0x20: computer player;
- 0x40: practice;
- 0x80–0x40000: skills sub-types;
- 0x80000 front nine, 0x100000 back nine, 0x200000 18 holes, 0x400000
  settings flag 0x800, 0x800000 one hole, 0x1000000 three holes;
- 0x2000000: playoff/sudden death (settings flag 0x400);
- 0x8000000: settings+0x1d7/+0x1d8, which the gallery suppresses on every
  rule;
- 0x10000000: golfer trait `+0x2e3` is 0;
- 0x20000000: format 3 or 6;
- 0x40000000: legends tour (settings+0x12 = 8).

The miss frame (`0x10212c19`): θ = `Angle180(dx, dz)` of ideal − golfer.
forward = sin θ·x + cos θ·z, which equals the target distance for the ideal
point and so fixes the convention. Lateral = cos θ·x − sin θ·z is positive
to the right in the left-handed source frame. `GetIdealPosition`
(`0x1013e64c`) is the pin unless `CPlayer+0x790a`, `+0x78fe ≥ 1` and the
hole are set. In that case it is a point at `Caddy::DistanceToTry` along
the line, the caddy's target. Those flags' meanings are unknown (medium).

## 4. Other commentary events

**Raisers** (exported `ScriptCommand` methods; each `ScriptCommand` is bound
to one script, high):

| Class/sub | Method | Script data |
| --- | --- | --- |
| 1/3 | `Swing` `0x100609af` | analyst "BallHit" (12) |
| 2/1 | `CommentatorBallInFlight` `0x10062dc5` | announcer "InFlight"/"ToHole" (182) |
| 2/2 | `EndShot` `0x1005fe8d` | analyst "PuttResult", "ScoreUpdate", "React", "Cup", "RollIn", "±N for round" (284) |
| 2/19 | `BeginShot` `0x10060634`; `QueueBeginShotComment` `0x100601e8` + `DoQueuedBeginShotComment` `0x100600c6` | announcer "PrePutt", "IntroPlayer", "Skills" (592); analyst "Yardages", "PreHit", "PrePutt", "PrehitLie" (127) |
| 9/28, 9/29 | `BeginHole` `0x1005f2fd`, `EndHole` `0x1005fc54` | announcer course/Tiger-proofing, "EndHole", "GPScoring", "ScoreUpdate" (55 + 69) |
| 10/10 | `OnClubSelectionComment` `0x10060bf3` | announcer "ClubChoice" (21) |
| 10/23, 10/24 | `OnShotSetupComment`, `OnAimComment` | none |
| 12/6, 12/7, 12/8 | `BeginTournament`, `RoundFormatComment`, `WeatherComment` | announcer "IntroCourse/IntroFormat/IntroWeather" (96 + 25 + 13 + 2 at sub 0); analyst "CourseState" (13) |
| 12/5, 12/9, 12/20 | `RoughComment`, `GreensComment`, `WindComment` | none |

**Flight index** (`ScriptCommand::SetFlightIndex` `0x100666f2`, high):

- No index fires while the ball has fewer than 60 recorded samples
  (`0x10379158`), or 30 when the lie is within 72 in of the hole
  (`0x102d60f8`).
- A putt (`CPlayer+0x786a`) waits until progress `+0x331` ≥ 0.1
  (`0x102d5e78`).
- index = `min(20, ftol(progress × 20.0))` (`0x102d56a4`).
- An index fires only when it exceeds the last one (reset to 3,
  `0x1037915c`) and progress has not gone backwards. The first evaluation
  after a reset never fires, because the stored progress starts at 1.0.
- `BallInFlight` (gallery and basic) loops over every skipped index.
  `CommentatorBallInFlight` sends only the newest.
- The sample counter `+0x32c` is taken to be the length of the
  precalculated path and progress its played fraction (medium).

`BeginShot(force)` skips a ball on a 0x20 (unplayable) lie and sets
`ForceRandomActions(force)`. The queued variant always runs with probabilities
forced. Which of the two the executable uses, and when, is encrypted.

**LocationEvent** values (`0x10215126`, high), in bit order:

- 1 shot flags; 3 `GetDistanceFromHole(false)`;
- 6 hole number. At a match-format hole end this is holes played
  (`0x102156a9`);
- 7 par; 9 score code; 13 wind setting (settings+0xf); 14 model flags;
- 17 hole shape (`0x10210e98`): pin ±420 in above/below, dogleg 1/2/0x10,
  and composite-course ("Tiger-proofed") bits from 0x20000;
- 19 standing; 23/24 elevation; 25 18; 26 format; 28 course id
  (`0x10211885`); 29/30 game flags.

The announcer's class-9 rules on bit 21, which this event does not provide,
read bit 23's value.

**CommentatorIntroEvent** values (`0x102154d5`, high):

- 1 green condition (settings+0x10: 1 wet, 2 damp, 3 normal, 4 dry,
  5 very dry);
- 2 rough length (settings+0xe: 1 short, 2 average, 3 long);
- 6 hole (`0x102134b4`); 9 tournament round (settings+0x1b3);
- 13 wind setting (1 still … 5 strong); 17 hole shape;
- 23 weather preset (settings+0x11: 2 fair, 3/4 windy, 5 foggy/overcast,
  6 wet);
- 26 format; 27 first golfer's model type (sub 6, `0x102155f5`);
- 28 course id; 29/30 game flags.

Course ids from the IntroCourse rules (high by name; the GUID table in
`0x10211885` was not mapped to course files): Pebble Beach 0x1, Sawgrass 0x6, St Andrews
0xd, Edgewood 0x15, Fancourt 0x16, Harbour Town 0x17, Red Mountain 0x18,
Sherwood 0x19, Troon 0x1a, Turnberry 0x1b, Emerald Dragon 0x1c.

**CommentatorUserEvent** (class 10): bit 0 club index, 2 terrain at golfer,
14 model flags, 26 format, 27 model type.

## 5. Interpreter rules for commentary (high)

1. **Choice.** Lowest priority byte, then most conditions, then least
   fired, then uniform (`0x1020c1df`). Single-action situations pick one
   action uniformly; duplicates weight the pick (`ChooseAction`
   `0x1020d11b`).
2. **On/off.** `Script::IsIgnored` (`0x1020d17b`) maps action type 8 to
   `Script+0x86`. `Script::Enable` (`0x1020b997`) sets it to 3 when
   `CMachineSettings` flag 0x1000 is on, else 0. Type 9 (gallery) uses
   `+0x87` and flag 0x800. Both default on (`SuggestSound` `0x102314f7`). 3
   never ignores and 0 always does. (The 1 → 16 % and 2 → 36 % levels exist
   in code but no setting produces them for these types.)
3. **Probability.** `random(100)+1 ≤ p`, skipped while ForceRandomActions
   is set (`0x102160a5`).
4. **One line at a time.** For type 8, if the global commentary handle
   (`0x1038c838`) is still playing, the action returns without playing.
   After 16 consecutive drops (`0x104503cc`) the handle is reset, and the
   next line plays even if the old one is still sounding. After playing,
   the handle becomes the new sample. The handle is shared by every script,
   so announcer and analyst never talk over each other except in the
   watchdog case.
5. **No repeat.** `SoundResponse::Invoke` (`0x102173e2`): a type 10/11
   response whose file equals the previous commentary file is skipped when
   that file started less than 20,000 ms ago (`StampClock` `0x10450298`).
6. **Response.** Uniform among the action's entries with the fewest plays
   (`0x10216d78`); counters are per response object.
7. **Sequences.** File flag bit 0 becomes 0x4000 (`0x10215e27`) and plays
   every response in order. The 18 announcer actions that use it are the
   match-play "All square thru N" scoring lines.
8. **Mixing.** Responses are type 10 (announcer) and 11 (analyst). Both use
   the TV-announce slider, default 35 %; the crowd defaults to 47 %
   (`SuggestSound`). Lines are 2D streams.

## 6. Data findings

| Script | Situations | Actions | Responses | Files | Silent placeholders | Missing files |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| announcer | 1,055 | 907 | 4,270 | 1,931 | 147 | 65 |
| analyst | 436 | 469 | 2,298 | 1,288 | 13 | 27 |
| gallery (class 2 only) | 196 | 199 | 784 | 31 | 0 | 7 |

- The commentary rules reference 3,216 of the 3,290 MP3s (156 MB). Names
  ending `.wav` resolve to the shipped `.mp3` (`SetAbsolutePath`
  `0x10217277`). "no commentary" responses are deliberate silences.
  Missing names fail to load and stay silent.
- The MP3s are 44.1 kHz mono (3,091), 44.1 kHz stereo (103) and 22.05 kHz
  mono (94). The largest is 311 KB, about 19 s.
- Priorities: announcer 98/99/100/231 and analyst 98/99/100/200; the gallery
  uses 100/199/200. Action probabilities are listed in commentary.json;
  about 44 % of announcer actions and 29 % of analyst actions are below
  100 %.
- Bit 3 equals bit 15, so three class-2 rules can never fire (two gallery,
  one analyst).
- Analyst "BallHit" rules need the TrueSwing tempo value (bit 12 of the
  swing event, `0x10214548`, flags 1/2). Click meters give 0, and some rules
  ask for 8, which the code never produces. With the tri-click meter they
  never play.
- No commentary or gallery situation uses mask bit 31 or the key-moment
  flag.

## 7. Native implementation and fidelity

`Tools/import_pga2005_audio.py` writes:

- `commentary.json`: the literal rule tables of all three scripts;
- `commentary-files.json`: hashes and provenance;
- `audio/commentary/*.mp3`: unchanged copies.

`--no-commentary` skips the MP3s. `Sources/GameHub/PGACommentary.swift`
holds the builder, interpreter and director. `PGAAudioEngine` plays the
result.

| Part | Status |
| --- | --- |
| Compact value indexing, operators (unsigned 3/4), choice order, probabilities, least-played responses, sequences, drop-while-speaking, 16-drop reset, 20 s repeat guard | Faithful |
| Class-2 builder formulas, flight index rules, gallery stepping vs commentator newest index | Faithful to the decode |
| Precalculated end | The native deterministic `CBallFlight` copy run to rest. It matched the actual rest exactly in 33 of 33 non-hazard Pebble test shots (M5). Hazard shots end at the water/OB impact, like `stepOriginal`. Computed in 150-tick slices per frame |
| Ideal position | Native caddie target (`playLineTarget`: the pin within driver reach, else a TCR aim point); approximates `Caddy::DistanceToTry` |
| Shot style | No shot-type menu natively: putter = putt (6), partial wedge near the green = chip (7), else normal (0). Lob, punch and pick never occur |
| Putts (bit 18) | Putter strokes this hole (medium) |
| Match/skins values | Hole-by-hole status against the best other score; the 0x80 hole-end flag is not reproduced |
| Weather preset | No native weather; always 2 (fair) |
| Gallery positional flag 0x10 | Played 2D, like the existing crowd path |
| Orchestration | **Native policy.** At round start the director queues BeginTournament (12/6), RoundFormat (12/7) and the analyst's WeatherComment (12/8); each hole start queues BeginHole (9/28). Each turn queues BeginShot (2/19) for one commentator, alternating which is asked first and falling to the other if no rule matches (`WillExecute`). These wait for silence and are dropped when a swing starts. In-flight and EndShot events are immediate (dropped while speaking, as in the original). EndHole (9/29) waits until everyone is in. Club selection (10/10) is not raised |
| Volume | Speech at the original 35 % default. The existing crowd and ambient paths still play at 100 %, so the crowd is relatively louder than the original 47 % |
| Fallback | Without commentary.json, or on the generated practice course, the earlier hand-mapped `crowdReaction` remains (labelled approximation) |

**Memory and CPU.** Speech is never preloaded. One MP3 at a time is decoded
on the audio queue into one 44.1 kHz mono buffer (≤ ~3.4 MB for the longest
line) on a single `AVAudioPlayerNode`. The node is stopped before another
line starts, so two lines never overlap. The decoded tables are about
0.8 MB of JSON, parsed once on the audio queue at start. The flight preview
costs about 11 ms mean and 48 ms worst for a whole Pebble flight in an
unoptimised **M5 debug** test. That is why it runs in 150-tick slices
(≤ ~8 ms debug per frame for the longest flight). Release-build and M1
costs are **unmeasured**.

## 8. Open questions

1. The order and timing of the executable's calls: who comments first
   before a shot, the delay between lines, whether the queued
   (probability-forced) or the plain BeginShot is used, and when club
   selection comments fire.
2. `CPlayer+0x790a` and `+0x78fe`, which decide whether the ideal position
   is the pin or the caddy's target.
3. The exact quantity behind the sample count (`+0x32c`) and progress
   (`+0x331`): path samples and time fraction are assumed.
4. `CPlayer+0x15ff` as a putt counter, and whether CPlayer's ball position
   stays at the lie until the ball rests (it decides bit 3 in flight).
5. `APosition::Rotate` sign convention, which is assumed from the miss
   frame. It decides the wind and break sides, whose names otherwise come
   from rule descriptions.
6. The match hole-end 0x80 flag (`vt+0x2c` check in `0x1021088a`).

## 9. Reproduction

```sh
python3 Tools/import_pga2005_audio.py          # writes commentary.json, commentary-files.json, audio/commentary/
python3 -m unittest Tests/test_pga2005_commentary.py
./Tools/test.sh -XCTest GameHubTests.PGACommentaryTests
```

Ghidra (read-only, private project copy):

```sh
AnalyzeHeadless Library/Research/ghidra-projects-commentary pga2005-commentary \
  -process Engine.dll -noanalysis -readOnly -postScript <export script> <out> fn:0x102146cb …
```
