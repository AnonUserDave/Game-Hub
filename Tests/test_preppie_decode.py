import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT/'Tools'))
import decode_preppie as decoder


class PreppieDecoderTests(unittest.TestCase):
    def payload(self):
        source=ROOT/'Library/SourceMedia/retro/preppie-atari-8-bit/reference-media.bin'
        if not source.is_file(): self.skipTest('Selected original Preppie! media is absent')
        return source.read_bytes()

    def test_ordered_init_run_and_known_relocation(self):
        package,records,known,_=decoder.decode_payload(self.payload())
        self.assertEqual([(r['loadAddress'],r['endAddressInclusive'])for r in records],
                         [(0x3000,0x5000),(0x2E2,0x2E3),(0x5500,0x9000),(0x2E0,0x2E1)])
        self.assertEqual(records[1]['data'],b'\x00\x30')
        self.assertEqual(records[3]['data'],b'\x80\x55')
        self.assertEqual(len(known),0x3A01)
        self.assertEqual(package['callbacks']['gameEntry'],0x1B01)
        self.assertEqual(decoder.sha256(known),decoder.KNOWN_SHA256)

    def test_source_identity_rejects_before_preparation(self):
        with self.assertRaises(decoder.DecodeError): decoder.decode_payload(b'\0'*23320)
        payload=bytearray(self.payload()); payload[100]^=1
        with self.assertRaises(decoder.DecodeError): decoder.decode_payload(payload)

    def test_unknown_relocation_tail_never_becomes_zero_ram(self):
        package,_,known,_=decoder.decode_payload(self.payload())
        source=decoder.KnownSource(known)
        self.assertEqual(source.read(0x4000,1),known[-1:])
        with self.assertRaises(decoder.DecodeError): source.read(0x4001,1)
        with self.assertRaises(decoder.DecodeError): source.read(0,10)
        self.assertEqual(package['unknownMemory'][0]['bytes'],255)

    def test_xex_malformed_bounds_and_ordered_overlap(self):
        for raw in [b'',b'\xff\xff',b'\xff\xff\x00\x20',b'\xff\xff\x00\x20\xff\x1f',
                    b'\xff\xff\x00\x20\x02\x20\x55']:
            with self.assertRaises(decoder.DecodeError): decoder.ordered_xex(raw)
        raw=b'\xff\xff\x00\x20\x00\x20\x11\x00\x20\x00\x20\x22'
        self.assertEqual([r['data']for r in decoder.ordered_xex(raw)],[b'\x11',b'\x22'])

    def test_all_authored_level_lane_and_group_records(self):
        package,_,known,_=decoder.decode_payload(self.payload())
        source=decoder.KnownSource(known)
        self.assertEqual(len(package['levels']),10)
        for index,level in enumerate(package['levels']):
            self.assertEqual(level['index'],index)
            self.assertEqual([len(g['bytes'])for g in level['groups']],[6,6,4,3,19])
            self.assertEqual(len(level['lanes']),12)
            for lane in level['lanes']:
                self.assertEqual(len(lane['characters']),48)
                self.assertEqual(bytes(lane['characters']),source.read(lane['address'],48))
        self.assertEqual(package['levels'][0]['groups'][0]['address'],0x2A4C)

    def test_player_missile_composite_preserves_unknown_zero_pointers(self):
        package,_,known,_=decoder.decode_payload(self.payload())
        source=decoder.KnownSource(known)
        actors=package['actorCompositeFrames']
        self.assertEqual(len(actors),80)
        self.assertEqual(len({a['address']for a in actors if a['address']}),41)
        self.assertEqual(sum('unknownRAM'in a for a in actors),10)
        for actor in actors:
            if actor['address']:
                self.assertEqual(bytes(actor['rows']),source.read(actor['address'],10))
            else:
                self.assertNotIn('rows',actor)
                self.assertEqual(actor['unknownRAM'],{'address':0,'bytes':10})

    def test_original_font_bit_pairs_and_shapes(self):
        package,_,known,_=decoder.decode_payload(self.payload())
        self.assertEqual([f['address']for f in package['fonts']],[0x1800,0x1C00,0x3C00])
        for font in package['fonts']:
            self.assertEqual(len(font['glyphRows']),128)
            self.assertTrue(all(len(g)==8 for g in font['glyphRows']))
            self.assertTrue(all(len(g)==64 for g in font['oneBitPixels']))
            self.assertTrue(all(len(g)==32 for g in font['twoBitPixels']))
        self.assertEqual(decoder.character_pixels([0x1b]+[0]*7,True)[:4],[0,1,2,3])
        self.assertEqual(decoder.character_pixels([0x81]+[0]*7)[:8],[1,0,0,0,0,0,0,1])
        with self.assertRaises(decoder.DecodeError): decoder.character_pixels([0]*9)

    def test_display_lists_are_static_bounded_and_preserve_dli_table(self):
        package,_,known,_=decoder.decode_payload(self.payload())
        menu,game=package['displayLists']
        self.assertEqual(menu['entries'][-1]['jumpTarget'],0x0AEB)
        self.assertEqual(game['entries'][-1]['jumpTarget'],0x3400)
        self.assertEqual(game['dliCount'],26)
        self.assertEqual(len(package['dliHandlerAddresses']),26)
        self.assertEqual(package['dliHandlerAddresses'][0],0x321A)
        with self.assertRaises(decoder.DecodeError): decoder.display_list(decoder.KnownSource(b'\x01\x00\x06'),0x600)
        with self.assertRaises(decoder.DecodeError): decoder.display_list(decoder.KnownSource(b'\x44'),0x600)

    def test_prepared_json_is_bounded_and_originals_stay_under_local_cache(self):
        payload=self.payload()
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            with patch.object(decoder,'selected_archive',return_value=payload): receipt=decoder.prepare(root)
            path=root/'Library/Prepared/preppie/preppie.json'
            data=path.read_bytes()
            self.assertLess(len(data),256*1024)
            self.assertEqual(decoder.sha256(data),receipt['packageSHA256'])
            self.assertEqual(receipt['counts']['laneRows'],120)
            self.assertEqual(receipt['counts']['actorUnknownPointerRecords'],10)
            self.assertEqual(len(json.loads(data)['unknownMemory']),2)

    def test_source_archive_bad_hash_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/decoder.ARCHIVE).write_bytes(b'wrong original')
            with self.assertRaises(decoder.DecodeError): decoder.selected_archive(root)
            self.assertFalse((root/'Library/Prepared').exists())


if __name__=='__main__': unittest.main()
