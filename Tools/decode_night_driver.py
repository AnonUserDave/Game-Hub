#!/usr/bin/env python3
"""Decode the selected C64 Night Driver's packed data, without executing 6502 code.

The first-party decoder ports the backward literal/match byte format identified
in the relocated $0108-$0195 unpacker. It is not a CPU, C64, VIC or SID emulator.
Original bytes and derived graphics are written only below ignored SourceMedia.
"""
import argparse
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SOURCE_SHA256 = "c8be3efca0b9cb49418e3e1fd3659a40b651aa864c53743a4a4a232c33394ad8"
UNPACKED_SHA256 = "df49a43b3d8b926c30f92d9434f934fd1c442907fa8e3012e1e10426f1f4a9b1"
GAME_SHA256 = "2238c3c9f844d4456edc49d4af00531b34f1caeba92d0a5f6fb83c2317c89b16"


class DecodeError(ValueError):
    pass


def sha256(data):
    return hashlib.sha256(data).hexdigest()


class BackwardStream:
    def __init__(self, data, initial_bits):
        self.data = data
        self.cursor = len(data) - 1
        self.bits = initial_bits

    def byte(self):
        if self.cursor < 0:
            raise DecodeError("Truncated backward stream")
        value = self.data[self.cursor]
        self.cursor -= 1
        return value

    def bit(self):
        bit = self.bits >> 7
        self.bits = (self.bits << 1) & 255
        if self.bits == 0:
            byte = self.byte()
            bit = byte >> 7
            self.bits = ((byte << 1) | 1) & 255
        return bit


def decode_stream(data, initial_bits, max_output=16384):
    """Bounded format decode. Returns normal-order bytes and consumed byte count."""
    if not 1 <= initial_bits <= 255 or not 0 < max_output <= 65536:
        raise DecodeError("Invalid decoder bounds or sentinel")
    stream, reversed_output = BackwardStream(data, initial_bits), bytearray()

    def append(byte):
        if len(reversed_output) >= max_output:
            raise DecodeError("Decoded data exceeds bound")
        reversed_output.append(byte)

    while True:
        literal = 0
        while True:
            literal = (literal << 1) | stream.bit()
            if literal > 65535:
                raise DecodeError("Oversized literal run")
            if literal == 0 or stream.bit() == 0:
                break
        if literal:
            # The source's 8-bit counter enters a full 256-byte run at zero.
            count = literal if literal & 255 else literal + 256
            for _ in range(count):
                append(stream.byte())

        length = 0
        while True:
            length = (length << 1) | stream.bit()
            if length >= 256:  # Overflow is the packed-format end marker.
                return bytes(reversed(reversed_output)), len(data) - 1 - stream.cursor
            if length == 0 or stream.bit() == 0:
                break

        offset = 0
        if length == 1:
            count = 1
            for _ in range(4):
                offset = (offset << 1) | stream.bit()
        else:
            count = 2 if length == 0 else length + 1
            group = stream.bit() * 2 + stream.bit()
            # $01D0..$01D3: widths of the four cumulative distance groups.
            for group_index in range(group, -1, -1):
                for _ in range((4, 2, 2, 3)[group_index]):
                    offset = (offset << 1) | stream.bit()
                if group_index:
                    offset += 1
        distance = offset + count
        if distance > len(reversed_output):
            raise DecodeError("Match references unwritten data")
        for _ in range(count):
            append(reversed_output[-distance])


def decode_program(program):
    if len(program) != 4101 or sha256(program) != SOURCE_SHA256:
        raise DecodeError("Selected Night Driver program identity mismatch")
    base, source_end = 0x0801, 0x162D
    # $0100 copies the final 256 stream bytes to $071C..$081B. Combine that
    # relocation as byte ranges; do not interpret or run the loader.
    prefix = program[source_end - base:source_end - base + 256]
    stream = prefix + program[0x081C - base:source_end - base + 1]
    unpacked, consumed = decode_stream(stream, program[0x172D - base])
    if consumed != len(stream) or len(unpacked) != 8449 or sha256(unpacked) != UNPACKED_SHA256:
        raise DecodeError("Unpacked Night Driver identity mismatch")
    # The trainer's $1FC0 copy relocates exactly 8 KiB $2000..$3FFF to $E000.
    game = unpacked[0x100:0x2100]
    if sha256(game) != GAME_SHA256:
        raise DecodeError("Relocated game identity mismatch")
    return unpacked, game


