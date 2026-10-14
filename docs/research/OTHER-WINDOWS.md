# Remaining Windows titles: original data preparation

2026-10-13, son's M5 Pro / 24 GB development machine. The owner's M1 Air / 8 GB / 2560 × 1600 remains the release target. **No skating title or PGA2004 is a finished native rewrite.** This checkpoint recovers actual supplied content and adds a bounded native collision-data loader. It does not supply skating gameplay or claim original behavior, rendering, modes, controls or M1 acceptance.

## Verified source coverage

The compact [content receipt](evidence/other-windows-content.json) records archive and extracted-source hashes, original content identities, decoded counts and limits. Full local inventories and prepared original bytes live under the ignored `Library/SourceMedia/<title>` and `Library/Imported/<title>` directories.

| Title | Supplied source and this checkpoint | Remaining before native gameplay |
| --- | --- | --- |
| PGA2004 | One readable 653,498,368-byte ISO, `INSTALL_DISC`. InstallShield v6 header has 5,792 file slots, 5,739 valid entries and cabinet volumes 1–3. Volumes 1/2 are present; volume 3 is missing. PBL, SAW and STA TCR/TCL/INI files and Engine.dll/CourseData.dll extract with stored MD5 verification. | TCR version **4**, which the existing PGA2005 version-7 decoder correctly rejects. Reconstruct its layout and original behaviors separately. KAP/BPB/CDA/AVN/PIN TCRs require missing cabinet volume 3; complete original media are still required. |
| THPS2 | One readable ISO, `THPS2`, with an installed `ALL.PKR` resource pack and x86 Windows executable. First-party PKR2 reader recovers **3,771** stored assets: 282 PSX, 32 TRG, 2,850 BMP, 312 WAV, plus symbols, fonts and other data. | PSX placement/mesh/material/texture loaders, TRG commands and original skating behaviors, modes, saves, rendering and input. Extracted data alone is not a native game. |
| THUG | Installed ZIP tree with Windows `THUG.exe`. **60** selected PRE3 archives decode. **47** unique collision assets, including **27** under `Levels/`, retain 588,741 vertices and 477,659 triangles. Original scene, texture and QB script bytes are retained for further static work. | Scene/material/animation loaders; script/goal execution and original skating/walking/driving behaviors; camera, audio, modes, saves, native presentation/input. The `Levels/` count includes interiors/editor/test content and is not a claim about playable level coverage. |
| THUG2 | All **three** raw MODE1 discs are readable (`THUG2_1/2/3`, 2,352-byte sectors with 2,048-byte payload). Microsoft CABs differ from PGA's InstallShield format. Selected LEVELS/PRE/ALLOTHER CABs yield 472/153/2,704 members. **117** PRE3 archives decode; **94** unique collision assets, including **23** under `levels/`, retain 544,349 vertices and 466,840 triangles. | MSI filename mapping and other cabinet groups are unfinished; full installed-game coverage is unverified. Scene/material/animation/script/behavior/mode/save/native presentation/input implementation remains. |

REA's target-free `inspect_pe_resources` identified the supplied THUG.exe as **PE32 / machine 0x014c (I386)** and enumerated its three resources. Evidence `ev_32a93c99b417701c0b2dd6d1aa534975785470e33f96ff118a9ec76f0d1eeecd`, binary SHA-256 `7dd979a2b3adb2013c2158364e5d7022fc72297ad39209262b47adb99c50b413`. This is static shipped-artifact evidence; the original executable was never run. Format/count evidence for the other files comes from the first-party parsers and their source-hash receipts, not a REA decompilation claim.

## First-party preparation and native data

Run:

```sh
python3 Tools/prepare_other_windows.py
python3 Tools/prepare_other_windows.py --titles thug thug2
python3 -m unittest Tests/test_neversoft_assets.py
./Tools/test.sh -XCTest GameHubTests.SkateOriginalCollisionTests
```

