#!/usr/bin/env python3
"""Decode corrected C64 Dig Dug sprite/bitmap formats and source level records.

This performs bounded data transforms reconstructed from supplied bytes. It
does not execute source instructions or implement C64 devices. Original arrays
and optional index-valued PNGs are written only to ignored Library/Prepared.
"""
import argparse
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GAME_SHA256 = "90d52fc5c20d64d033d135d16146f5da01e369681373f74756cf33c562de0cda"
GAME_BYTES = 24_576
MAX_DECODED = 16_384
MAX_FRAMES = 128


class GraphicsError(ValueError):
    pass


@dataclass(frozen=True)
class Block:
    index: int
    source: int
    destination: int
    parameter: int


class Body:
    def __init__(self, data: bytes):
        if len(data) != GAME_BYTES or hashlib.sha256(data).hexdigest() != GAME_SHA256:
            raise GraphicsError("Corrected Dig Dug body identity mismatch")
        self.data = data

    def read(self, address: int, count: int = 1) -> bytes:
        if count < 0 or address < 0x6000 or address + count > 0xC000:
            raise GraphicsError("Source range outside corrected body")
        return self.data[address - 0x6000:address - 0x6000 + count]

    def byte(self, address: int) -> int:
        return self.read(address)[0]

    def word(self, address: int) -> int:
        return int.from_bytes(self.read(address, 2), "little")

    def block(self, index: int) -> Block:
        if not 0 <= index < 60:
            raise GraphicsError("Block table index outside60 entries")
        return Block(index, self.byte(0x9B1A + index) | self.byte(0x9B56 + index) << 8,
                     self.byte(0x9B92 + index) | self.byte(0x9BCE + index) << 8,
                     self.byte(0x9C0A + index))


def decode_nibbles(data: bytes, lookup: bytes, limit: int = MAX_DECODED) -> tuple[bytes, int]:
    """$A7AD: FF-terminated pairs expanded through a16-byte original table."""
    if len(lookup) != 16 or not 0 < limit <= MAX_DECODED:
        raise GraphicsError("Invalid nibble table/output bound")
    output = bytearray()
    for consumed, value in enumerate(data, 1):
        if value == 255:
            return bytes(output), consumed
        if len(output) + 2 > limit:
            raise GraphicsError("Nibble output overflow")
        output.extend((lookup[value >> 4], lookup[value & 15]))
    raise GraphicsError("Missing nibble terminator")


def decode_sparse_sprites(data: bytes, inserted_rows: bytes) -> list[bytes]:
    """$8B25: skip rows, optional authored4-row prefix, per-column row literals.

    Return63 meaningful multicolor sprite bytes; VIC's64th padding byte is not
    rendered. The selected streams end at explicit pointer-table boundaries.
    """
    if len(inserted_rows) != 12 or len(data) > 8192:
        raise GraphicsError("Invalid sprite input/prefix bounds")
    cursor, frames = 0, []
    while cursor < len(data):
        if len(frames) >= MAX_FRAMES or cursor + 2 > len(data):
            raise GraphicsError("Truncated sprite header/frame bound")
        first, second = data[cursor:cursor + 2]
        cursor += 2
        skipped, rows = first & 127, second & 31
        prefix_rows = 4 if first & 128 else 0
        if rows == 0 or skipped + prefix_rows + rows > 21:
            raise GraphicsError("Sprite row extent is not a qualified21-row record")
        frame = bytearray(63)
        destination = skipped * 3
        if prefix_rows:
            frame[destination:destination + 12] = inserted_rows
            destination += 12
        for _ in range(rows):
            for column, flag in enumerate((128, 64, 32)):
                if second & flag:
                    if cursor >= len(data):
                        raise GraphicsError("Truncated sprite row literal")
                    frame[destination + column] = data[cursor]
                    cursor += 1
            destination += 3
        frames.append(bytes(frame))
    return frames


