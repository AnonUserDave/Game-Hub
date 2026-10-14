# InstallShield cabinet reader

Observed from local supplied media on 2026-10-13. No installer code was executed. `Tools/installshield_cab.py` is a standard-library reader for InstallShield 5+ cabinets (`ISc(` signature). It replaces the Homebrew `unshield` dependency for PGA Tour 2005. The field layout follows unshield 1.6.2's documented behaviour, implemented independently and checked against unshield's output.

## Format fields relied on

All integers are little-endian. Offsets marked "desc" are relative to `cab_descriptor_offset`.

| Structure | Fields used |
| --- | --- |
| Common header (20 bytes, every file) | `ISc(`, `version`, volume info, `cab_descriptor_offset`, `cab_descriptor_size`. Major version is `(version >> 12) & 0xF` when the top byte is 1, or `(version & 0xFFFF) / 100` when it is 2 or 4. PGA 2005 is `0x0100600C`, which is major version 6. |
| Cabinet descriptor | desc+0x0C file-table offset, +0x14/+0x18 file-table size, +0x1C directory count, +0x28 file count, +0x2C descriptor-array offset (v6+), +0x3E 71 file-group hash heads, then 71 component hash heads. |
| Hash-list node | `name`, `descriptor`, `next` (3 × u32, desc-relative). |
| File group | `name` u32, then 0x12 bytes (v6+) or 0x48 bytes (v5) skipped, then `first_file` and `last_file` u32. |
| Component | `name` u32, 0x6B bytes (v6+) or 0x6C bytes (v5) skipped, then u16 group count and u32 offset of a table of group-name offsets. |
| File table | Directory-name offsets (u32, relative to the file table). In v5, per-file descriptor offsets follow. |
| v6+ file descriptor (0x57 bytes) | flags u16, expanded u64, compressed u64, data offset u64, MD5[16], 16 bytes skipped, name offset u32, directory index u16, 12 bytes skipped, link previous u32, link next u32, link flags u8, volume u16. |
| v5 file descriptor (0x3A bytes) | name, directory (u32), flags u16, expanded and compressed u32, 0x14 bytes skipped, data offset u32, MD5. The volume is found by walking the volume headers. |
| Volume header (after the common header) | v6+: data offset, first and last file index, and the offset, expanded size and compressed size of the first and last files (64-bit, 64 bytes in all). v5: 32-bit equivalents (40 bytes); a last-file offset of 0 means "none". |
| Strings | NUL-terminated (shown as cp1252); UTF-16LE when the major version is 17 or later. |

**File flags.** The flags are 1 (split across volumes), 2 (obfuscated), 4 (compressed) and 8 (invalid). An entry is valid when flag 8 is clear and both its name offset and data offset are non-zero. Link flag 1 (`LINK_PREV`) means the entry reuses the stored data of `link_previous`.

**Split files.** Reading starts at the descriptor's volume and continues into later volumes. In each volume, a split file uses that volume's last-file fields when it is the volume's last file, and its first-file fields when it is the volume's first file. In v5, split files carry no flag. A split is inferred when a volume's first or last compressed size differs from the descriptor's.

**Compressed data.** The stored bytes are a sequence of `u16 length` + raw-deflate chunks. Each chunk is an independent stream, inflated with `wbits = -15`. Like unshield, the reader appends one zero byte when a stream needs it. Each chunk expands to at most 64 KiB in this media; the reader allows up to 1 MiB.

**Obfuscation.** Each stored byte, including the length prefixes, decodes as `ror8(b ^ 0xD5, 2) - (seed % 0x47)`. The seed starts at 0 for each file and increases by one per byte, across volume boundaries.

**Verification.** The output size must equal the expanded size. In v6+, the MD5 of the expanded bytes must match the stored digest. (unshield also skips the MD5 check for v5.)

## API

