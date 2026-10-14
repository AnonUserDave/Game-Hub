#!/usr/bin/env python3
"""Pure-Python reader for InstallShield 5+ cabinets (``ISc(`` DATA1.HDR + DATAn.CAB).

Standard library only (struct, zlib, hashlib). It parses the header's file
table, directories, file groups and components, then streams files out of
spanned volumes one compressed chunk at a time. Every file's expanded size and,
for version 6+ headers, its stored MD5 are verified before an output file is
renamed into place. Memory use is bounded by one chunk plus small per-volume
read buffers; a volume is never loaded whole, and volumes can be read straight
out of ISO9660 images. Installer code is never executed.

Format notes and validation: docs/research/INSTALLSHIELD-CAB.md.

Library use::

    with Cabinet.from_directory("Library/SourceMedia/pga2005/cabs") as cab:
        for entry in cab.files(groups=["Data - Shaders"], patterns=["*.fx"]):
            cab.extract(entry, "Library/Imported/pga2005/install")
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import fnmatch
import hashlib
import io
import os
from pathlib import Path, PurePosixPath
import re
import struct
import sys
from typing import BinaryIO, Callable, Iterable, Iterator, Sequence
import zlib

SIGNATURE = b"ISc("
COMMON_HEADER = struct.Struct("<4sIIII")          # 20 bytes
CAB_DESCRIPTOR_FIXED = 0x3E                       # bytes before the hash tables
HASH_BUCKETS = 71                                 # file-group and component tables
VOLUME_HEADER_V5 = struct.Struct("<10I")          # 40 bytes after the common header
VOLUME_HEADER_V6 = struct.Struct("<QIIQQQQQQ")    # 64 bytes after the common header
FILE_DESCRIPTOR_V5 = struct.Struct("<IIHII20sI16s")         # 0x3A bytes
FILE_DESCRIPTOR_V6 = struct.Struct("<HQQQ16s16sIH12sIIBH")  # 0x57 bytes

FILE_SPLIT = 0x1
FILE_OBFUSCATED = 0x2
FILE_COMPRESSED = 0x4
FILE_INVALID = 0x8
LINK_PREV = 0x1
LINK_NEXT = 0x2

V5_NO_LAST_FILE = 0x7FFFFFFF
MAX_HEADER_BYTES = 256 * 1024**2
SMALL_HEADER_FILE = 64 * 1024**2
MAX_VOLUME_NUMBER = 999
MAX_STRING_BYTES = 64 * 1024
CHUNK_OUTPUT_LIMIT = 1024**2       # unshield itself stops at 64 KiB per chunk
COPY_BLOCK = 1024**2
VOLUME_BUFFER = 1024**2
DEFAULT_READ_LIMIT = 64 * 1024**2
LAYOUTS = ("unshield", "directory")


class CabinetError(ValueError):
    """Malformed, unsupported, truncated, unsafe or unverifiable cabinet data."""


@dataclass(frozen=True)
class FileGroup:
    name: str
    first_file: int
    last_file: int


@dataclass(frozen=True)
class Component:
    name: str
    file_groups: tuple[str, ...]


@dataclass(frozen=True)
class CabFile:
    """One file-table entry, as reached through ``group`` (None if ungrouped)."""

    index: int
    name: str
    directory: str              # as stored, backslash separated
    group: str | None
    size: int                   # expanded bytes
    compressed_size: int
    md5: str                    # stored digest of the expanded bytes (hex)
    flags: int
    volume: int
    data_offset: int
    link_previous: int = 0
    link_flags: int = 0
    valid: bool = True
    raw_name: bytes = field(default=b"", repr=False, compare=False)
    raw_directory: bytes = field(default=b"", repr=False, compare=False)
    raw_group: bytes | None = field(default=None, repr=False, compare=False)

    @property
    def path(self) -> str:
        """Directory and name joined with ``/`` (no group, no sanitising)."""
        directory = self.directory.replace("\\", "/").strip("/")
        return f"{directory}/{self.name}" if directory else self.name

    @property
    def compressed(self) -> bool:
        return bool(self.flags & FILE_COMPRESSED)

    @property
    def obfuscated(self) -> bool:
        return bool(self.flags & FILE_OBFUSCATED)

    @property
    def split(self) -> bool:
        return bool(self.flags & FILE_SPLIT)

    def relative_path(self, layout: str = "unshield") -> PurePosixPath:
        """Safe output path for ``layout``.

        ``unshield`` reproduces ``unshield -d OUT x`` exactly: ``group/dir/name``
        with spaces, ``<>[]`` and non-printable bytes in the group and directory
        replaced by ``_`` and non-printable bytes in the name replaced by ``_``.
        ``directory`` is the installed layout ``dir/name`` without the group.
        Raises CabinetError for absolute or ``..`` paths and names containing a
        path separator.
        """
        if self.raw_name and any(b in b"/\\" for b in self.raw_name):
            raise CabinetError(f"Unsafe file name in cabinet: {self.name!r}")
        if layout == "unshield":
            parts = []
            if self.raw_group:
                parts += _unshield_directory(self.raw_group).split("/")
            parts += _unshield_directory(self.raw_directory).split("/")
            parts.append(_unshield_name(self.raw_name))
        elif layout == "directory":
            parts = _printable(self.directory).replace("\\", "/").split("/")
            parts.append(_printable(self.name))
        else:
            raise ValueError(f"Unknown layout {layout!r}; expected one of {LAYOUTS}")
        return _safe_relative(parts, self.name)


def _printable(text: str) -> str:
    return "".join("_" if ord(c) < 0x20 or ord(c) == 0x7F else c for c in text)


def _unshield_directory(raw: bytes) -> str:
    out = []
    for byte in raw:
        if byte == 0x5C:
            out.append("/")
        elif byte in b" <>[]" or not 0x20 <= byte <= 0x7E:
            out.append("_")
        else:
            out.append(chr(byte))
    return "".join(out)


def _unshield_name(raw: bytes) -> str:
    return "".join(chr(b) if 0x20 <= b <= 0x7E else "_" for b in raw)


def _safe_relative(parts: Iterable[str], label: str) -> PurePosixPath:
    clean = []
    for part in parts:
        if part in ("", "."):
            continue
        if part == ".." or "\x00" in part:
            raise CabinetError(f"Path traversal refused for {label!r}")
        clean.append(part)
    if not clean:
        raise CabinetError(f"Empty output path for {label!r}")
    return PurePosixPath(*clean)


# --------------------------------------------------------------------------
# Obfuscation: each stored byte b becomes ror8(b ^ 0xD5, 2) - (seed % 0x47),
# with the seed starting at 0 for each file and advancing once per byte read,
# including chunk length prefixes and across volume boundaries.

_ROR_TABLE = bytes((((b ^ 0xD5) >> 2) | ((b ^ 0xD5) << 6)) & 0xFF for b in range(256))
_SUBTRACT_TABLES = [bytes((v - k) & 0xFF for v in range(256)) for k in range(0x47)]


def deobfuscate(data: bytes, seed: int) -> bytes:
    """Undo InstallShield's byte obfuscation for ``data`` starting at ``seed``."""
    out = bytearray(data.translate(_ROR_TABLE))
    for key in range(0x47):
        start = (key - seed) % 0x47
        if start < len(out):
            out[start::0x47] = out[start::0x47].translate(_SUBTRACT_TABLES[key])
    return bytes(out)


