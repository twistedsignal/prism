"""Self-contained, lossless P1 preset codes. No storage or network lookup.

After the P1 prefix, unpadded base64url holds a mode byte, payload, and a
big-endian CRC-16/CCITT (initial value 0xffff) over mode + payload. Mode bit 0
selects the dense presence bitmap; bit 1 selects raw DEFLATE. Other bits are
reserved. Sparse fields use ascending 7-bit IDs, terminated by 127. Values
and the dense bitmap are MSB-first, with zero padding only in the last byte.
"""
import base64
import binascii
from decimal import Decimal
import math
import re
import struct
import zlib

from preset_format_v1 import FIELDS

LIMIT = 4096
DEFAULTS = {field['key']: field['default'] for field in FIELDS}


class Bits:
    def __init__(self, data=None):
        self.data = bytearray() if data is None else bytearray(data)
        self.position = 0

    def write(self, value, width):
        for shift in range(width - 1, -1, -1):
            if self.position % 8 == 0:
                self.data.append(0)
            self.data[-1] |= ((value >> shift) & 1) << (7 - self.position % 8)
            self.position += 1

    def read(self, width):
        if self.position + width > len(self.data) * 8:
            raise ValueError('Preset code is truncated')
        value = 0
        for _ in range(width):
            value = (value << 1) | ((self.data[self.position // 8] >> (7 - self.position % 8)) & 1)
            self.position += 1
        return value

    def finish(self):
        remaining = len(self.data) * 8 - self.position
        if remaining > 7 or self.read(remaining):
            raise ValueError('Preset code has trailing data')


def grid(field, index):
    return float(Decimal(str(field['min'])) + index * Decimal(str(field['step'])))


def width(field):
    count = int((Decimal(str(field['max'])) - Decimal(str(field['min']))) / Decimal(str(field['step'])))
    return count, count.bit_length()


def validate(field, value):
    kind = field['type']
    valid = False
    if kind == 'number':
        valid = not isinstance(value, bool) and isinstance(value, (float, int)) and math.isfinite(value) and field['min'] <= value <= field['max']
    elif kind == 'bool':
        valid = isinstance(value, bool)
    elif kind in ('color', 'rgba'):
        valid = isinstance(value, str) and re.fullmatch(r'#[0-9A-F]{' + ('6' if kind == 'color' else '8') + '}', value)
    elif kind == 'select':
        valid = value in field['options']
    elif kind == 'text':
        valid = isinstance(value, str) and len(value) <= field['maxLength'] and not re.search(r'[\x00-\x08\x0b-\x1f\x7f]', value)
        if field['key'] == 'textFont' and isinstance(value, str):
            valid = valid and not re.search(r'[\x00-\x1f\x7f]', value)
    if not valid:
        raise ValueError('Invalid preset value for ' + field['key'])


def put_value(bits, field, value):
    kind = field['type']
    if kind == 'number':
        count, size = width(field)
        index = round((value - field['min']) / field['step'])
        compact = 0 <= index <= count and grid(field, index) == value
        bits.write(0 if compact else 1, 1)
        if compact:
            bits.write(index, size)
        else:
            for byte in struct.pack('>d', value):
                bits.write(byte, 8)
    elif kind in ('color', 'rgba'):
        bits.write(int(value[1:], 16), 24 if kind == 'color' else 32)
    elif kind == 'select':
        bits.write(field['options'].index(value), (len(field['options']) - 1).bit_length())
    elif kind == 'text':
        raw = value.encode('utf-8')
        length = len(raw)
        while length >= 128:
            bits.write((length & 127) | 128, 8)
            length >>= 7
        bits.write(length, 8)
        for byte in raw:
            bits.write(byte, 8)


def get_value(bits, field):
    kind = field['type']
    if kind == 'bool':
        return not field['default']
    if kind == 'number':
        if bits.read(1):
            return struct.unpack('>d', bytes(bits.read(8) for _ in range(8)))[0]
        count, size = width(field)
        index = bits.read(size)
        if index > count:
            raise ValueError('Invalid numeric index')
        return grid(field, index)
    if kind in ('color', 'rgba'):
        size = 6 if kind == 'color' else 8
        return f'#{bits.read(size * 4):0{size}X}'
    if kind == 'select':
        index = bits.read((len(field['options']) - 1).bit_length())
        if index >= len(field['options']):
            raise ValueError('Invalid selection index')
        return field['options'][index]
    length = 0
    for shift in (0, 7):
        byte = bits.read(8)
        length |= (byte & 127) << shift
        if not byte & 128:
            break
    else:
        raise ValueError('Invalid text length')
    if length > field['maxLength'] * 4:
        raise ValueError('Preset text is too long')
    return bytes(bits.read(8) for _ in range(length)).decode('utf-8')


def pack(settings, dense):
    changed = [i for i, field in enumerate(FIELDS) if settings[field['key']] != field['default']]
    bits = Bits()
    if dense:
        for index in range(len(FIELDS)):
            bits.write(int(index in changed), 1)
    for index in changed:
        if not dense:
            bits.write(index, 7)
        field = FIELDS[index]
        put_value(bits, field, settings[field['key']])
    if not dense:
        bits.write(127, 7)
    return bytes(bits.data)


def envelope(mode, payload):
    raw = bytes([mode]) + payload
    raw += struct.pack('>H', binascii.crc_hqx(raw, 0xffff))
    return 'P1' + base64.urlsafe_b64encode(raw).decode('ascii').rstrip('=')


def encode(settings):
    values = dict(DEFAULTS)
    unknown = set(settings) - set(values)
    if unknown:
        raise ValueError('Settings are not supported by preset format P1: ' + ', '.join(sorted(unknown)))
    values.update(settings)
    for field in FIELDS:
        validate(field, values[field['key']])
    candidates = []
    for dense in (False, True):
        payload = pack(values, dense)
        compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
        compressed = compressor.compress(payload) + compressor.flush()
        candidates.extend((envelope(int(dense), payload), envelope(int(dense) | 2, compressed)))
    return min(candidates, key=lambda code: (len(code), code))


def decode(code):
    if not isinstance(code, str) or len(code) > LIMIT:
        raise ValueError('Preset code is too long or invalid')
    code = code.strip()
    if not code.startswith('P1'):
        raise ValueError('Unsupported preset code version')
    token = code[2:]
    if not token or not re.fullmatch(r'[A-Za-z0-9_-]+', token):
        raise ValueError('Invalid preset code characters')
    try:
        raw = base64.b64decode(token + '=' * (-len(token) % 4), altchars=b'-_', validate=True)
        if base64.urlsafe_b64encode(raw).decode().rstrip('=') != token:
            raise ValueError('Invalid preset code encoding')
        if len(raw) < 4 or binascii.crc_hqx(raw[:-2], 0xffff) != int.from_bytes(raw[-2:], 'big'):
            raise ValueError('Preset code checksum failed')
        mode, payload = raw[0], raw[1:-2]
        if mode > 3:
            raise ValueError('Unsupported preset encoding')
        if mode & 2:
            decompressor = zlib.decompressobj(-15)
            payload = decompressor.decompress(payload, LIMIT + 1)
            if len(payload) > LIMIT or not decompressor.eof or decompressor.unused_data or decompressor.unconsumed_tail:
                raise ValueError('Invalid or oversized compressed preset')
        bits = Bits(payload)
        values = dict(DEFAULTS)
        if mode & 1:
            indices = [i for i in range(len(FIELDS)) if bits.read(1)]
        else:
            indices = None
        previous = -1
        for position in range(len(FIELDS) + 1):
            index = indices[position] if indices is not None and position < len(indices) else (127 if indices is not None else bits.read(7))
            if index == 127:
                break
            if index <= previous or index >= len(FIELDS):
                raise ValueError('Invalid preset field order')
            previous = index
            field = FIELDS[index]
            value = get_value(bits, field)
            validate(field, value)
            values[field['key']] = value
        bits.finish()
        return values
    except (binascii.Error, UnicodeError, zlib.error, struct.error) as error:
        raise ValueError('Invalid preset code') from error
