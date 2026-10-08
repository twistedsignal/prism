import copy
from concurrent.futures import ThreadPoolExecutor
import http.client
import json
import random
from pathlib import Path
import struct
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
import config
import preset_codec as codec
import schema
import server


class CodecTests(unittest.TestCase):
    def roundtrip(self, changes):
        settings = dict(codec.DEFAULTS, **changes)
        code = codec.encode(settings)
        self.assertEqual(codec.decode(code), settings)
        self.assertEqual(codec.encode(settings), code)
        return code

    def test_golden_codes_and_small_presets(self):
        for changes, golden in [({}, 'P1AP4T3g'), ({'zoom': 2}, 'P1AAxff2BY'),
                                ({'outlineSize': 4, 'outlineColor': '#FF0000'}, 'P1ADYQ5_gAB_DjzA')]:
            self.assertEqual(self.roundtrip(changes), golden)
            self.assertLessEqual(len(golden), 50)
        self.assertLessEqual(len(self.roundtrip({'text': 'Hello 😀', 'textFont': 'Gotham'})), 50)

    def test_frozen_defaults_and_order(self):
        self.assertEqual(codec.DEFAULTS, schema.DEFAULTS)
        with patch.object(schema, 'DEFAULTS', {'zoom': 4}), patch.object(schema, 'SETTINGS', {}):
            self.assertEqual(codec.decode('P1AAxff2BY')['zoom'], 2)
            self.assertEqual(codec.decode('P1AP4T3g'), codec.DEFAULTS)

    def test_exact_numbers_inactive_effects_and_unicode(self):
        self.roundtrip({'zoom': 1.2345678901234567, 'ambientIntensity': 0.51450001,
                        'glow': False, 'glowColor': '#ABCDEF', 'glowOpacity': 0.123456789,
                        'text': 'Line one\nOlá 😀 日本語', 'textFont': 'Custom font 日本語',
                        'colorOverlayColor': '#12345678'})

    def test_all_modes_and_random_full_presets(self):
        rng = random.Random(8)
        for _ in range(30):
            values = dict(codec.DEFAULTS)
            for field in codec.FIELDS:
                kind = field['type']
                if kind == 'number':
                    count, _ = codec.width(field)
                    values[field['key']] = codec.grid(field, rng.randint(0, count))
                elif kind == 'bool':
                    values[field['key']] = not field['default']
                elif kind in ('color', 'rgba'):
                    size = 6 if kind == 'color' else 8
                    values[field['key']] = f'#{rng.randrange(16 ** size):0{size}X}'
                elif kind == 'select':
                    values[field['key']] = rng.choice(field['options'])
                else:
                    values[field['key']] = 'Text 😀 ' * 10
            self.assertGreater(len(self.roundtrip(values)), 50)
            for dense in (False, True):
                raw = codec.pack(values, dense)
                for compressed in (False, True):
                    payload = zlib.compress(raw, wbits=-15) if compressed else raw
                    code = codec.envelope(int(dense) | (2 if compressed else 0), payload)
                    self.assertEqual(codec.decode(code), values)

    def test_invalid_input_checksum_versions_and_trailing_data(self):
        for code in (None, 3, '', 'P2abc', 'P1@', 'P1abc=', 'P1A', 'P1' + 'A' * 4096,
                     'P1AP4T3A', codec.envelope(4, b'\xfe'), codec.envelope(0, b'\xfe\x00'),
                     codec.envelope(0, b''), codec.envelope(0, b'\xff')):
            with self.subTest(code=str(code)[:30]), self.assertRaises(ValueError):
                codec.decode(code)
        self.assertEqual(codec.decode('  P1AP4T3g\n'), codec.DEFAULTS)

    def test_invalid_fields_and_values_are_rejected(self):
        for changes in ({'zoom': float('nan')}, {'zoom': True}, {'zoom': 6}, {'text': '\x00'},
                        {'text': 'x' * 121}, {'textFont': 'x' * 101}, {'textFont': 'a\nb'},
                        {'outlineColor': '#NOTHEX'}, {'heatmapSource': 'bad'}, {'unknown': 1}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                codec.encode(changes)
        # Craft codes that bypass the encoder's validation.
        for bad in (float('nan'), float('inf'), 6):
            bits = codec.Bits()
            bits.write(6, 7)  # zoom
            bits.write(1, 1)
            for byte in struct.pack('>d', bad):
                bits.write(byte, 8)
            bits.write(127, 7)
            with self.assertRaises(ValueError):
                codec.decode(codec.envelope(0, bytes(bits.data)))
        bits = codec.Bits()
        bits.write(0, 7)
        codec.put_value(bits, codec.FIELDS[0], 1)
        bits.write(0, 7)
        codec.put_value(bits, codec.FIELDS[0], 2)
        bits.write(127, 7)
        with self.assertRaisesRegex(ValueError, 'order'):
            codec.decode(codec.envelope(0, bytes(bits.data)))

    def test_decompression_is_bounded_and_complete(self):
        for payload in (zlib.compress(b'\x00' * 10000, wbits=-15),
                        zlib.compress(b'\xfe', wbits=-15) + b'extra',
                        zlib.compress(b'\xfe', wbits=-15)[:-1], b'garbage'):
            with self.assertRaises(ValueError):
                codec.decode(codec.envelope(2, payload))


class PresetApiTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.store = config.Store(directory.name)
        self.http = server.ThreadingHTTPServer(('127.0.0.1', 0), server.make_handler(SimpleNamespace(store=self.store)))
        thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.http.server_close)
        self.addCleanup(thread.join)
        self.addCleanup(self.http.shutdown)

    def request(self, action, body):
        conn = http.client.HTTPConnection('127.0.0.1', self.http.server_port)
        conn.request('POST', '/presets/' + action, json.dumps(body), {'X-Prism': '1', 'Content-Type': 'application/json'})
        response = conn.getresponse()
        result = response.status, json.loads(response.read())
        conn.close()
        return result

    def test_export_decode_import_persistence_and_duplicates(self):
        self.store.save_preset('Original', {'zoom': 1.2345, 'text': 'Olá 😀'})
        status, result = self.request('export', {'name': 'Original'})
        self.assertEqual(status, 200)
        code = result['code']
        original = self.store.get_presets()
        status, result = self.request('decode', {'code': code})
        self.assertEqual(status, 200)
        self.assertEqual(result['settings'], original['Original'])
        self.assertEqual(self.store.get_presets(), original)
        status, result = self.request('import', {'code': code, 'name': '  My preset  '})
        self.assertEqual(status, 200)
        self.assertEqual(result['name'], 'My preset')
        self.assertEqual(config.Store(self.store.directory).get_presets()['My preset'], original['Original'])
        before = copy.deepcopy(self.store.get_presets())
        self.assertEqual(self.request('import', {'code': codec.encode({'zoom': 3}), 'name': 'My preset'})[0], 409)
        self.assertEqual(self.store.get_presets(), before)

    def test_bad_requests_never_write(self):
        for action, body, status in [('export', {'name': 'missing'}, 404), ('export', {'name': []}, 400),
                                     ('decode', {'code': 'bad'}, 400), ('import', {'code': 'bad', 'name': 'Hi'}, 400),
                                     ('import', {'code': codec.encode({}), 'name': ''}, 400),
                                     ('import', {'code': codec.encode({}), 'name': 'x' * 65}, 400),
                                     ('import', {'code': codec.encode({}), 'name': []}, 400)]:
            self.assertEqual(self.request(action, body)[0], status)
        self.assertFalse(self.store.presets_path.exists())

    def test_import_is_atomic(self):
        def save(_):
            try:
                self.store.import_preset('Same', schema.DEFAULTS)
                return True
            except FileExistsError:
                return False
        with ThreadPoolExecutor(max_workers=8) as pool:
            self.assertEqual(sum(pool.map(save, range(16))), 1)


if __name__ == '__main__':
    unittest.main()