def _inflate_chunk(payload: bytes) -> bytes:
    decoder = zlib.decompressobj(-zlib.MAX_WBITS)
    try:
        out = decoder.decompress(payload, CHUNK_OUTPUT_LIMIT)
        if not decoder.eof:
            if decoder.unconsumed_tail or len(out) >= CHUNK_OUTPUT_LIMIT:
                raise CabinetError("Compressed chunk expands beyond the 1 MiB limit")
            # unshield appends one zero byte before inflating; mirror it.
            out += decoder.decompress(b"\x00", CHUNK_OUTPUT_LIMIT - len(out))
    except zlib.error as error:
        raise CabinetError(f"Corrupt deflate chunk: {error}") from None
    if not decoder.eof:
        raise CabinetError("Truncated deflate chunk")
    return out


# --------------------------------------------------------------------------
# Volume sources.

VolumeOpener = Callable[[int], BinaryIO]


def _volume_prefix(header_name: str) -> str:
    match = re.match(r"^(.*?)\d+$", Path(header_name).stem)
    return match.group(1) if match else "data"


def directory_opener(directory: str | os.PathLike, prefix: str = "data") -> VolumeOpener:
    """Open ``<prefix><n>.cab`` volumes from ``directory`` case-insensitively."""
    root = Path(directory)
    listing: dict[str, Path] = {}

    def opener(number: int) -> BinaryIO:
        wanted = f"{prefix}{number}.cab".casefold()
        if wanted not in listing:
            listing.clear()
            if root.is_dir():
                listing.update({p.name.casefold(): p for p in root.iterdir() if p.is_file()})
        path = listing.get(wanted)
        if path is None:
            raise CabinetError(f"Missing cabinet volume {prefix}{number}.cab in {root}")
        return open(path, "rb", buffering=VOLUME_BUFFER)

    return opener


class _ISOEntryRaw(io.RawIOBase):
    """Seekable read-only view of one ISO9660 file (``inspect_pga2005.ISO9660``)."""

    def __init__(self, iso, entry: dict, block: int = 2048):
        super().__init__()
        self._iso = iso
        self._start = entry["logical_sector"] * block
        self._size = entry["bytes"]
        self._pos = 0

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self._pos

    def seek(self, offset, whence=io.SEEK_SET):
        base = {io.SEEK_SET: 0, io.SEEK_CUR: self._pos, io.SEEK_END: self._size}[whence]
        if base + offset < 0:
            raise OSError("Negative seek in ISO entry")
        self._pos = base + offset
        return self._pos

    def readinto(self, buffer):
        amount = min(len(buffer), self._size - self._pos)
        if amount <= 0:
            return 0
        data = self._iso.read(self._start + self._pos, amount)
        buffer[:amount] = data
        self._pos += amount
        return amount


