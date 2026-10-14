#!/usr/bin/env python3
"""Prepare selected 7800 Asteroids tables and original 160A pixels, without execution.

Original bytes/pixels are only written beneath ignored Library/Prepared. No CPU,
MARIA, firmware or machine is interpreted. Tables have fixed, audited ROM ranges;
original graphical rows are decoded directly from the two authored graphics banks.
"""
import argparse
import hashlib
import json
from pathlib import Path

from prepare_asteroids import REFERENCES, read_reference, parse_a78

SOURCE_SHA256 = REFERENCES[1].payload_sha256
CODE_SHA256 = 'a1e293ed0e1af9ea6a7df257440a50e40a4ae9088d6bcf4800a5a6f51780183d'
TABLES = {
    'seed': (0xD000, 55),
    'menuModes': (0xD2AF, 6),
    'demoControls': (0xD6AB, 8),
    'shipStartX': (0xD814, 2),
    'collisionScan': (0xDDE0, 9),
    'collisionX': (0xDDE9, 8),
    'collisionY': (0xDDF1, 8),
    'collisionDiagonal': (0xDDF9, 8),
    'shipOutlineX1': (0xDE01, 16),
    'shipOutlineY1': (0xDE11, 16),
    'shipOutlineX2': (0xDE21, 16),
    'shipOutlineY2': (0xDE31, 16),
    'spinStyles': (0xF3AA, 24),
    'spinMasks': (0xF3C2, 24),
    'spinRanges': (0xF3DA, 12),
    'explosionStarts': (0xF3E6, 8),
    'explosionEnds': (0xF3EE, 8),
    'initialImages': (0xF3F6, 3),
    'centerX': (0xF3F9, 7),
    'centerY': (0xF400, 7),
    'speedCaps': (0xF4B1, 4),
    'aimMasks': (0xF762, 5),
    'ufoVelocityXHigh': (0xF767, 32),
    'ufoVelocityXLow': (0xF787, 32),
    'ufoVelocityYHigh': (0xF7A7, 32),
    'ufoVelocityYLow': (0xF7C7, 32),
    'waveCaps': (0xF896, 4),
    'waveTimers': (0xF89A, 4),
    'safeRadius': (0xF9B3, 2),
    'explosionSteps': (0xDA8B, 7),
    'paletteRegisters': (0xFE25, 32),
    'objectPalettes': (0xFE45, 33),
    'menuImages': (0xFE68, 29),
    'menuPalettes': (0xFE85, 29),
    'menuX': (0xFEA2, 29),
    'menuY': (0xFEBF, 29),
    'scoreBCDLow': (0xFEDC, 8),
    'scoreBCDHigh': (0xFEE4, 8),
    'shotOffsetX': (0xFEEC, 16),
    'shotOffsetY': (0xFEFC, 16),
    'thrustLow': (0xFF0C, 32),
    'thrustHigh': (0xFF2C, 32),
    'speedLimits': (0xFF4C, 32),
    'displayZones': (0xFDF2, 51),
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def graphics(rom, bank, low, width, height=16):
    if len(rom) != 16384 or bank not in (0xC000, 0xE000):
        raise ValueError('Invalid selected ROM/graphics bank')
    if not (0 <= low <= 255 and 1 <= width <= 31 and low + width <= 256 and height in (8, 16)):
        raise ValueError('Graphics record crosses authored page or bounds')
    pixels = []
    # MARIA zone OFFSET decreases: the top authored row is the highest page.
    for row in range(height - 1, -1, -1):
        start = bank - 0xC000 + row * 256 + low
        for byte in rom[start:start + width]:
            pixels.extend((byte >> shift) & 3 for shift in (6, 4, 2, 0))
    return {'width': width * 4, 'height': height, 'pixels': pixels}


def content_digest(package):
    data = bytearray()
    for name, values in sorted(package['tables'].items()):
        data.extend(name.encode() + b'\0' + len(values).to_bytes(2, 'little') + bytes(values))
    for name, frame in sorted(package['frames'].items()):
        data.extend(name.encode() + b'\0' + frame['width'].to_bytes(2, 'little') + frame['height'].to_bytes(2, 'little') + bytes(frame['pixels']))
    return digest(data)


def decode_payload(payload):
    if digest(payload) != SOURCE_SHA256:
        raise ValueError('Selected A78 payload identity changed')
    header = parse_a78(payload)
    rom = payload[128:]
    if header['rom_sha256'] != CODE_SHA256:
        raise ValueError('Selected code identity changed')
    tables = {name: list(rom[address - 0xC000:address - 0xC000 + size])
              for name, (address, size) in TABLES.items()}
    frames = {f'objects-{low:02x}-{width}': graphics(rom, 0xC000, low, width)
              for width in (1, 2, 3) for low in range(257 - width)}
    # Original title/options use type7 and the separate E000 graphics bank.
    for image, palette in zip(tables['menuImages'], tables['menuPalettes']):
        width = 32 - (palette & 31)
        frames[f'menu-{image:02x}-{width}'] = graphics(rom, 0xE000, image, width)
    for image in range(1, 24):
        # Source score/status display's indirect CHARBASE=$E0 and eight-row zone.
        frames[f'glyph-{image}'] = graphics(rom, 0xE000, image, 1, height=8)
    result = {'schema': 1, 'sourceSHA256': SOURCE_SHA256, 'codeSHA256': CODE_SHA256,
              'tables': tables, 'frames': frames,
              'graphicsQualification': 'ROM 160A color indexes; RGB and live DMA timing unqualified',
              'rngQualification': 'Existing 256-byte RAM page and timer byte required at native initialization'}
    return result


def prepare(root):
    payload = read_reference(root, REFERENCES[1])
    result = decode_payload(payload)
    out = root / 'Library/Prepared/asteroids7800'
    out.mkdir(parents=True, exist_ok=True)
    path = out / 'asteroids7800.json'
    encoded = json.dumps(result, separators=(',', ':')).encode() + b'\n'
    if len(encoded) > 512 * 1024:
        raise ValueError('Prepared package exceeds native bound')
    path.write_bytes(encoded)
    receipt = {'schema': 1, 'sourceSHA256': SOURCE_SHA256, 'codeSHA256': CODE_SHA256,
               'packageSHA256': digest(encoded), 'packageBytes': len(encoded),
               'method': 'Static direct data decoding; no execution or emulation',
               'windows': {name: {'address': hex(address), 'fileOffset': address - 0xC000 + 128,
                                 'bytes': size, 'sha256': digest(payload[address - 0xC000 + 128:address - 0xC000 + 128 + size])}
                           for name, (address, size) in TABLES.items()},
               'frames': len(result['frames']), 'contentSHA256': content_digest(result)}
    (out / 'provenance.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    receipt = prepare(args.root.resolve())
    print(f"Prepared {receipt['frames']} original-index graphics records; {receipt['packageBytes']} bytes")


if __name__ == '__main__':
    main()
