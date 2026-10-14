# Local media on the son's Mac

The owner confirmed on 2026-10-13 that **all original game ZIPs were already AirDropped to the son's computer**. No additional media transfer is needed for this handoff. GitHub holds the project source and research records; the ZIPs remain ignored local inputs.

1. Clone `https://github.com/AnonUserDave/Game-Hub.git`.
2. Locate the AirDropped ZIPs, usually in Downloads, and put them in the clone's root. Keep the original filenames. Never add them to Git.
3. With Python 3.10+ installed, run `python3 Tools/prepare_pga2005.py` from the clone. It reads `Tiger_Woods_PGA_Tour_2005_Win_ISO_EN.zip`, extracts selected source files safely and regenerates the original PBL/TUR course viewer assets in ignored `Library/` directories.
4. Build using `./Tools/build.sh`, then open `Game Hub.app` or run `./Tools/run.sh`. Choose the clone as the library folder if prompted.

The expected PGA 2005 ZIP is 1,371,440,468 bytes, SHA-256 `620d35d54988f470c8dbbd386dc76b4a607f65f448ae0adf321738610ae5412e`. Preparation recovers 236 images, metadata for 11 courses, and original geometry/material/tee/pin data for Pebble Beach and Turnberry. No Windows installer needs to run.

Existing local `Library/SourceMedia`, `Library/Imported`, large Ghidra databases, `.tools` installations and build output are reproducible caches, not Git inputs. Curated research metadata is in [research/evidence](research/evidence/README.md), with reproduction details in [PGA2005-REA.md](research/PGA2005-REA.md). Do not transfer authentication configuration, keychain data or credentials from the original laptop. Authenticate GitHub independently on the son's machine when pushing.

Known source gaps remain: PGA 2004 has only disc 1; the Space Invaders ZIP contains Bally pinball firmware, while the intended game is the classic Taito shooter. AirDrop preserves those source issues; it does not resolve them.