def _iso_index(isos: Sequence) -> dict[str, tuple[object, dict]]:
    index: dict[str, tuple[int, object, dict]] = {}
    for iso in isos:
        for entry in iso.files():
            name = PurePosixPath(entry["path"]).name.casefold()
            depth = len(PurePosixPath(entry["path"]).parts)
            if name not in index or depth < index[name][0]:
                index[name] = (depth, iso, entry)
    return {name: (iso, entry) for name, (_, iso, entry) in index.items()}


def iso_volume_opener(isos: Sequence, prefix: str = "data") -> VolumeOpener:
    """Open ``<prefix><n>.cab`` straight out of ISO9660 images (no temp copies)."""
    index = _iso_index(isos)

    def opener(number: int) -> BinaryIO:
        found = index.get(f"{prefix}{number}.cab".casefold())
        if found is None:
            raise CabinetError(f"Missing cabinet volume {prefix}{number}.cab on the supplied discs")
        return io.BufferedReader(_ISOEntryRaw(*found), VOLUME_BUFFER)

    return opener


def _read_header_stream(stream: BinaryIO) -> bytes:
    """Read only the header region (bounded) from a .hdr or header-bearing .cab."""
    stream.seek(0)
    head = stream.read(COMMON_HEADER.size)
    if len(head) != COMMON_HEADER.size or head[:4] != SIGNATURE:
        raise CabinetError("Not an InstallShield cabinet header (missing ISc( signature)")
    _, _, _, descriptor_offset, descriptor_size = COMMON_HEADER.unpack(head)
    if not descriptor_size:
        raise CabinetError("Cabinet has no header descriptor (data-only volume?)")
    stream.seek(descriptor_offset)
    descriptor = stream.read(0x30)
    if len(descriptor) != 0x30:
        raise CabinetError("Truncated cabinet descriptor")
    table_offset, = struct.unpack_from("<I", descriptor, 0x0C)
    table_size, = struct.unpack_from("<I", descriptor, 0x14)
    end = descriptor_offset + max(descriptor_size, table_offset + table_size,
                                  CAB_DESCRIPTOR_FIXED + 8 * HASH_BUCKETS)
    total = stream.seek(0, io.SEEK_END)
    if total <= SMALL_HEADER_FILE:
        end = total         # a .hdr (or small single-volume .cab): keep all of it
    if end > MAX_HEADER_BYTES:
        raise CabinetError(f"Cabinet header claims {end} bytes; refusing")
    stream.seek(0)
    data = stream.read(end)
    if len(data) != end:
        raise CabinetError("Truncated cabinet header")
    return data


@dataclass(frozen=True)
class _VolumeHeader:
    data_offset: int
    first_file_index: int
    last_file_index: int
    first_file_offset: int
    first_file_expanded: int
    first_file_compressed: int
    last_file_offset: int
    last_file_expanded: int
    last_file_compressed: int


@dataclass
class _Descriptor:
    index: int
    flags: int
    size: int
    compressed_size: int
    data_offset: int
    md5: bytes
    name_offset: int
    directory_index: int
    volume: int
    link_previous: int = 0
    link_next: int = 0
    link_flags: int = 0

    @property
    def valid(self) -> bool:
        return not self.flags & FILE_INVALID and bool(self.name_offset) and bool(self.data_offset)


