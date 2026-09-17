#!/usr/bin/env python3
"""Synthetic Smmr fixtures: Pillow/libtiff Group 4 and one T.6 literal stream.

Only regeneration needs Pillow with libtiff. Normal tests read the saved files.
Each bilevel source is saved as PBM so the independent expected pixels survive.
"""
from io import BytesIO
from pathlib import Path
import struct
import subprocess

from PIL import Image

OUT = Path(__file__).resolve().parents[1] / 'fixtures'


def chunk(tag, payload):
    return tag + struct.pack('>I', len(payload)) + payload + bytes(len(payload) % 2)


def document(parts):
    body = b'DJVU' + b''.join(chunk(tag, data) for tag, data in parts)
    return b'AT&TFORM' + struct.pack('>I', len(body)) + body


def group4(image, invert):
    output = BytesIO()
    image.save(output, format='TIFF', compression='group4', tiffinfo={262: int(invert)})
    encoded = output.getvalue()
    tags = Image.open(BytesIO(encoded)).tag_v2
    assert tags[259] == 4 and tags[262] == int(invert) and len(tags[273]) == 1
    start, size = tags[273][0], tags[279][0]
    return encoded[start:start + size]


def mask(image, invert=False, stripe_rows=0):
    width, height = image.size
    result = b'MMR' + bytes([int(invert) | (2 if stripe_rows else 0)]) + struct.pack('>HH', width, height)
    if not stripe_rows:
        return result + group4(image, invert)
    result += struct.pack('>H', stripe_rows)
    for top in range(0, height, stripe_rows):
        encoded = group4(image.crop((0, top, width, min(height, top + stripe_rows))), invert)
        result += struct.pack('>I', len(encoded)) + encoded
    return result


def info(width, height):
    return struct.pack('>HH', width, height) + bytes([24, 0, 44, 1, 22, 1])


def save(name, width, height, pixel, invert=False, stripe_rows=0):
    image = Image.new('1', (width, height))
    image.putdata([0 if pixel(x, y) else 255 for y in range(height) for x in range(width)])
    image.save(OUT / f'{name}.pbm')
    (OUT / f'{name}.djvu').write_bytes(document([(b'INFO', info(width, height)), (b'Smmr', mask(image, invert, stripe_rows))]))


def pattern(x, y):
    if y == 0:
        return False
    if y == 1:
        return True
    if y < 11:
        shift = (y % 7) - 3
        return 8 + shift <= x < 23 + shift or x == 0 or x == 36
    return ((x * 17 + y * 31) ^ (x * y * 3)) % 23 < 9


for name, invert, stripes in [('mmr', False, 0), ('mmr-inverted', True, 0),
                              ('mmr-striped', False, 5), ('mmr-striped-inverted', True, 1)]:
    save(name, 37, 29, pattern, invert, stripes)
save('mmr-tiny', 1, 7, lambda x, y: y in [0, 2, 3, 6])
save('mmr-long', 9001, 3, lambda x, y: (x >= 4096 if y == 0 else x < 8192 if y == 1 else x % 127 == 0))

# Same glyph mask and IW44 layers as the JB2 foreground fixture.
image = Image.new('1', (65, 49))
image.putdata([0 if ((x % 16 in (3, 4) and 3 <= y % 15 <= 11) or
                    (y % 15 in (3, 4, 7, 10, 11) and 3 <= x % 16 <= 10)) else 255
               for y in range(49) for x in range(65)])
glyph_mask = mask(image)
data = (OUT / 'foreground.djvu').read_bytes()
parts, pos = [], 16
while pos < len(data):
    tag, size = data[pos:pos + 4], int.from_bytes(data[pos + 4:pos + 8], 'big')
    parts.append((b'Smmr', mask(image, stripe_rows=8)) if tag == b'Sjbz' else (tag, data[pos + 8:pos + 8 + size]))
    pos += 8 + size + size % 2
(OUT / 'mmr-foreground.djvu').write_bytes(document(parts))

# Optional uncompressed T.6 codes can cross row boundaries. No encoder code
# from the implementation is used here; 1 is black, 000001 emits five whites.
pixels = '1010000' '0101000' '0010110'
bits, zeros = '0000001111', 0
for pixel in pixels:
    if pixel == '0':
        zeros += 1
        if zeros == 5:
            bits += '000001'
            zeros = 0
    else:
        bits += '0' * zeros + '1'
        zeros = 0
bits += '0' * (zeros + 6) + '10'  # Exit with residual whites and a white next run.
bits += '000000000001' * 2
bits += '0' * (-len(bits) % 8)
encoded = bytes(int(bits[i:i + 8], 2) for i in range(0, len(bits), 8))
image = Image.new('1', (7, 3))
image.putdata([0 if c == '1' else 255 for c in pixels])
image.save(OUT / 'mmr-uncompressed.pbm')
(OUT / 'mmr-uncompressed-reference.djvu').write_bytes(document([
    (b'INFO', info(7, 3)), (b'Smmr', mask(image))]))
(OUT / 'mmr-uncompressed.djvu').write_bytes(document([
    (b'INFO', info(7, 3)), (b'Smmr', b'MMR\0' + struct.pack('>HH', 7, 3) + encoded)]))

# FGbz correspondence addresses JB2 blits, not MMR runs, stripes or connected
# components. Its validated but unused colors must leave the MMR mask black.
colors = [(176, 24, 47), (0, 91, 188), (33, 119, 19)]
indices = subprocess.run(['bzz', '-e'], input=b'\0\x02\0\x01\0\x00',
                         capture_output=True, check=True, timeout=30).stdout
fgbz = b'\x80\x00\x03' + b''.join(bytes(rgb[::-1]) for rgb in colors) + b'\0\0\x03' + indices
for name, source in [('mmr-palette', 'mmr'), ('mmr-palette-bg', 'palette-unmapped-bg')]:
    data = (OUT / f'{source}.djvu').read_bytes()
    parts, pos = [], 16
    while pos < len(data):
        tag, size = data[pos:pos + 4], int.from_bytes(data[pos + 4:pos + 8], 'big')
        payload = data[pos + 8:pos + 8 + size]
        if tag == b'Sjbz':
            tag, payload = b'Smmr', glyph_mask
        if tag != b'FGbz':
            parts.append((tag, payload))
        pos += 8 + size + size % 2
    (OUT / f'{name}.djvu').write_bytes(document([*parts, (b'FGbz', fgbz)]))