- `Cabinet(header, volume_opener=None, *, major_version=None)`. The header can be a path, bytes or a stream: a `.hdr`, or a `data1.cab` that embeds the header.
- `Cabinet.from_directory(dir)` opens the cabinets from a folder. `Cabinet.from_isos([iso, ...])` reads them in place from ISO9660 images, so nothing is copied out first.
- `groups()`, `components()` and `directories()` list the header's contents.
- `files(groups=None, patterns=None, include_invalid=False)` lists files. Both filters are case-insensitive globs, and group names match either their stored form or unshield's form (`Sounds_-_Basic`).
- `find(name)` looks up one file. `entry(index)` returns a file by its index.
- `iter_chunks(entry)` streams a file with bounded memory. `read(entry, max_bytes)`, `verify(entry)` and `copy_to(entry, stream)` build on it.
- `extract(entry_or_name, out, layout="unshield", overwrite=False)` and `extract_all(out, groups, patterns, ...)` write files to disk.
- CLI: `python3 Tools/installshield_cab.py (--cabs DIR | --iso A --iso B) list|test|extract OUT [--group G] [--glob P] [--layout unshield|directory]`.

**Output layouts.** `unshield` reproduces the `unshield x` tree as `group/dir/name`. In the group and directory names, spaces, `<>[]` and non-printable bytes become `_`. In the file name, only non-printable bytes do. `directory` writes `dir/name` without the group.

**Extraction safety.** Output goes to a hidden `.partial` file, which is renamed only after verification. The reader refuses `..` components, file names that contain a separator, symlink escapes and writes through symlinks. An existing identical file is skipped (checked by MD5). A different existing file raises an error unless `overwrite=True`.

**Same-path collisions.** In `extract_all`, two different files mapping to the same case-insensitive path raise an error instead of overwriting each other. This matters with the `directory` layout: in this media, `Golfer` and `Golfer-English` both ship `chars/fend.xbx`. Extract the groups separately, in the order you want, to apply such overlays.

## Validation on the PGA Tour 2005 cabinets

Tested on the M5 Pro development Mac (24 GB) only. M1 acceptance has not been measured.

**Header contents.** The header has 8,951 file entries, 234 directories, 68 file groups and 56 components. Of the entries, 6,828 are valid; the 2,123 invalid entries are skipped, as unshield does. There are 420 valid `LINK_PREV` entries, 1,720 stored uncompressed and no obfuscated files. One file, index 5885 (`CC35_01.mp3`), is split from DATA2.CAB into DATA3.CAB.

**Comparison with unshield.** Every valid file in every group was extracted and compared by SHA-256 with unshield 1.6.2's tree in `Library/SourceMedia/pga2005/install`. All 6,828 files (985,532,659 bytes) matched, with 0 mismatches and no missing or extra paths. That covers all 36 output groups, including the requested groups:

| Group | Files |
| --- | ---: |
| Executable | 63 |
| Data-Golfball | 12 |
| Sounds - Basic | 146 |
| Courses - Generic | 535 |
| CoursesRoot | 19 |
| DataImages | 695 |
| Golfer | 75 |
| Data - Shaders | 3 |

**Timing and memory** (from `/usr/bin/time -l`):

| Run | Wall time | Peak RSS |
| --- | ---: | ---: |
| Extract all from `cabs/` (Python 3.14) | 4.1 s | 52 MB |
| Extract all directly from the two ISOs (Python 3.14) | 4.3 s | 62 MB |
| Extract all directly from the two ISOs (Apple `/usr/bin/python3` 3.9.6) | 4.5 s | 49 MB |
| Re-run over an existing identical tree (MD5 check, no writes) | 1.8 s | 49 MB |
| `test` (decompress and verify only) | 2.6 s | 37 MB |

**Synthetic fixtures.** `Tests/test_installshield_cab.py` builds v5, v6 and v17 cabinets in-test. They cover eight-volume spans, chunks straddling volumes, obfuscation, links, invalid entries, embedded headers, ISO-style openers and traversal attempts. As a one-off check, unshield 1.6.2 extracted the v6 multi-volume fixture to identical bytes and paths.

## Limitations

- Only formats and features observed or documented by unshield are supported. The v5 path and the version 17+ UTF-16 strings path are tested only with synthetic fixtures.
- The reader does not interpret component destinations or the setup script, so it does not reproduce the final installed folder layout. Use the group-prefixed layout, or select groups explicitly.
- A v5 file's MD5 is not verified, matching unshield; only size and deflate integrity are checked.
- `iter_chunks` verifies size and MD5 only when it is fully consumed. `extract`, `read`, `verify` and `copy_to` always consume it fully.
