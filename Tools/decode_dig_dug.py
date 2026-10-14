#!/usr/bin/env python3
"""Recover the selected C64 Dig Dug body by decoding two packed byte formats.

This first-party tool performs bounded literal/match and escape/run decoding,
plus known byte-range relocation. It executes no 6502 instructions and contains
no CPU, C64, VIC or SID interpreter. Original outputs stay in ignored media.
"""
import argparse
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SOURCE_SHA256 = "cdac1a545475cc547f6b608cb14bc8b6fabd22c444b66fbc8a45ee4eb11f4333"
INTRO_SHA256 = "6dacb993fa16ae61102a7d64aaf34e5b362a7a40b1aa4e963c83f81c4efb4891"
SECOND_STAGE_SHA256 = "b96ff9ffcce59737777f9dc1c6228bf8150a8f2adcfeb4cb5281e6ab20e7430d"
GAME_SHA256 = "90d52fc5c20d64d033d135d16146f5da01e369681373f74756cf33c562de0cda"


class DecodeError(ValueError):
    pass


class _EndMarker(Exception):
    pass


def sha256(data):
    return hashlib.sha256(data).hexdigest()


@dataclass(frozen=True)
class BackwardReceipt:
    consumed_bytes: int
    remaining_bits: int
    literal_bytes: int
    match_bytes: int


class BackwardBits:
    def __init__(self, data, initial_byte):
        self.data = data
        self.cursor = len(data) - 1
        self.byte = initial_byte
        self.remaining = 8

    def read(self, width):
        if not 0 <= width <= 16:
            raise DecodeError("Unsupported packed bit width")
        value = 0
        for _ in range(width):
            if self.remaining == 0:
                if self.cursor < 0:
                    raise DecodeError("Truncated backward bit stream")
                self.byte = self.data[self.cursor]
                self.cursor -= 1
                self.remaining = 8
            value = (value << 1) | (self.byte >> 7)
            self.byte = (self.byte << 1) & 255
            self.remaining -= 1
        return value


def decode_backward(data, table, initial_byte, max_output=32768):
    """Decode the first layer's MSB-first backward literal/match format."""
    if len(table) != 256 or not 0 <= initial_byte <= 255 or not 0 < max_output <= 65536:
        raise DecodeError("Invalid backward decoder bounds")
    bits = BackwardBits(data, initial_byte)
    output = bytearray()
    literal_bytes = match_bytes = 0

    def run(start):
        # The source uses unary table selection and bit 4 as its end marker.
        # A nonterminating selector is malformed; never wrap through the table.
        for advance in range(1, 33):
            index = (start + advance) & 255
            if bits.read(1):
                if index & 16:
                    raise _EndMarker()
                return (bits.read(table[index]) + table[index + 16]) & 255
        raise DecodeError("Unterminated packed run selector")

    def append(value):
        if len(output) >= max_output:
            raise DecodeError("Decoded backward data exceeds bound")
        output.append(value)

    try:
        while True:
            count = run(255)
            for _ in range(count):
                append(bits.read(8))
                literal_bytes += 1

            length_minus_one = (run(31) - 1) & 255
            if length_minus_one == 0:
                offset = bits.read(4)
            else:
                group = bits.read(2 if length_minus_one == 1 else 3)
                if length_minus_one >= 2:
                    group += 4
                for _ in range(2):
                    offset = (bits.read(table[0x40 + group]) + table[0x4D + group]
                              + 256 * table[0x5A + group])
                    if offset == 122 and group >= 4:
                        group = 12
                    else:
                        break
                else:
                    raise DecodeError("Repeated packed distance escape")
            distance = offset + 1
            if distance > len(output):
                raise DecodeError("Packed match references unwritten data")
            for _ in range(length_minus_one + 1):
                append(output[-distance])
                match_bytes += 1
    except _EndMarker:
        receipt = BackwardReceipt(len(data) - 1 - bits.cursor, bits.remaining,
                                  literal_bytes, match_bytes)
        return bytes(reversed(output)), receipt


