#!/usr/bin/env python3
"""Decode selected Preppie! source tables and graphics without running the game.

Preserve ordered INIT/RUN records, known relocation bytes and explicit unknown RAM.
No CPU, Atari OS, ANTIC, GTIA, POKEY or generated game is executed/interpreted.
Original arrays/binaries are only written beneath ignored Library/Prepared.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import struct
import zipfile

ARCHIVE = 'Preppie!_Atari-8-bit_ROM_EN.zip'
ARCHIVE_SHA256 = 'c9a99331845fd13d6ea3aea30127f759369a29e6b6b204a545f66500d97395be'
MEMBERS = ('Game Files/Preppie! (1982)(Adventure International)(US).zip',
           'Preppie! (1982)(Adventure International)(US).xex')
SOURCE_SHA256 = '802fd22e3b866f001ab1bffae7422c62e906461e6460540761bead260ed710f5'
KNOWN_SHA256 = 'e01ad59aee16357addb667483917cded5a490e443e97d9e38fde37b73bcd5ac7'
TABLES = {
    'joystickDirection': (0x2027, 16),
    'playerOffsetsX0': (0x2032, 4), 'playerOffsetsX1': (0x2036, 4),
    'playerMemoryPages': (0x203A, 5), 'playerMemoryOffsets': (0x203F, 5),
    'lanePhaseRegisters': (0x2044, 6), 'laneScreenOrigins': (0x2068, 6),
    'laneDisplayListOffsets': (0x206E, 6),
    'fontClearPatch': (0x2074, 40), 'fontEffectPatch': (0x209C, 40),
    'animatedFontParts': (0x20C4, 40), 'movableGlyphRows': (0x20EC, 20),
    'playerFramePointers': (0x2100, 160), 'jumpRows': (0x21AE, 4),
    'jumpAnimation': (0x21B2, 19), 'jumpVelocity': (0x21C5, 19),
    'initialScoreGlyphs': (0x21EA, 10), 'soundPeriods': (0x21FC, 37),
    'levelLaneDelays': (0x32FD, 10), 'levelEffectEnable': (0x3307, 10),
    'levelPlayerDelay': (0x3311, 10), 'levelGoalCount': (0x331B, 10),
    'levelRandomEventBase': (0x3325, 10), 'levelRandomActorBase': (0x332F, 10),
    'laneClearedCells': (0x3339, 12), 'dliHandlerPointers': (0x394C, 52),
}
CALLBACKS = {'xexInit': 0x3000, 'xexRun': 0x5580, 'loaderCallback': 0x5500,
             'gameEntry': 0x1B01, 'resetMenu': 0x1B56, 'newGame': 0x06CF,
             'immediateVBI': 0x1261, 'menuDeferredVBI': 0x13E6,
             'gameDeferredVBI': 0x12AF, 'displayListInterrupt': 0x3200,
             'countdownTimer1': 0x1012, 'musicTimer2': 0x1187}


class DecodeError(ValueError):
    pass


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def ordered_xex(data):
    if not data.startswith(b'\xff\xff') or len(data) > 64 * 1024:
        raise DecodeError('Invalid/oversized XEX')
    offset, records = 2, []
    while offset < len(data):
        if data[offset:offset+2] == b'\xff\xff':
            offset += 2
        if offset + 4 > len(data):
            raise DecodeError('Truncated XEX record')
        first, last = struct.unpack_from('<HH', data, offset)
        offset += 4
        size = last - first + 1
        if size <= 0 or offset + size > len(data) or len(records) >= 16:
            raise DecodeError('Reversed/truncated/excess XEX records')
        records.append({'loadAddress': first, 'endAddressInclusive': last,
                        'fileOffset': offset, 'data': data[offset:offset+size]})
        offset += size
    if not records: raise DecodeError('Empty XEX')
    return records


class KnownSource:
    """Only verified supplied relocation bytes; an absent byte is never zero RAM."""
    def __init__(self, data, base=0x0600):
        self.data, self.base = data, base
    def read(self, address, size):
        if size < 0 or address < self.base or address + size > self.base + len(self.data):
            raise DecodeError(f'Original read depends on unknown memory: ${address:04X}+{size}')
        return self.data[address-self.base:address-self.base+size]
    def byte(self, address):
        return self.read(address, 1)[0]
    def word(self, address):
        return int.from_bytes(self.read(address, 2), 'little')


def display_list(source, address):
    """Parse the authored finite ANTIC descriptor, not a display/CPU interpreter."""
    entries, current, row, dli = [], address, 0, 0
    heights = {2:8, 3:10, 4:8, 5:16, 6:8, 7:16, 8:8, 9:4, 10:4, 11:2, 12:1, 13:2, 14:1, 15:1}
    for _ in range(256):
        opcode = source.byte(current)
        mode = opcode & 15
        record = {'address':current, 'opcode':opcode, 'mode':mode, 'scanline':row,
                  'dli':bool(opcode & 128), 'horizontalScroll':bool(opcode & 16),
                  'verticalScroll':bool(opcode & 32)}
        current += 1
        if record['dli']: dli += 1
        if mode == 1:
            record['jumpTarget'] = source.word(current); current += 2
            record['waitVerticalBlank'] = bool(opcode & 64)
            if not record['waitVerticalBlank'] or record['jumpTarget'] != address:
                raise DecodeError('Selected static display list has unsupported non-JVB/cross-list jump')
            entries.append(record)
            return {'address':address, 'bytes':current-address, 'scanlines':row,
                    'dliCount':dli, 'entries':entries}
        if mode == 0: height = ((opcode >> 4) & 7) + 1
        else:
            height = heights[mode]
            if opcode & 64:
                record['screenAddress'] = source.word(current); current += 2
        record['height'] = height
        entries.append(record); row += height
        if row > 512: raise DecodeError('Static display exceeds native descriptor bound')
    raise DecodeError('Unterminated static display list')


def character_pixels(rows, two_bit=False):
    if len(rows) != 8 or any(not isinstance(b,int) or not 0 <= b <= 255 for b in rows):
        raise DecodeError('Expected an eight-row original character')
    shifts = (6,4,2,0) if two_bit else (7,6,5,4,3,2,1,0)
    mask = 3 if two_bit else 1
    return [(byte >> shift) & mask for byte in rows for shift in shifts]


def decode_payload(payload):
    if len(payload) != 23320 or sha256(payload) != SOURCE_SHA256:
        raise DecodeError('Selected Preppie! XEX identity changed')
    records = ordered_xex(payload)
    expected = [(0x3000,0x5000),(0x02E2,0x02E3),(0x5500,0x9000),(0x02E0,0x02E1)]
    if [(r['loadAddress'],r['endAddressInclusive'])for r in records] != expected:
        raise DecodeError('Selected ordered load layout changed')
    if records[1]['data'] != b'\x00\x30' or records[3]['data'] != b'\x80\x55':
        raise DecodeError('Selected INIT/RUN changed')
    # Exact selected $5500 code copies 59 pages. The last255 source bytes were
    # never loaded by this XEX; do not fabricate them in a flattened RAM image.
    known = records[2]['data'][0x100:]
    if len(known) != 0x3A01 or sha256(known) != KNOWN_SHA256:
        raise DecodeError('Selected known relocation changed')
    source = KnownSource(known)
    loading_source = KnownSource(records[0]['data'],0x3000)
    loading_dl = display_list(loading_source,0x3100)
    levels = []
    source_windows = []
    def take(address,size,purpose):
        value = source.read(address,size)
        source_windows.append({'address':address,'bytes':size,'purpose':purpose,'sha256':sha256(value)})
        return value
    def split_pointer(low,high,index):
        return source.byte(low+index) | source.byte(high+index) << 8
    for level in range(10):
        groups = []
        for group, size in enumerate([6,6,4,3,19]):
            pointer = split_pointer(0x2B83+group*10,0x2BB5+group*10,level)
            groups.append({'address':pointer,'bytes':list(take(pointer,size,f'level{level}-group{group}'))})
        lanes = []
        for lane in range(12):
            table = split_pointer(0x2BE7,0x2BF3,lane)
            pointer = source.word(table + level * 2)
            target = split_pointer(0x2BFF,0x2C0B,lane)
            lanes.append({'lane':lane,'address':pointer,'screenDestination':target,
                          'characters':list(take(pointer,48,f'level{level}-lane{lane}'))})
        levels.append({'index':level,'groups':groups,'lanes':lanes})
    fonts = []
    for address in (0x1800,0x1C00,0x3C00):
        data = take(address,1024,f'character-bank-${address:04X}')
        glyphs = [list(data[i*8:i*8+8])for i in range(128)]
        fonts.append({'address':address,'glyphRows':glyphs,
                      'oneBitPixels':[character_pixels(g)for g in glyphs],
                      'twoBitPixels':[character_pixels(g,True)for g in glyphs]})
    actors = []
    for part in range(5):
        for direction in range(4):
            for frame in range(4):
                pointer = source.word(0x2100 + part*32 + direction*8 + frame*2)
                record = {'part':part,'direction':direction,'frame':frame,'address':pointer}
                if pointer == 0:
                    record['unknownRAM'] = {'address':0,'bytes':10}
                else:
                    record['rows'] = list(take(pointer,10,f'actor-part{part}-direction{direction}-frame{frame}'))
                actors.append(record)
    tables = {name:list(take(address,size,name))for name,(address,size)in TABLES.items()}
    lists = [display_list(source,0x0AEB), display_list(source,0x3400)]
    for dl in lists: take(dl['address'],dl['bytes'],'static-display-list')
    dlis = [source.word(0x394C+i*2)for i in range(lists[1]['dliCount'])]
    if any(not 0x3200 <= address < 0x32C4 for address in dlis):
        raise DecodeError('DLI table points outside selected authored handlers')
    package = {'schema':1,'sourceSHA256':SOURCE_SHA256,'knownRelocationSHA256':KNOWN_SHA256,
               'loadingDisplayList':loading_dl, 'callbacks':CALLBACKS,'levels':levels,'fonts':fonts,'actorCompositeFrames':actors,
               'tables':tables,'displayLists':lists,'dliHandlerAddresses':dlis,
               'unknownMemory':[{'address':0x4001,'bytes':255,'reason':'Relocation reads beyond supplied XEX segment'},
                                {'address':0,'bytes':10,'reason':'Ten composite-pointer records read zero-page RAM'}],
               'qualification':'Static original data and callback mapping; no game or machine execution'}
    return package, records, known, source_windows


def selected_archive(root):
    path = root / ARCHIVE
    if path.stat().st_size > 1024*1024: raise DecodeError('Source archive exceeds bound')
    data = path.read_bytes()
    if sha256(data) != ARCHIVE_SHA256: raise DecodeError('Source archive identity changed')
    for member in MEMBERS:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            if archive.namelist().count(member) != 1: raise DecodeError('Missing/duplicate selected archive member')
            info = archive.getinfo(member)
            if info.file_size > 64*1024: raise DecodeError('Selected member exceeds bound')
            data = archive.read(info)
    return data


def prepare(root):
    package,records,known,windows = decode_payload(selected_archive(root))
    encoded = json.dumps(package,separators=(',',':')).encode()+b'\n'
    if len(encoded) > 256*1024: raise DecodeError('Prepared source data exceeds native bound')
    output = root / 'Library/Prepared/preppie'
    if not output.resolve().is_relative_to(root.resolve()): raise DecodeError('Prepared directory leaves workspace')
    output.mkdir(parents=True,exist_ok=True)
    for name,data in [('preppie.json',encoded),('relocated-known.bin',known)]:
        file = output/name
        if file.is_symlink(): raise DecodeError('Prepared output is a symlink')
        file.write_bytes(data)
    receipt = {'schema':1,'archiveSHA256':ARCHIVE_SHA256,'sourceSHA256':SOURCE_SHA256,
               'knownRelocationSHA256':KNOWN_SHA256,'packageSHA256':sha256(encoded),'packageBytes':len(encoded),
               'loadRecords':[{'loadAddress':r['loadAddress'],'endAddressInclusive':r['endAddressInclusive'],
                               'fileOffset':r['fileOffset'],'bytes':len(r['data']),'sha256':sha256(r['data'])}for r in records],
               'windows':windows,'counts':{'levels':10,'laneRows':120,'laneRowBytes':48,'fontBanks':3,
                                        'fontCharacters':384,'actorCompositeRecords':80,'actorKnownPointers':70,
                                        'actorDistinctKnownFrames':41,'actorUnknownPointerRecords':10,
                                        'displayLists':3,'gameDLIs':len(package['dliHandlerAddresses'])},
               'unknownMemory':package['unknownMemory'],'callbacks':CALLBACKS,
               'method':'Direct selected-byte source parsing; no execution or emulation'}
    provenance = output/'provenance.json'
    if provenance.is_symlink(): raise DecodeError('Prepared receipt is a symlink')
    provenance.write_text(json.dumps(receipt,indent=2)+'\n')
    return receipt


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parent.parent)
    args=parser.parse_args()
    receipt=prepare(args.root.resolve())
    print(f"Preppie!: {receipt['counts']['levels']} level records, {receipt['counts']['laneRows']} lane rows, {receipt['counts']['fontCharacters']} characters; {receipt['packageBytes']} bytes")
    print('Original relocation tail and zero-page sprite reads remain unknown; no source execution.')


if __name__ == '__main__': main()