class _SpanReader:
    """Stored (compressed/obfuscated) bytes of one file across volumes."""

    def __init__(self, cabinet: "Cabinet", fd: _Descriptor):
        self.cab = cabinet
        self.fd = fd
        self.split = bool(fd.flags & FILE_SPLIT)
        self.compressed = bool(fd.flags & FILE_COMPRESSED)
        self.obfuscated = bool(fd.flags & FILE_OBFUSCATED)
        self.seed = 0
        self.volume = 0
        self.stream: BinaryIO | None = None
        self.position = 0
        self.left = 0
        start = fd.volume
        if cabinet.major_version <= 5:
            # v5 descriptors do not name their volume; walk forward to it.
            while fd.index > cabinet._volume(start)[1].last_file_index:
                start += 1
                if start > MAX_VOLUME_NUMBER:
                    raise CabinetError(f"No volume holds file {fd.index}")
        self._open(start)

    def _open(self, number: int):
        if not 0 < number <= MAX_VOLUME_NUMBER:
            raise CabinetError(f"Invalid volume number {number} for file {self.fd.index}")
        stream, header = self.cab._volume(number)
        fd = self.fd
        if self.cab.major_version == 5:
            # IS5 marks split files only through the volume headers.
            if (fd.index < self.cab.file_count - 1 and fd.index == header.last_file_index
                    and header.last_file_compressed != fd.compressed_size):
                self.split = True
            elif (fd.index > 0 and fd.index == header.first_file_index
                    and header.first_file_compressed != fd.compressed_size):
                self.split = True
        self.volume, self.stream, self.left = number, stream, 0
        if self.split:
            if fd.index == header.last_file_index and header.last_file_offset != V5_NO_LAST_FILE:
                offset = header.last_file_offset
                expanded, compressed = header.last_file_expanded, header.last_file_compressed
            elif fd.index == header.first_file_index:
                offset = header.first_file_offset
                expanded, compressed = header.first_file_expanded, header.first_file_compressed
            else:
                return      # this volume holds none of the file; try the next one
        else:
            offset, expanded, compressed = fd.data_offset, fd.size, fd.compressed_size
        self.position = offset
        self.left = compressed if self.compressed else expanded

    def read(self, size: int) -> bytes:
        parts = []
        need = size
        while need:
            if not self.left:
                if not self.split:
                    raise CabinetError(f"File {self.fd.index} runs past its stored extent")
                self._open(self.volume + 1)
                continue
            take = min(need, self.left)
            self.stream.seek(self.position)
            data = self.stream.read(take)
            if len(data) != take:
                raise CabinetError(f"Volume {self.volume} is truncated (file {self.fd.index})")
            parts.append(data)
            self.position += take
            self.left -= take
            need -= take
        data = parts[0] if len(parts) == 1 else b"".join(parts)
        if self.obfuscated:
            data = deobfuscate(data, self.seed)
            self.seed += len(data)
        return data