def decode_runs(data, max_output=40960):
    """Decode the second layer's five escape markers and 8-bit run counts.

    $E2 repeats its following value by the following count; $E7 repeats a value
    three times; $D6 emits counted zeroes; $CB emits two zeroes; $C7 emits counted
    spaces. Zero counts represent 256, as in the source's decrement loop.
    """
    if not 0 < max_output <= 65536:
        raise DecodeError("Invalid run decoder bound")
    cursor = 0
    output = bytearray()

    def byte():
        nonlocal cursor
        if cursor >= len(data):
            raise DecodeError("Truncated packed run")
        value = data[cursor]
        cursor += 1
        return value

    while cursor < len(data):
        marker = byte()
        # Each group begins with X=0 and INX at $0111. The $CB path adds
        # another INX at $0148, whereas $D6's BIT skips that increment.
        count = (byte() or 256) if marker in (0xE2, 0xD6, 0xC7) else (3 if marker == 0xE7 else 2 if marker == 0xCB else 1)
        if marker in (0xE2, 0xE7):
            value = byte()
        elif marker in (0xD6, 0xCB):
            value = 0
        elif marker == 0xC7:
            value = 32
        else:
            value = marker
        if len(output) + count > max_output:
            raise DecodeError("Decoded run data exceeds bound")
        output.extend([value] * count)
    return bytes(output)


def decode_program(program):
    if len(program) != 16551 or sha256(program) != SOURCE_SHA256:
        raise DecodeError("Selected Dig Dug program identity mismatch")
    base = 0x0801
    footer = program[0x47A8 - base:0x48A8 - base]
    # The $0340 loader copies this footer to $0723..$0822, including the
    # overlapping program header. Build only those known byte ranges, rather
    # than assuming any zero-filled C64 RAM outside the supplied program.
    stream = footer + program[0x0823 - base:0x46B1 - base]
    intro, receipt = decode_backward(stream, footer, footer[0x67])
    if len(intro) != 23044 or sha256(intro) != INTRO_SHA256:
        raise DecodeError("Unpacked Dig Dug intro identity mismatch")
    if receipt.literal_bytes != 6660 or receipt.match_bytes != 16384:
        raise DecodeError("Unexpected Dig Dug first-layer extent")

    # The intro's $14C0 copy stub moves $1680 onward to $0801. Its complete
    # page loop also copies RAM outside the loaded intro; retain only known
    # source bytes. The second stream starts at $0882 and needs no unknown RAM.
    second = intro[0x1680 - base:]
    if len(second) != 19333 or sha256(second) != SECOND_STAGE_SHA256:
        raise DecodeError("Relocated Dig Dug second-layer identity mismatch")
    game = decode_runs(second[0x0882 - base:])
    if len(game) != 24576 or sha256(game) != GAME_SHA256:
        raise DecodeError("Decoded Dig Dug game identity mismatch")
    return intro, second, game, receipt


def prepare(root=ROOT):
    directory = Path(root) / "Library/SourceMedia/retro/dig-dug-c64"
    intro, second, game, receipt = decode_program((directory / "program-00.bin").read_bytes())
    metadata = {
        "schemaVersion": 1,
        "sourceProgramSHA256": SOURCE_SHA256,
        "execution": "none; bounded byte-format decoding and known range relocation only",
        "firstLayer": {"sha256": INTRO_SHA256, "bytes": len(intro), "loadAddress": 0x0801,
                       "entryAddress": 0x0C40, "role": "crack intro, not game body",
                       "literalBytes": receipt.literal_bytes, "matchBytes": receipt.match_bytes,
                       "packedBytesConsumed": receipt.consumed_bytes,
                       "remainingBits": receipt.remaining_bits},
        "secondLayer": {"sha256": SECOND_STAGE_SHA256, "bytes": len(second), "loadAddress": 0x0801,
                        "role": "known relocated packed bytes; unknown intro RAM excluded",
                        "streamAddress": 0x0882, "streamBytes": 19204},
        "game": {"sha256": GAME_SHA256, "bytes": len(game), "loadAddress": 0x6000,
                 "endExclusive": 0xC000, "trainerEntryAddress": 0x7090,
                 "entryAddress": 0x8000},
        "trainer": {"credit": "JACK ALIEN/REMEMBER", "optionalPatchesApplied": False,
                    "options": ["unlimited lives for both players", "monsters cannot hit you",
                                "rocks cannot hit you", "Commodore key level skip"],
                    "patchAddresses": [[0xA1DF], [0xB179, 0xB22A, 0xB2CF, 0xB2EB],
                                       [0xAB51, 0xAB55], [0x80C3]]},
        "qualification": "static content recovery; gameplay, graphics, audio and clocks not yet qualified",
    }
    directory.mkdir(parents=True, exist_ok=True)
    for filename, data in (("intro.bin", intro), ("stage2.bin", second), ("game.bin", game)):
        (directory / filename).write_bytes(data)
    (directory / "decode.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    metadata = prepare(args.root)
    print(json.dumps({"game": metadata["game"], "execution": metadata["execution"]}, indent=2))


if __name__ == "__main__":
    main()
