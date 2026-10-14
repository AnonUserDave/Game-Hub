# Project status

Updated 2026-10-13. Work on the owner's laptop is paused at his request for handoff to his son. The long-term objective remains unfinished. No game is certified as a fully faithful rewrite.

| Workstream | Verified progress | Remaining |
| --- | --- | --- |
| Hub | Optimized ARM64 build, 18 catalog entries, async startup and folder selection verified in native UI | Broader native import/launch QA |
| Native golf practice | Three generated playable holes, swing/flight/rolling/putting, penalties, scorecard, pause/hub return | Final GUI confirmation of fixed forest transforms; original gameplay/content parity |
| Original geometry | Decoder passes all 11 courses; PBL 925,930 vertices / 843,279 faces; TUR 727,939 / 655,692 | Alternate LODs, vegetation and animation |
| Original materials | PBL 181 and TUR 81 used materials resolve to original TCL textures; eight decoded DDS samples independently match pixels | Original shader effects, alpha, water, lighting and subterrain rules |
| Original holes | PBL 18 holes, 90 tees, 180 pins recovered directly from TCR; inch units corroborated in assembly | Native gameplay integration and original selection rules |
| Original Course Lab | Original faces/UVs/textures render; palette and navigation work | Further visual parity and sustained performance profiling |
| Retina | Actual 2560 × 1600 Metal attachments verified in fullscreen practice and original viewer, 4× MSAA | Snapshots reach 55–60 FPS; sustained session statistics remain |
| Exact floor index | PBL 9,110 and TUR 7,128 source centroid queries pass, zero missing; index builds about 0.6 s | Integrate with rules/ball; wall/object collision semantics |
| Wired controller | Native USB backend active; user reported buttons, triggers and sticks working; RT release observed | Other buttons, game actions, focus and hot unplug/replug |
| Tests | 23 Swift XCTest and 18 Python tests pass | Expand as original behavior is reconstructed |
| Other games | All supplied archives cataloged; Space Invaders source mismatch recorded | Full native rewrites; PGA 2004 needs discs 2/3 |
| GitHub | Integrated app source, tools, tests and handoff documents in this checkpoint | Continue small checkpoints in the son's clone |

See [HANDOFF.md](HANDOFF.md) for the next work and completion gates.

The son's M5 MacBook Pro (24 GB) is for development only. [M1_TARGET_CONSTRAINT.md](M1_TARGET_CONSTRAINT.md) requires M1 Air / 8 GB / 2560 × 1600 acceptance. Original ZIPs are already AirDropped; [continuation prompt](SON_HANDOFF_PROMPT.md) and [media setup](MEDIA_SETUP.md) are ready.