class Cabinet:
    """An InstallShield cabinet set: one header plus DATAn.CAB volumes.

    ``header`` is a path, bytes, or a binary stream holding ``data1.hdr`` (or a
    ``data1.cab`` that embeds its header). ``volume_opener(n)`` returns a
    seekable binary stream for volume ``n`` (1-based); when ``header`` is a path
    it defaults to the same directory and file prefix.
    """

    def __init__(self, header, volume_opener: VolumeOpener | None = None, *,
                 major_version: int | None = None):
        self._resources: list = []
        if isinstance(header, (bytes, bytearray, memoryview)):
            data = bytes(header)
        elif hasattr(header, "read"):
            data = _read_header_stream(header)
        else:
            path = Path(header)
            with open(path, "rb") as stream:
                data = _read_header_stream(stream)
            if volume_opener is None:
                volume_opener = directory_opener(path.parent, _volume_prefix(path.name))
        self._data = data
        self._opener = volume_opener
        self._volumes: dict[int, tuple[BinaryIO, _VolumeHeader]] = {}
        self._parse(major_version)

    # ---- construction helpers -------------------------------------------
    @classmethod
    def from_directory(cls, directory, prefix: str = "data") -> "Cabinet":
        root = Path(directory)
        names = {p.name.casefold(): p for p in root.iterdir() if p.is_file()} if root.is_dir() else {}
        header = names.get(f"{prefix}1.hdr") or names.get(f"{prefix}1.cab")
        if header is None:
            raise CabinetError(f"No {prefix}1.hdr or {prefix}1.cab in {root}")
        return cls(header, directory_opener(root, prefix))

    @classmethod
    def from_isos(cls, iso_paths: Iterable, prefix: str = "data") -> "Cabinet":
        """Read the header and volumes directly from ISO9660 images."""
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        try:
            from inspect_pga2005 import ISO9660
        finally:
            sys.path.pop(0)
        isos = []
        try:
            for path in iso_paths:
                isos.append(ISO9660(Path(path)))
            index = _iso_index(isos)
            found = index.get(f"{prefix}1.hdr") or index.get(f"{prefix}1.cab")
            if found is None:
                raise CabinetError(f"No {prefix}1.hdr or {prefix}1.cab on the supplied discs")
            with io.BufferedReader(_ISOEntryRaw(*found), VOLUME_BUFFER) as stream:
                header = _read_header_stream(stream)
            cabinet = cls(header, iso_volume_opener(isos, prefix))
        except BaseException:
            for iso in isos:
                iso.close()
            raise
        cabinet._resources.extend(isos)
        return cabinet

    def close(self):
        for stream, _ in self._volumes.values():
            stream.close()
        self._volumes.clear()
        for resource in self._resources:
            resource.close()
        self._resources.clear()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    # ---- header parsing ---------------------------------------------------
    def _unpack(self, fmt: str | struct.Struct, offset: int):
        try:
            if isinstance(fmt, struct.Struct):
                return fmt.unpack_from(self._data, offset)
            return struct.unpack_from(fmt, self._data, offset)
        except struct.error:
            raise CabinetError(f"Header field at 0x{offset:x} lies outside the header") from None

    def _string(self, offset: int) -> tuple[str, bytes]:
        if offset < 0 or offset >= len(self._data):
            raise CabinetError(f"String at 0x{offset:x} lies outside the header")
        if self.unicode:
            end = offset
            while True:
                end = self._data.find(b"\x00\x00", end, offset + MAX_STRING_BYTES)
                if end < 0:
                    raise CabinetError(f"Unterminated string at 0x{offset:x}")
                if (end - offset) % 2 == 0:
                    break
                end += 1
            text = self._data[offset:end].decode("utf-16-le", errors="replace")
            return text, text.encode("utf-8")
        end = self._data.find(b"\x00", offset, offset + MAX_STRING_BYTES)
        if end < 0:
            raise CabinetError(f"Unterminated string at 0x{offset:x}")
        raw = self._data[offset:end]
        return raw.decode("cp1252", errors="replace"), raw

    def _descriptor_string(self, offset: int) -> tuple[str, bytes]:
        return self._string(self._cdo + offset)

    def _parse(self, forced_major: int | None):
        signature, version, _, cdo, cds = self._unpack(COMMON_HEADER, 0)
        if signature != SIGNATURE:
            raise CabinetError("Not an InstallShield cabinet header (missing ISc( signature)")
        if not cds:
            raise CabinetError("Cabinet has no header descriptor (data-only volume?)")
        self.version = version
        if forced_major is not None:
            major = forced_major
        elif version >> 24 == 1:
            major = (version >> 12) & 0xF
        elif version >> 24 in (2, 4):
            major = (version & 0xFFFF) // 100
        else:
            raise CabinetError(f"Unknown cabinet version 0x{version:08x}; pass major_version")
        self.major_version = major
        self.unicode = major >= 17
        self._cdo = cdo
        self._table_offset, = self._unpack("<I", cdo + 0x0C)
        self.directory_count, = self._unpack("<I", cdo + 0x1C)
        self.file_count, = self._unpack("<I", cdo + 0x28)
        self._table_offset2, = self._unpack("<I", cdo + 0x2C)
        table = cdo + self._table_offset
        entries = self.directory_count + (self.file_count if major <= 5 else 0)
        if table + 4 * entries > len(self._data):
            raise CabinetError("File table lies outside the header")
        self._table = struct.unpack_from(f"<{entries}I", self._data, table)
        self._directories = [self._string(table + self._table[i]) if self._table[i] else ("", b"")
                             for i in range(self.directory_count)]
        self._descriptors = [self._read_descriptor(i) for i in range(self.file_count)]
        self._groups = self._read_groups()
        self._group_of: dict[int, FileGroup] = {}
        for group in self._groups:
            if group.last_file >= self.file_count and group.first_file <= group.last_file:
                raise CabinetError(f"File group {group.name!r} extends past the file table")
            for index in range(group.first_file, group.last_file + 1):
                self._group_of.setdefault(index, group)

    def _read_descriptor(self, index: int) -> _Descriptor:
        table = self._cdo + self._table_offset
        if self.major_version <= 5:
            offset = table + self._table[self.directory_count + index]
            (name, directory, flags, size, compressed, _, data_offset,
             md5) = self._unpack(FILE_DESCRIPTOR_V5, offset)
            return _Descriptor(index, flags, size, compressed, data_offset, md5, name,
                               directory, volume=1)
        offset = table + self._table_offset2 + index * FILE_DESCRIPTOR_V6.size
        (flags, size, compressed, data_offset, md5, _, name, directory, _, link_previous,
         link_next, link_flags, volume) = self._unpack(FILE_DESCRIPTOR_V6, offset)
        return _Descriptor(index, flags, size, compressed, data_offset, md5, name, directory,
                           volume, link_previous, link_next, link_flags)

    def _walk_list(self, heads_offset: int) -> Iterator[int]:
        seen = set()
        for bucket in range(HASH_BUCKETS):
            node, = self._unpack("<I", self._cdo + heads_offset + 4 * bucket)
            while node:
                if node in seen or len(seen) > 100000:
                    raise CabinetError("Cyclic group/component list in header")
                seen.add(node)
                _, descriptor, following = self._unpack("<3I", self._cdo + node)
                yield descriptor
                node = following

    def _read_groups(self) -> list[FileGroup]:
        groups = []
        skip = 0x48 if self.major_version <= 5 else 0x12
        for descriptor in self._walk_list(CAB_DESCRIPTOR_FIXED):
            base = self._cdo + descriptor
            name_offset, = self._unpack("<I", base)
            first, last = self._unpack("<II", base + 4 + skip)
            name, raw = self._descriptor_string(name_offset)
            groups.append((first, len(groups), FileGroup(name, first, last), raw))
        groups.sort(key=lambda item: (item[0], item[1]))
        self._group_raw = {g.name: raw for _, _, g, raw in groups}
        return [g for _, _, g, _ in groups]

    # ---- public queries ---------------------------------------------------
    @property
    def verifies_md5(self) -> bool:
        return self.major_version >= 6

    def groups(self) -> list[FileGroup]:
        """File groups in file-table order."""
        return list(self._groups)

    def components(self) -> list[Component]:
        skip = 0x6C if self.major_version <= 5 else 0x6B
        result = []
        for descriptor in self._walk_list(CAB_DESCRIPTOR_FIXED + 4 * HASH_BUCKETS):
            base = self._cdo + descriptor
            name_offset, = self._unpack("<I", base)
            count, table = self._unpack("<HI", base + 4 + skip)
            names = tuple(self._descriptor_string(self._unpack("<I", self._cdo + table + 4 * i)[0])[0]
                          for i in range(count))
            result.append(Component(self._descriptor_string(name_offset)[0], names))
        return result

    def directories(self) -> list[str]:
        return [text for text, _ in self._directories]

    def _entry(self, fd: _Descriptor, group: FileGroup | None) -> CabFile:
        table = self._cdo + self._table_offset
        name, raw_name = self._string(table + fd.name_offset) if fd.name_offset else ("", b"")
        if fd.directory_index < self.directory_count:
            directory, raw_directory = self._directories[fd.directory_index]
        else:
            directory, raw_directory = "", b""
        return CabFile(fd.index, name, directory, group.name if group else None, fd.size,
                       fd.compressed_size, fd.md5.hex(), fd.flags, fd.volume, fd.data_offset,
                       fd.link_previous, fd.link_flags, fd.valid, raw_name, raw_directory,
                       self._group_raw.get(group.name) if group else None)

    def entry(self, index: int) -> CabFile:
        if not 0 <= index < self.file_count:
            raise CabinetError(f"File index {index} out of range")
        return self._entry(self._descriptors[index], self._group_of.get(index))

    def files(self, groups: Iterable[str] | None = None, patterns: Iterable[str] | None = None,
              *, include_invalid: bool = False) -> Iterator[CabFile]:
        """Yield files group by group (unshield order), then any ungrouped files.

        ``groups`` and ``patterns`` are case-insensitive globs. Groups match the
        stored name or its unshield directory name (``Sounds - Basic`` or
        ``Sounds_-_Basic``); patterns match ``entry.path`` or ``entry.name``.
        Invalid entries (flag 8, or no name/data offset) are skipped unless
        ``include_invalid``; unshield skips them too.
        """
        group_globs = [g.casefold() for g in groups] if groups is not None else None
        file_globs = [p.casefold().replace("\\", "/") for p in patterns] if patterns else None

        def wanted(entry: CabFile) -> bool:
            if not include_invalid and not entry.valid:
                return False
            if file_globs is None:
                return True
            path, name = entry.path.casefold(), entry.name.casefold()
            return any(fnmatch.fnmatchcase(path, g) or fnmatch.fnmatchcase(name, g)
                       for g in file_globs)

        for group in self._groups:
            if group_globs is not None:
                names = (group.name.casefold(),
                         _unshield_directory(self._group_raw[group.name]).casefold())
                if not any(fnmatch.fnmatchcase(n, g) for n in names for g in group_globs):
                    continue
            for index in range(group.first_file, group.last_file + 1):
                entry = self._entry(self._descriptors[index], group)
                if wanted(entry):
                    yield entry
        if group_globs is None:
            for index in range(self.file_count):
                if index not in self._group_of:
                    entry = self._entry(self._descriptors[index], None)
                    if wanted(entry):
                        yield entry

    def find(self, name: str, *, group: str | None = None) -> CabFile:
        """Look up one valid file by ``dir/name`` path or bare name (case-insensitive)."""
        wanted = name.replace("\\", "/").strip("/").casefold()
        matches = {}
        for entry in self.files(None if group is None else [group]):
            candidates = [entry.path.casefold(), entry.name.casefold()]
            try:
                candidates.append(str(entry.relative_path()).casefold())
            except CabinetError:
                pass        # unsafe names stay findable; extract() refuses them
            if wanted in candidates:
                matches.setdefault(entry.index, entry)
        if not matches:
            raise CabinetError(f"No file named {name!r} in the cabinet")
        if len(matches) > 1:
            listed = ", ".join(f"{e.group}:{e.path}" for e in list(matches.values())[:5])
            raise CabinetError(f"{name!r} is ambiguous ({len(matches)} files: {listed})")
        return next(iter(matches.values()))

    # ---- data access -------------------------------------------------------
    def _volume(self, number: int) -> tuple[BinaryIO, _VolumeHeader]:
        if number in self._volumes:
            return self._volumes[number]
        if self._opener is None:
            raise CabinetError("No volume opener was supplied for this cabinet")
        try:
            stream = self._opener(number)
        except OSError as error:
            raise CabinetError(f"Cannot open cabinet volume {number}: {error}") from None
        try:
            stream.seek(0)
            v5 = self.major_version <= 5
            layout = VOLUME_HEADER_V5 if v5 else VOLUME_HEADER_V6
            raw = stream.read(COMMON_HEADER.size + layout.size)
            if len(raw) != COMMON_HEADER.size + layout.size or raw[:4] != SIGNATURE:
                raise CabinetError(f"Cabinet volume {number} has no ISc( header")
            fields = layout.unpack_from(raw, COMMON_HEADER.size)
            if v5:
                (data_offset, _, first, last, first_off, first_exp, first_comp, last_off,
                 last_exp, last_comp) = fields
                last_off = last_off or V5_NO_LAST_FILE
            else:
                (data_offset, first, last, first_off, first_exp, first_comp, last_off,
                 last_exp, last_comp) = fields
            header = _VolumeHeader(data_offset, first, last, first_off, first_exp, first_comp,
                                   last_off, last_exp, last_comp)
        except BaseException:
            stream.close()
            raise
        self._volumes[number] = (stream, header)
        return self._volumes[number]

    def _resolve(self, item) -> _Descriptor:
        if isinstance(item, CabFile):
            index = item.index
        elif isinstance(item, int):
            index = item
        elif isinstance(item, str):
            index = self.find(item).index
        else:
            raise TypeError("Expected a CabFile, file index or file name")
        if not 0 <= index < self.file_count:
            raise CabinetError(f"File index {index} out of range")
        return self._descriptors[index]

    def _data_source(self, fd: _Descriptor) -> _Descriptor:
        # A LINK_PREV entry shares the stored data of an earlier entry; unshield
        # extracts (and verifies) that entry's data instead.
        seen = set()
        while fd.link_flags & LINK_PREV:
            if fd.index in seen or not 0 <= fd.link_previous < self.file_count:
                raise CabinetError(f"Broken link chain at file {fd.index}")
            seen.add(fd.index)
            fd = self._descriptors[fd.link_previous]
        return fd

    def iter_chunks(self, item) -> Iterator[bytes]:
        """Yield the file's expanded bytes in bounded chunks (<= 1 MiB each).

        Size and MD5 are checked once the generator is exhausted; a CabinetError
        is raised then if either does not match the header.
        """
        fd = self._resolve(item)
        if not fd.valid:
            raise CabinetError(f"File {fd.index} is marked invalid or has no data")
        source = self._data_source(fd)
        if not source.valid:
            raise CabinetError(f"File {fd.index} links to invalid file {source.index}")
        return self._chunks(source, fd.index)

    def _chunks(self, fd: _Descriptor, label: int) -> Iterator[bytes]:
        reader = _SpanReader(self, fd)
        digest = hashlib.md5()
        total = 0
        if fd.flags & FILE_COMPRESSED:
            remaining = fd.compressed_size
            while remaining > 0:
                if remaining < 3:
                    raise CabinetError(f"File {label}: compressed size does not fit its chunks")
                length, = struct.unpack("<H", reader.read(2))
                if not length or length > remaining - 2:
                    raise CabinetError(f"File {label}: invalid chunk length {length}")
                out = _inflate_chunk(reader.read(length))
                remaining -= 2 + length
                total += len(out)
                if total > fd.size:
                    raise CabinetError(f"File {label}: expands past {fd.size} bytes")
                digest.update(out)
                yield out
        else:
            remaining = fd.size
            while remaining:
                out = reader.read(min(COPY_BLOCK, remaining))
                remaining -= len(out)
                total += len(out)
                digest.update(out)
                yield out
        if total != fd.size:
            raise CabinetError(f"File {label}: expanded to {total} bytes, header says {fd.size}")
        if self.verifies_md5 and digest.digest() != fd.md5:
            raise CabinetError(f"File {label}: MD5 mismatch ({digest.hexdigest()} != {fd.md5.hex()})")

    def verify(self, item) -> int:
        """Decompress and verify a file without writing it; returns its size."""
        return sum(len(chunk) for chunk in self.iter_chunks(item))

    def copy_to(self, item, stream: BinaryIO) -> int:
        total = 0
        for chunk in self.iter_chunks(item):
            stream.write(chunk)
            total += len(chunk)
        return total

    def read(self, item, max_bytes: int = DEFAULT_READ_LIMIT) -> bytes:
        """Return a whole (verified) file; refuses files larger than ``max_bytes``."""
        fd = self._resolve(item)
        if fd.size > max_bytes:
            raise CabinetError(f"File {fd.index} is {fd.size} bytes (> {max_bytes}); stream it")
        return b"".join(self.iter_chunks(fd.index))

    def _matches_existing(self, entry: CabFile, target: Path) -> bool:
        if not target.is_file() or target.stat().st_size != entry.size:
            return False
        with open(target, "rb") as stream:
            if self.verifies_md5:
                digest = hashlib.md5()
                while chunk := stream.read(COPY_BLOCK):
                    digest.update(chunk)
                return digest.digest() == self._data_source(self._descriptors[entry.index]).md5
            for chunk in self.iter_chunks(entry.index):
                if stream.read(len(chunk)) != chunk:
                    return False
            return True

    def target_path(self, item, output_dir, layout: str = "unshield") -> Path:
        """Where ``extract`` would write ``item`` (checked to stay inside output_dir)."""
        entry = item if isinstance(item, CabFile) else self._entry_for(item)
        root = Path(output_dir)
        target = root.joinpath(*entry.relative_path(layout).parts)
        if not target.resolve().is_relative_to(root.resolve()):
            raise CabinetError(f"Path escapes destination: {entry.path!r}")
        return target

    def _entry_for(self, item) -> CabFile:
        if isinstance(item, str):
            return self.find(item)
        return self.entry(self._resolve(item).index)

    def extract(self, item, output_dir, *, layout: str = "unshield",
                overwrite: bool = False) -> Path:
        """Stream one file to ``output_dir`` and return its path.

        Data goes to a hidden ``.partial`` file that is renamed only after the
        size and MD5 checks pass. An existing identical file is left alone; a
        different one raises CabinetError unless ``overwrite``.
        """
        entry = item if isinstance(item, CabFile) else self._entry_for(item)
        root = Path(output_dir)
        target = self.target_path(entry, root, layout)
        if target.is_symlink():
            raise CabinetError(f"Refusing to write through a symlink: {target}")
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.parent.resolve().is_relative_to(root.resolve()):
            raise CabinetError(f"Path escapes destination: {entry.path!r}")
        if target.exists():
            if not overwrite:
                if self._matches_existing(entry, target):
                    return target
                raise CabinetError(f"Existing file differs from the cabinet: {target}")
            if not target.is_file():
                raise CabinetError(f"Existing path is not a file: {target}")
        partial = target.with_name(f".{target.name}.partial")
        try:
            with open(partial, "wb") as out:
                self.copy_to(entry.index, out)
            os.replace(partial, target)
        finally:
            if partial.exists():
                partial.unlink()
        return target

    def extract_all(self, output_dir, groups: Iterable[str] | None = None,
                    patterns: Iterable[str] | None = None, *, layout: str = "unshield",
                    overwrite: bool = False,
                    progress: Callable[[CabFile, Path], None] | None = None) -> list[Path]:
        """Extract every selected valid file; returns the written paths.

        Two different files mapping to the same (case-insensitive) path raise
        CabinetError instead of silently overwriting each other.
        """
        plan: dict[str, CabFile] = {}
        for entry in self.files(groups, patterns):
            key = str(entry.relative_path(layout)).casefold()
            if key not in plan:
                plan[key] = entry
                continue
            first = self._data_source(self._descriptors[plan[key].index])
            second = self._data_source(self._descriptors[entry.index])
            same = first.index == second.index or (
                self.verifies_md5 and (first.size, first.md5) == (second.size, second.md5))
            if not same:
                raise CabinetError(f"Files {first.index} and {second.index} both map to "
                                   f"{entry.relative_path(layout)}; select groups or use "
                                   "the unshield layout")
        written = []
        for entry in plan.values():
            path = self.extract(entry, output_dir, layout=layout, overwrite=overwrite)
            written.append(path)
            if progress:
                progress(entry, path)
        return written


