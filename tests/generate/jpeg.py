#!/usr/bin/env python3
"""Synthetic JPEG layers. Requires Pillow and a C compiler for regeneration only.

Pass --stb-header pointing to the unmodified pinned header (vendor/stb/README.md),
and optionally --cc 'zig cc'. Saved references use whole-image upstream stb;
separate Pillow/libjpeg references check the codec independently. The standalone
reference receives only the right-edge resampling correction, not our adapter.
"""
import argparse
import hashlib
from pathlib import Path
import shlex
import struct
import subprocess
import tempfile
from PIL import Image

root = Path(__file__).resolve().parent
out = root.parent / 'fixtures'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--stb-header', type=Path, required=True)
parser.add_argument('--cc', default='cc')
args = parser.parse_args()
assert hashlib.sha256(args.stb_header.read_bytes()).hexdigest() == '594c2fe35d49488b4382dbfaec8f98366defca819d916ac95becf3e75f4200b3'


def chunks(name):
    data, pos, result = (out / f'{name}.djvu').read_bytes(), 16, []
    while pos < len(data):
        tag, size = data[pos:pos + 4], int.from_bytes(data[pos + 4:pos + 8], 'big')
        result.append((tag, data[pos + 8:pos + 8 + size]))
        pos += 8 + size + size % 2
    return result


def djvu(name, parts):
    body = b'DJVU' + b''.join(tag + struct.pack('>I', len(data)) + data + bytes(len(data) % 2) for tag, data in parts)
    (out / f'{name}.djvu').write_bytes(b'AT&TFORM' + struct.pack('>I', len(body)) + body)


def info(w, h, gamma=22, rotation=1):
    return struct.pack('>HH', w, h) + bytes([24, 0, 44, 1, gamma, rotation])


def ppm(path):
    header, raw = path.read_bytes().split(b'\n255\n', 1)
    w, h = map(int, header.splitlines()[-1].split())
    return w, h, raw


def save_ppm(name, w, h, raw):
    (out / f'{name}.ppm').write_bytes(f'P6\n{w} {h}\n255\n'.encode() + bytes(raw))