def reflect_sprite(frame: bytes, vertical: bool = False) -> bytes:
    """Native data transforms at $9371 (horizontal) and $93EA (top12 rows)."""
    if len(frame) != 63:
        raise GraphicsError("Sprite must have63 meaningful bytes")
    output = bytearray(63)
    if vertical:
        for row in range(12):
            output[(11 - row) * 3:(12 - row) * 3] = frame[row * 3:(row + 1) * 3]
    else:
        for row in range(21):
            for column in range(3):
                value = frame[row * 3 + column]
                reversed_pairs = sum(((value >> (pair * 2)) & 3) << (6 - pair * 2) for pair in range(4))
                output[row * 3 + 2 - column] = reversed_pairs
    return bytes(output)


def transform_twelve_rows(frame: bytes, shifts: bytes, masks: bytes) -> bytes:
    """$9436's authored12-row transform, preserving its source/dest ordering."""
    if len(frame) != 63 or len(shifts) != 7 or len(masks) != 7 or any(s > 7 for s in shifts):
        raise GraphicsError("Invalid twelve-row transform input")
    output = bytearray(63)
    destination, source = 33, 0
    for _ in range(3):
        for _ in range(3):
            for group in range(4):
                value = 0
                mask = masks[3 - group]
                for row in range(4):
                    table = 3 - group + row
                    masked, shift = frame[source + row * 3] & mask, shifts[table]
                    # $9461 clears carry once, then performs9-bit right rotation
                    # through it. A host logical shift loses the first row's bits.
                    value |= ((masked >> shift) | (masked << (9 - shift))) & 255
                output[destination] = value
                destination -= 3
                if destination < 0:
                    destination += 37
                    if destination == 36:
                        return bytes(output)
            source += 1
        source += 9
    raise GraphicsError("Twelve-row transform did not terminate")


def decode_run_nibbles(data: bytes, literals: bytes, limit: int = MAX_DECODED) -> tuple[bytes, int]:
    """$9537/$9557: zero-terminated nibbles; high codes repeat source byte55."""
    if len(literals) != 8 or not 0 < limit <= MAX_DECODED:
        raise GraphicsError("Invalid run-nibble literal/output bounds")
    output = bytearray()
    for consumed, byte in enumerate(data, 1):
        if byte == 0:
            return bytes(output), consumed
        for nibble in (byte >> 4, byte & 15):
            count = 1 if nibble < 8 else (nibble & 7) or 256
            if len(output) + count > limit:
                raise GraphicsError("Run-nibble output overflow")
            output.extend(bytes([literals[nibble] if nibble < 8 else 0x55]) * count)
    raise GraphicsError("Missing run-nibble terminator")


def source_level_index(level: int) -> int:
    if not 0 <= level <= 255:
        raise GraphicsError("Level is not a source byte")
    while level >= 16:
        level -= 4
    return level


def decode_levels(body: Body) -> dict:
    """Original tunnel records and enemy placements, not a rendered tunnel map."""
    horizontal = body.read(0x98F2, 14)
    vertical = body.read(0x9900, 15)
    layouts, spawns = [], []
    for index in range(16):
        pointer = body.word(0xA5C5 + index * 2)
        count = body.byte(0xA481 + index) + 1
        mask = body.byte(0xA5B5 + index)
        if count > 8:
            raise GraphicsError("Tunnel segment count exceeds source mask")
        records = body.read(pointer, count)
        segments = []
        for source_index in reversed(range(count)):
            value = records[source_index]
            x_index, y_index = value >> 4, value & 15
            if x_index >= len(horizontal) or y_index >= len(vertical):
                raise GraphicsError("Tunnel coordinate index outside source table")
            x = horizontal[x_index] + (256 if x_index >= 11 else 0)
            segments.append({"recordIndex": source_index, "xIndex": x_index, "yIndex": y_index,
                             "x": x, "y": vertical[y_index], "vertical": bool(mask & 128)})
            mask = mask << 1 & 255
        layouts.append({"index": index, "sourceAddress": pointer, "segments": segments})
        pointer = body.word(0xA5E5 + index * 2)
        if pointer < 0x6000 or pointer + 13 > 0xC000:
            spawns.append({"index": index, "sourceAddress": pointer, "available": False,
                           "reason": "Source pointer addresses startup RAM outside recovered body"})
            continue
        records = body.read(pointer, 13)
        placements = []
        # $A402 starts count13 then decrements before reading; slot21 starts
        # at record12. $A449 skips one DEY below slot8, so monsters decrement
        # by2 (odd slots21...7), then five rocks decrement by1 (6...2).
        for source_index, slot in zip(range(12, -1, -1), (21, 19, 17, 15, 13, 11, 9, 7, 6, 5, 4, 3, 2)):
            value = records[source_index]
            x_index, y_index = value >> 4, value & 15
            if x_index >= len(horizontal) or y_index >= len(vertical):
                raise GraphicsError("Enemy coordinate index outside source table")
            active = y_index != 0
            x = horizontal[x_index] + (256 if x_index >= 11 else 0)
            y = vertical[y_index] - (2 if slot < 7 else 0) if active else 0
            placements.append({"slot": slot, "recordIndex": source_index, "active": active,
                               "x": x if x_index != 0 else 0, "y": y,
                               "xIndex": x_index, "yIndex": y_index})
        spawns.append({"index": index, "sourceAddress": pointer, "available": True,
                       "rawRecords": list(records), "placements": placements})
    return {"layouts": layouts, "spawns": spawns,
            "firstRoundLayoutIndices": [0, 1], "firstRoundSpawnIndex": 1,
            "levelIndexRule": "Keep source level byte; subtract4 while >=16",
            "limits": ["Records do not implement dig/terrain raster, pump, enemies, rocks or timing.",
                       "Index0 enemy pointer depends on external startup RAM; no values are guessed."]}