`prepare_other_windows.py` streams selected ZIP members, verifies ZIP CRC and source SHA-256, reads ISO files without mounting, and reuses the existing MD5-verifying InstallShield reader for PGA2004. Microsoft CAB extraction uses macOS's existing `/usr/bin/bsdtar`, after validating the full member list; no dependency or compatibility runtime is installed. The preparer never launches, patches or installs an original executable. PGA2004's present courses are extracted for research but do not enter the PGA2005 course catalog.

`neversoft_assets.py` independently reads observed PKR2 stored entries, PRE3 size/version/name/extent fields and 4 KiB LZSS streams. It rejects unknown compression, path traversal, duplicate paths, malformed extents and expanded assets above 64 MiB. It decodes observed THUG collision v9 and THUG2 v10 into **GHSC v1**: a 20-byte header, 24-byte object records, float3 vertices and 16-byte triangle records containing original face flags and terrain IDs. Both source versions' geometry fields pass complete count/index/finite-coordinate validation across the recovered corpus; this does not establish runtime collision semantics. BSP traversal, object movement, collision solver behavior, axis conversion and source-unit interpretation remain unfinished. Original coordinates are preserved.

Every PRE-derived source and native collision package is addressed by the expanded source SHA-256. Shared assets and alternate archive paths therefore cannot silently replace each other. A receipt's `native_path` selects the exact collision source. Source paths alone never qualify an asset as a playable main level.

`SkateOriginalCollision.swift` loads GHSC packages with Foundation, retains one mapped compact buffer, validates object coverage, all triangle indices and finite vertices, and exposes object/vertex/triangle access. The maximum package is 64 MiB, with no whole-library cache. It is a native ARM64 asset foundation; no hub entry advertises it as a skating rewrite. Rendering/collision acceleration should preserve the source's object and face classification when implemented.

## Validation and next implementation

Seven focused Python tests cover stored PKR lookup/orphan tables; PRE paths/alignment/truncation; LZSS literal, overlapping match and initial ring behavior; float/fixed vertices, small/large faces, explicit v9/v10 gates and malformed data. The allocation regression rejects cumulative vertex/face counts above the source header before expanding repeated object spans. The real preparation completed on all four supplied archives. All decoded collision objects' vertex/face totals and indices passed the structural checks. Source hashes and native hashes are retained in the receipt.

The initial three Swift tests passed on the M5, including the original New Jersey collision package (1,700 objects, 48,761 vertices, 38,202 triangles). A further original THUG2 AP package test exercises 739 objects, 51,797 vertices and 45,428 triangles. Run the focused command above after integration; these checks establish data loading and structural validation only. M1 performance, original-engine comparison and physical controller behavior remain **unverified**.

The next useful skating checkpoint is one original level's **visual** loader with exact scene/material/texture pairing, followed by source-backed collision classification and basic source-reconstructed locomotion. Preserve the separation between an original level viewer, limited development gameplay and a faithful rewrite. Completing story goals, tricks/scoring/combos, off-board behaviors, modes and saves requires individual behavior reconstruction and comparison; a generic skateboard demo cannot satisfy those gates.

## Format references used

- [JayFoxRox's PKR reader](https://github.com/JayFoxRox/thps2-tools/blob/master/extract-pkr.py) documents the stored directory/file tables; actual local records determine the accepted version and compression.
- [io_thps_scene THUG collision importer](https://github.com/denetii/io_thps_scene/blob/main/import_thug2.py) documents object headers, fixed/float positions, small/large faces and intensity/face section offsets. The implementation here is independent and adds bounded validation and the native package.
- [Haruhiko Okumura's LZSS source](https://github.com/niemasd/LZSS-Haruhiko-Okumura/blob/main/lzss.c) documents the ring/flag/match convention; local PRE3 bytes determine the version, initial ring and framing accepted here.
- [GreaseMonkey's PSX format research](https://gist.github.com/iamgreaser/b54531e41d77b69d7d13391deb0ac6a5) and [THPS2 tools](https://github.com/JayFoxRox/thps2-tools) are starting points for the unfinished THPS2 loader. Their broader platform claims are not proof of this game's native fidelity.

No third-party execution/modding package was installed or copied into the repository. Original data, binaries, converted meshes/textures and builds remain outside Git.
