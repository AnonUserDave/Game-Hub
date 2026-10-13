# PGA 2005 source asset findings

Observed from local supplied media, 2026-10-13. No original installer or game code was executed.

## Identity and available data

The supplied archive `Tiger_Woods_PGA_Tour_2005_Win_ISO_EN.zip` has SHA-256 `620d35d54988f470c8dbbd386dc76b4a607f65f448ae0adf321738610ae5412e`. It contains install and media ISO9660 images and a courses B6I image. The parser reads the B6I's sector layout directly without mounting or emulating a drive.

| Disc | Files | Important contents |
| --- | ---: | --- |
| INSTALL_DISC | 2,101 | InstallShield DATA1.CAB/HDR and DATA2.CAB, character/configuration data |
| MEDIA_DISC | 1,892 | DATA3.CAB, movie assets |
| COURSES_DISC | 2,242 | TW2005.EXE, 11 course pairs of TCR/TCL files, readable settings and images |

The uncompressed courses-disc executable is PE32 x86, SHA-256 `2229ff0bc5ddbda3d892c45cf3ede1b4194bdb86ff90ca0396f2736ff34374f4`. Engine code lives in separate DLLs inside the installation cabinets; see the REA ledger for static evidence and entry points.

## Import tool results

`Tools/import_pga2005.py` converted **236 images**, with **zero unsupported images** in this media. It supports the observed uncompressed/RLE TGA and legacy DDS RGB/DXT1/DXT3/DXT5 layouts. It imports INI metadata for AUS, EDW, FAN, HAR, JPN, MON, PBL, SAW, SHR, STA and TUR: **198 holes** in total.

All 11 extracted Pebble Beach source images were independently compared with Pillow RGBA decoding. After correcting 565-channel expansion to use bit replication, all compared TGA and DDS pixels matched exactly. This validates that sample's decoded pixels, not all formats or gameplay. Converted PNG file bytes are intentionally different from the source image files.

Metadata preserves every raw section/key entry with its line number, repeated pivot keys, raw coordinates, and source hashes. Turnberry has a malformed handicap value (`16.16.16`) that is preserved with a warning; it is not silently corrected. Coordinate units and mapping into game space remain unverified.

## What this does not establish

- TCR terrain and TCL compiled-library structures are not decoded by this importer.
- Tee, pin, pivot, OB and coastline settings are useful metadata, not a terrain reconstruction.
- Original textures do not by themselves reproduce original lighting, trees, geometry or rendering.
- No current result demonstrates gameplay equivalence, original animation/audio, complete modes, or performance at 2560 × 1600.

## Reproduce

```sh
python3 Tools/inspect_pga2005.py
python3 Tools/import_pga2005.py
python3 -m unittest discover -s Tests -p 'test_*.py'
```

Output is local under ignored `Library/SourceMedia`, `Library/Imported`, and `Library/Research`. New format readers should reject malformed bounds/counts and retain an unsupported status for unknown structures.