def sprite_indices(frame: bytes) -> list[int]:
    if len(frame) != 63:
        raise GraphicsError("Sprite must have63 meaningful bytes")
    return [(value >> shift) & 3 for value in frame for shift in (6, 4, 2, 0)]


def decode(body_data: bytes) -> tuple[dict, dict]:
    body = Body(body_data)
    prepared = {"schema": 1, "sourceSHA256": GAME_SHA256}
    blocks = [body.block(i) for i in range(60)]
    prepared["blocks"] = [b.__dict__ for b in blocks]
    table_pointers = [body.byte(0xA6E6 + i) | body.byte(0xA6EA + i) << 8 for i in range(4)]
    buffers, nibble_records = {}, []
    for index in (0x38, 0x39, 0x3A):
        block = blocks[index]
        lookup = body.read(table_pointers[index - 0x38], 16)
        values, consumed = decode_nibbles(body.read(block.source, 0xC000 - block.source), lookup)
        buffers[block.destination] = values
        nibble_records.append({"index": index, "sourceAddress": block.source, "consumed": consumed,
                               "destination": block.destination, "bytes": list(values)})
        if index == 0x3A:
            continuation = block.source + consumed
            extra, used = decode_nibbles(body.read(continuation, 0xC000 - continuation), body.read(table_pointers[3], 16))
            buffers[block.destination] += extra
            nibble_records.append({"index": "3A-continuation", "sourceAddress": continuation, "consumed": used,
                                   "destination": block.destination + len(values), "bytes": list(extra)})
    prepared["decodedNibbleTables"] = nibble_records
    memory = {}  # Known data writes only; absent addresses never become guessed RAM.
    for address, values in buffers.items():
        memory.update({address + i: v for i, v in enumerate(values)})
    for address in range(0x4800, 0x6000):
        memory[address] = 0 # $89BE clears4800..5CFF and5D00..5FFF via descriptors0/4.
    for address in range(0x4000, 0x43FF):
        memory[address] = 0 # descriptor1's exclusive end leaves padding at43FF unqualified.
    prefix = body.read(0x8BC2, 12)[::-1]
    streams = []
    for index in (0x33, 0x34, 0x35, 0x36):
        block = blocks[index]
        end = body.word(0x8B1B + (index - 0x33) * 2)
        if end < block.source or end - block.source > 8192:
            raise GraphicsError("Sprite stream range outside bounded format")
        if block.source >= 0xC000:
            try:
                encoded = bytes(memory[a] for a in range(block.source, end))
            except KeyError as error:
                raise GraphicsError("Sprite source depends on unknown RAM") from error
        else:
            encoded = body.read(block.source, end - block.source)
        frames = decode_sparse_sprites(encoded, prefix)
        streams.append({"index": index, "frames": len(frames), "inputBytes": len(encoded),
                        "sourceAddress": block.source, "sourceEnd": end, "destination": block.destination})
        for frame_index, frame in enumerate(frames):
            memory.update({block.destination + frame_index * 64 + i: v for i, v in enumerate(frame)})
    def read_frame(address):
        try:
            return bytes(memory[address + i] for i in range(63))
        except KeyError as error:
            raise GraphicsError("Sprite transform reads unknown data") from error
    def write_frame(address, frame):
        memory.update({address + i: v for i, v in enumerate(frame)})
    shifts, masks = body.read(0x94A5, 7), body.read(0x94AC, 7)
    for index in tuple(range(0x21, 0x25)) + tuple(range(0x25, 0x29)):
        block = blocks[index]
        write_frame(block.destination, transform_twelve_rows(read_frame(block.source), shifts, masks))
    def reflect_range(index):
        source_code = body.byte(0x8C68 + index)
        destination_code = body.byte(0x8C6F + index)
        end_code = body.byte(0x8C76 + index)
        kind = body.byte(0x8C7D + index) | body.byte(0x8C84 + index) << 8
        if kind not in (0x9371, 0x93EA) or end_code <= source_code or end_code - source_code > 64:
            raise GraphicsError("Unsupported source sprite transform")
        for code in range(source_code, end_code):
            destination = 0x4000 + (destination_code + code - source_code) * 64
            write_frame(destination, reflect_sprite(read_frame(0x4000 + code * 64), vertical=kind == 0x93EA))
    for index in (2, 1, 0, 3, 4):
        reflect_range(index)
    for index in (0x14, 0x15):
        block = blocks[index]
        values = body.read(block.source, block.parameter + 1)
        memory.update({block.destination + i: v for i, v in enumerate(values)})
    selected_codes = tuple(range(16)) + tuple(range(32, 128))
    prepared["sprites"] = [{"code": code, "width": 12, "height": 21,
                             "bytes": list(read_frame(0x4000 + code * 64))} for code in selected_codes]
    # The death sequence at $B8EC replaces only the selected animation bank.
    block = blocks[0x37]
    end = body.word(0x8B1B + 8)
    death_frames = decode_sparse_sprites(body.read(block.source, end - block.source), prefix)
    for index, frame in enumerate(death_frames):
        write_frame(block.destination + index * 64, frame)
    for index in range(0x26, 0x29):
        b = blocks[index]
        write_frame(b.destination, transform_twelve_rows(read_frame(b.source), shifts, masks))
    for index in (5, 6):
        reflect_range(index)
    prepared["deathSprites"] = [{"code": code, "width": 12, "height": 21,
                                  "bytes": list(read_frame(0x4000 + code * 64))} for code in range(16)]
    prepared["spriteStreams"] = streams + [{"index": 0x37, "frames": len(death_frames), "inputBytes": end - block.source,
                                           "sourceAddress": block.source, "sourceEnd": end, "destination": block.destination}]
    prepared["bonusSprites"] = [{"index": i, "sourceAddress": body.word(0x9125 + i * 2),
                                  "bytes": list(body.read(body.word(0x9125 + i * 2), 30))} for i in range(11)]
    shape, consumed = decode_run_nibbles(body.read(blocks[0x20].source, 0xC000 - blocks[0x20].source), body.read(0x957C, 8))
    prepared["decodedBitmapPattern"] = {"sourceAddress": blocks[0x20].source, "consumed": consumed,
                                       "destination": blocks[0x20].destination, "bytes": list(shape)}
    # $9C2A advances down a bitmap-byte column, jumping313 bytes at each
    # character-row boundary. $9D07 repeats that20-pixel column17 times.
    prepared["menuBitmapColumns"] = {"sourceAddress": 0x9F40, "columnHeight": 20, "columns": 17,
                                      "bytes": list(body.read(0x9F40, 20 * 17))}
    prepared["levels"] = decode_levels(body)
    prepared["limits"] = ["Original character font copy $D800->$1000 needs firmware not supplied by the body.",
                          "Images use original2-bit indices, not qualified C64 RGB colors or sprite priority.",
                          "Level records are content; gameplay/dig/rock/entity timing and rendered map are not implemented.",
                          "No source CPU/device execution, original-game comparison, physical input or M1 acceptance."]
    windows = [("block-pointers-and-parameters", 0x9B1A, 300), ("block-copy-fill-functions", 0x9ABD, 93),
               ("sparse-sprite-decoder", 0x8B25, 168), ("sprite-source-ends", 0x8B1B, 10),
               ("sprite-transform-functions", 0x9371, 307), ("sprite-transform-descriptors", 0x8C68, 35),
               ("packed-nibble-decoder", 0xA7A5, 58), ("run-nibble-decoder", 0x9537, 69),
               ("tunnel-layout-and-spawn-tables", 0xA481, 388), ("layout-and-spawn-consumers", 0xA355, 300),
               ("level-index", 0xA6D8, 14), ("coordinate-tables", 0x98F2, 29),
               ("menu-bitmap-columns", 0x9F40, 340)]
    receipt = {"schema": 1, "body_sha256": GAME_SHA256, "body_bytes": GAME_BYTES,
               "method": "bounded native format decoding of corrected body; no target execution",
               "block_count": 60, "sprite_count": len(prepared["sprites"]), "death_sprite_count": 16,
               "sprite_stream_frame_counts": [record["frames"] for record in prepared["spriteStreams"]],
               "bonus_sprite_count": 11, "layout_count": 16, "source_backed_spawn_records": 15,
               "spawn_record_bytes": 13, "unresolved_spawn_records": 1,
               "decoded_nibble_table_bytes": [len(record["bytes"]) for record in nibble_records],
               "decoded_bitmap_pattern_bytes": len(shape), "menu_bitmap_column_bytes": 340,
               "windows": [{"name": name, "address": f"${address:04X}", "body_offset": address - 0x6000,
                            "bytes": count, "sha256": hashlib.sha256(body.read(address, count)).hexdigest()}
                           for name, address, count in windows], "limits": prepared["limits"]}
    return prepared, receipt