# --------------------------------------------------------------------------
# Command line.

def _open_from_args(args) -> Cabinet:
    if args.iso:
        return Cabinet.from_isos(args.iso)
    return Cabinet.from_directory(args.cabs)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--cabs", type=Path, help="directory holding data1.hdr and dataN.cab")
    source.add_argument("--iso", type=Path, action="append",
                        help="disc image holding the cabinets (repeat for each disc)")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("list", "test", "extract"):
        command = commands.add_parser(name)
        command.add_argument("--group", action="append", help="file group glob (repeatable)")
        command.add_argument("--glob", action="append", help="file path/name glob (repeatable)")
        if name == "list":
            command.add_argument("--groups", action="store_true", help="list file groups only")
        if name == "extract":
            command.add_argument("output", type=Path)
            command.add_argument("--layout", choices=LAYOUTS, default="unshield")
            command.add_argument("--overwrite", action="store_true")
    args = parser.parse_args(argv)
    with _open_from_args(args) as cab:
        if args.command == "list" and args.groups:
            for group in cab.groups():
                print(f"{group.first_file:5d}-{group.last_file:5d}  {group.name}")
            return 0
        if args.command == "list":
            for entry in cab.files(args.group, args.glob):
                print(f"{entry.size:12d}  {entry.md5}  {entry.group}  {entry.path}")
            return 0
        count = size = 0
        if args.command == "test":
            for entry in cab.files(args.group, args.glob):
                size += cab.verify(entry)
                count += 1
        else:
            for path in cab.extract_all(args.output, args.group, args.glob,
                                        layout=args.layout, overwrite=args.overwrite):
                count += 1
                size += path.stat().st_size
        print(f"{args.command}: {count} files, {size:,} bytes verified", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, CabinetError) as error:
        print(f"installshield_cab: {error}", file=sys.stderr)
        raise SystemExit(1)