def sample(image, reduction, x, y, page_height):
    w, h, raw = image
    den = 2 * reduction
    ix, fx = divmod(2 * x + 1 - reduction, den)
    iy, fy = divmod(2 * (page_height - 1 - y) + 1 - reduction, den)
    rgb = [0, 0, 0]
    for dx, dy, weight in [(0, 0, (den-fx)*(den-fy)), (1, 0, fx*(den-fy)), (0, 1, (den-fx)*fy), (1, 1, fx*fy)]:
        px, py = min(w-1, max(0, ix+dx)), min(h-1, max(0, iy+dy))
        for c in range(3):
            rgb[c] += raw[((h-1-py)*w+px)*3+c] * weight
    return bytes((v + den*den//2) // (den*den) for v in rgb)


with tempfile.TemporaryDirectory(prefix='djvu-jpeg-fixtures-') as temp:
    decoder = Path(temp) / 'reference'
    header = args.stb_header.read_text()
    old = 'out[i*2+0] = stbi__div4(input[w-2]*3 + input[w-1] + 2);'
    assert header.count(old) == 1
    (Path(temp) / 'stb_image.h').write_text(header.replace(old, 'out[i*2+0] = stbi__div4(input[w-1]*3 + input[w-2] + 2);'))
    subprocess.run([*shlex.split(args.cc), '-O2', '-fwrapv', '-I', temp, str(root / 'jpeg-reference.c'), '-o', str(decoder)], check=True)
    for name, mode, w, h, options in [
        ('baseline', 'RGB', 37, 29, {'subsampling': 2}),
        ('progressive', 'RGB', 37, 29, {'progressive': True, 'subsampling': 2}),
        ('444', 'RGB', 37, 29, {'subsampling': 0}),
        ('422', 'RGB', 37, 29, {'subsampling': 1}),
        ('rgb', 'RGB', 37, 29, {'keep_rgb': True}),
        ('gray', 'L', 37, 29, {}),
        ('cmyk', 'CMYK', 37, 29, {}),
        ('ycck', 'CMYK', 37, 29, {}),
        ('restart', 'RGB', 37, 29, {'restart_marker_blocks': 2}),
        ('progressive-restart', 'RGB', 37, 29, {'progressive': True, 'restart_marker_blocks': 2}),
        ('tiny', 'RGB', 1, 1, {}),
        ('narrow', 'RGB', 1, 17, {}),
        ('background-layer', 'RGB', 22, 17, {}),
        ('foreground-layer', 'RGB', 6, 5, {'progressive': True}),
    ]:
        name = 'jpeg-' + name
        image = Image.new('RGB', (w, h))
        image.putdata([((x*7 + y*3) % 256, (y*11 + x*5) % 256, ((x ^ y)*13) % 256) for y in range(h) for x in range(w)])
        path = out / f'{name}.jpg'
        image.convert(mode).save(path, quality=85, **options)
        encoded = path.read_bytes()
        if name == 'jpeg-ycck':
            encoded = bytearray(encoded)
            encoded[encoded.index(b'Adobe') + 11] = 2
            path.write_bytes(encoded)
        if 'restart' in name:
            assert b'\xff\xdd' in encoded and b'\xff\xd0' in encoded
        if name == 'jpeg-rgb':
            assert b'Adobe' in encoded and b'R\x11' in encoded
        djvu(name, [(b'INFO', info(w, h)), (b'BGjp', encoded)])
        reference = subprocess.check_output([str(decoder), str(path)])
        (out / f'{name}-reference.ppm').write_bytes(reference)
        independent = Image.open(path).convert('RGB').tobytes()
        save_ppm(name + '-libjpeg', w, h, independent)
        delta = [abs(a-b) for a, b in zip(ppm(out / f'{name}-reference.ppm')[2], independent, strict=True)]
        print(name, 'libjpeg max delta', max(delta), 'mean', round(sum(delta)/len(delta), 4))

    # Three sequential single-component scans, SOF1 and quantizer redefinition.
    # Each block has DC=8, AC=0; direct RGB becomes exactly (129, 130, 131).
    def segment(tag, data):
        return bytes([255, tag]) + struct.pack('>H', len(data)+2) + data
    encoded = b'\xff\xd8'
    encoded += segment(0xee, b'Adobe\x00\x64\x00\x00\x00\x00\x00')
    encoded += segment(0xc1, bytes([8, 0, 8, 0, 8, 3, 82, 17, 0, 71, 17, 0, 66, 17, 0]))
    encoded += segment(0xc4, bytes([0, 1, 1] + [0]*14 + [0, 4, 16, 1] + [0]*15 + [0]))
    for component, quant in [(82, 1), (71, 2), (66, 3)]:
        encoded += segment(0xdb, bytes([0] + [quant]*64))
        encoded += segment(0xda, bytes([1, component, 0, 0, 63, 0])) + b'\xa1'
    encoded += b'\xff\xd9'
    path = out / 'jpeg-sequential.jpg'
    path.write_bytes(encoded)
    djvu('jpeg-sequential', [(b'INFO', info(8, 8)), (b'BGjp', encoded)])
    reference = subprocess.check_output([str(decoder), str(path)])
    (out / 'jpeg-sequential-reference.ppm').write_bytes(reference)
    independent = Image.open(path).convert('RGB').tobytes()
    assert independent == bytes([129, 130, 131])*64
    save_ppm('jpeg-sequential-libjpeg', 8, 8, independent)

# Compatibility cases derived from our own streams. No foreign pixels or
# compressed data are needed to reproduce the header and alignment quirks.
original = (out / 'jpeg-baseline.jpg').read_bytes()
# APP14 declares eleven payload bytes; the leftover transform byte is junk.
short_app14 = b'\xff\xee\x00\x0dAdobe\x00\x64\x00\x00\x00\x00\x01'
quant = original.index(b'\xff\xdb')
header_junk = original[:quant] + b'header\xff\x00' + short_app14 + original[quant:]
scan = header_junk.index(b'\xff\xda')
header_junk = header_junk[:scan] + b'gap\xff\x00' + header_junk[scan:]
(out / 'jpeg-header-junk.jpg').write_bytes(header_junk)
djvu('jpeg-header-junk', [(b'INFO', info(37, 29)), (b'BGjp', header_junk)])
assert Image.open(out / 'jpeg-header-junk.jpg').convert('RGB').tobytes() == ppm(out / 'jpeg-baseline-libjpeg.ppm')[2]

# The manual sequential stream uses seven bits per block: DC code 10, value
# 1000, AC EOB 0. Only its final padding bit changes from one to zero.
original = (out / 'jpeg-sequential.jpg').read_bytes()
assert original.count(b'\x3f\x00\xa1') == 3
zero_padding = original.replace(b'\x3f\x00\xa1', b'\x3f\x00\xa0')
(out / 'jpeg-zero-padding.jpg').write_bytes(zero_padding)
djvu('jpeg-zero-padding', [(b'INFO', info(8, 8)), (b'BGjp', zero_padding)])
assert Image.open(out / 'jpeg-zero-padding.jpg').convert('RGB').tobytes() == ppm(out / 'jpeg-sequential-libjpeg.ppm')[2]

# Layer combinations use the same synthetic glyphs as the IW44 fixtures.
parts = dict(chunks('foreground'))
mmr = dict(chunks('mmr-foreground'))[b'Smmr']
bg44 = [(tag, payload) for tag, payload in chunks('foreground') if tag == b'BG44']
bgjp = (out / 'jpeg-background-layer.jpg').read_bytes()
fgjp = (out / 'jpeg-foreground-layer.jpg').read_bytes()
bg_jpeg = ppm(out / 'jpeg-background-layer-reference.ppm')
fg_jpeg = ppm(out / 'jpeg-foreground-layer-reference.ppm')
bg_iw = ppm(out / 'background-layer-expected.ppm')
fg_iw = ppm(out / 'foreground-layer-expected.ppm')
for name, mask, bg, fg, background, foreground in [
    ('jpeg-compound', (b'Sjbz', parts[b'Sjbz']), [(b'BGjp', bgjp)], (b'FGjp', fgjp), bg_jpeg, fg_jpeg),
    ('jpeg-mmr', (b'Smmr', mmr), [(b'BGjp', bgjp)], (b'FGjp', fgjp), bg_jpeg, fg_jpeg),
    ('jpeg-background', (b'Sjbz', parts[b'Sjbz']), [(b'BGjp', bgjp)], (b'FG44', parts[b'FG44']), bg_jpeg, fg_iw),
    ('jpeg-foreground', (b'Sjbz', parts[b'Sjbz']), bg44, (b'FGjp', fgjp), bg_iw, fg_jpeg),
]:
    djvu(name, [(b'INFO', info(65, 49)), fg, *bg, mask])
    pixels = bytearray()
    for y in range(49):
        for x in range(65):
            lx, ly = x % 16, y % 15
            ink = (lx in (3, 4) and 3 <= ly <= 11) or (ly in (3, 4, 7, 10, 11) and 3 <= lx <= 10)
            pixels.extend(sample(foreground, 11, x, y, 49) if ink else sample(background, 3, x, y, 49))
    save_ppm(name + '-reference', 65, 49, pixels)

rgb = ppm(out / 'jpeg-baseline-reference.ppm')[2]
gamma = bytes(int(255 * (v / 255) ** (1 / 2.2) + 0.5) for v in range(256))
djvu('jpeg-gamma-rotated', [(b'INFO', info(37, 29, gamma=10, rotation=6)), (b'BGjp', (out / 'jpeg-baseline.jpg').read_bytes())])
save_ppm('jpeg-gamma-rotated-reference', 29, 37, [gamma[rgb[(x*37 + 36-y)*3+c]] for y in range(37) for x in range(29) for c in range(3)])