def prepare(root: Path, preview: bool = False) -> dict:
    path = root / "Library/SourceMedia/retro/dig-dug-c64/game.bin"
    if path.stat().st_size != GAME_BYTES:
        raise GraphicsError("Corrected body size mismatch")
    data = path.read_bytes()
    prepared, receipt = decode(data) # identity and every format validated before output
    output = root / "Library/Prepared/dig-dug-graphics"
    output.mkdir(parents=True, exist_ok=True)
    (output / "dig-dug-graphics.json").write_text(json.dumps(prepared, separators=(",", ":")) + "\n")
    if preview:
        from PIL import Image
        for group in ("sprites", "deathSprites"):
            records = prepared[group]
            montage = Image.new("L", (16 * 28, ((len(records) + 15) // 16) * 25))
            for i, record in enumerate(records):
                image = Image.new("L", (12, 21))
                image.putdata([v * 85 for v in sprite_indices(bytes(record["bytes"]))])
                image = image.resize((24, 21), resample=Image.Resampling.NEAREST)
                montage.paste(image, ((i % 16) * 28 + 2, (i // 16) * 25 + 2))
            montage.save(output / f"{group}-indices.png")
        columns = prepared["menuBitmapColumns"]
        logo = Image.new("L", (columns["columns"] * 4, columns["columnHeight"]))
        for column in range(columns["columns"]):
            for row in range(columns["columnHeight"]):
                value = columns["bytes"][column * columns["columnHeight"] + row]
                for pair in range(4):
                    logo.putpixel((column * 4 + pair, row), ((value >> (6 - pair * 2)) & 3) * 85)
        logo.resize((columns["columns"] * 8, columns["columnHeight"]), resample=Image.Resampling.NEAREST).save(output / "menu-bitmap-indices.png")
    return receipt


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--preview", action="store_true", help="Write gray index-valued PNGs; colors are unqualified")
    args = parser.parse_args()
    receipt = prepare(args.root.resolve(), preview=args.preview)
    if args.receipt:
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Decoded {receipt['sprite_count']} initialized sprite slots,16 layouts and15 source-backed spawn records")


if __name__ == "__main__":
    main()