def prepare(root=ROOT):
    directory = Path(root) / "Library/SourceMedia/retro/night-driver-c64"
    program = (directory / "program-00.bin").read_bytes()
    unpacked, game = decode_program(program)

    def section(start, end):
        return list(game[start - 0xE000:end - 0xE000])

    metadata = {
        "schemaVersion": 1, "sourceProgramSHA256": SOURCE_SHA256,
        "unpackedSHA256": UNPACKED_SHA256, "gameSHA256": GAME_SHA256,
        "unpackedLoadAddress": 0x1F00, "gameLoadAddress": 0xE000,
        "resetAddress": 0xE03E, "irqAddress": 0xEBB1, "nmiAddress": 0xEC24,
        "execution": "none; static byte-format decoding and range relocation only",
        "trainer": {"author": "MANIK", "unlimitedTimePatchAddress": 0x2C0E,
                    "normalGameEquivalentAddress": 0xEC0E, "patchApplied": False},
        "tables": {
            "postDepthSchedules": [section(0xE3C3 + i * 8, 0xE3CB + i * 8) for i in range(4)],
            "acceleration": section(0xE4DA, 0xE4DE), "deceleration": section(0xE4DE, 0xE4E2),
            "gearIndicatorRows": section(0xE726, 0xE72A),
            "spriteScoreOffsets": section(0xE7A6, 0xE7AA),
        },
        "graphics": {
            "columns": 40, "rows": 25, "tileWidth": 8, "tileHeight": 8,
            "characterRows": [section(0xF800 + i * 8, 0xF808 + i * 8) for i in range(256)],
            "digitSprites": [section(0xF400 + i * 64, 0xF43F + i * 64) for i in range(10)],
            # The source offsets into one continuous 0..9,0 strip by up to seven
            # scanlines to roll from one numeral into the next.
            "scoreDigitRows": [section(0xF980 + i * 8, 0xF988 + i * 8) for i in range(11)],
            "instructions": section(0xEC4C, 0xEFBC),
            "hud": {"gear": section(0xE932, 0xE937), "speed": section(0xE937, 0xE93C),
                    "time": section(0xE93C, 0xE940), "highScore": section(0xE940, 0xE951),
                    "extendedPlay": section(0xE951, 0xE962), "timeLabel": section(0xE962, 0xE973),
                    "colors": section(0xE973, 0xE984)},
            "car": [section(start, start + 18) for start in (0xE984, 0xE996, 0xE9A8, 0xE9BA, 0xE9CC)],
            "crashPhases": []
        },
    }
    # Each crash stream is a sequence of (column,row,glyph) ending in $80.
    for phase in range(4):
        pointer_bytes = section(0xE53E + phase * 2, 0xE540 + phase * 2)
        pointer = pointer_bytes[0] + 256 * pointer_bytes[1]
        cells = []
        while game[pointer - 0xE000] < 128:
            cell = section(pointer, pointer + 3)
            if not 0 <= cell[0] < 40 or not 0 <= cell[1] < 22:
                raise DecodeError("Invalid crash-art cell")
            cells.append(cell)
            pointer += 3
        metadata["graphics"]["crashPhases"].append(cells)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "unpacked.bin").write_bytes(unpacked)
    (directory / "game.bin").write_bytes(game)
    (directory / "native-media.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    metadata = prepare(args.root)
    print(json.dumps({"gameSHA256": metadata["gameSHA256"], "execution": metadata["execution"]}, indent=2))


if __name__ == "__main__":
    main()
