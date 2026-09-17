#!/usr/bin/env python3
"""Regenerate our synthetic IW44/FGbz fixtures using external DjVuLibre tools.

No downloaded images or books. Native/WASM tests use the saved tiny files and do
not run this script. The independent Python compositor defines the initial color
sampling policy; it is intentionally separate from DjVuLibre's display scaler.
"""
from pathlib import Path
import random
import subprocess
import tempfile

out = Path(__file__).resolve().parents[1] / 'fixtures'
out.mkdir(exist_ok=True)


def run(*args):
    subprocess.run([str(a) for a in args], check=True, timeout=30, capture_output=True)


def pnm(path, width, height, pixels, gray=False):
    path.write_bytes(f'P{5 if gray else 6}\n# synthetic IW44 fixture\n{width} {height}\n255\n'.encode() + bytes(pixels))


def ppm(path):
    content = path.read_bytes()
    header, raw = content.split(b'\n255\n', 1)
    width, height = map(int, header.splitlines()[-1].split())
    assert len(raw) == width * height * 3
    return width, height, raw


def chunks(path):
    data = path.read_bytes()
    assert data[:8] == b'AT&TFORM' and data[12:16] == b'DJVU'
    result = []
    pos = 16
    while pos < len(data):
        size = int.from_bytes(data[pos + 4:pos + 8], 'big')
        result.append((data[pos:pos + 4], data[pos + 8:pos + 8 + size]))
        pos += 8 + size + size % 2
    return result


def djvu(path, parts, form=b'DJVU', magic=True):
    body = bytearray(form)
    for tag, payload in parts:
        body += tag + len(payload).to_bytes(4, 'big') + payload
        if len(payload) % 2:
            body.append(0)
    path.write_bytes((b'AT&T' if magic else b'') + b'FORM' + len(body).to_bytes(4, 'big') + body)


def oracle(name, width, height, suffix='expected'):
    path = out / f'{name}-{suffix}.ppm'
    run('ddjvu', '-format=ppm', f'-size={width}x{height}', '-aspect=no', out / f'{name}.djvu', path)
    return path


def pattern(width, height, gray):
    result = bytearray()
    for y in range(height):
        for x in range(width):
            if gray:
                result.append((x * 7 + y * 11 + (90 if x > width // 2 and y > height // 2 else 0)) % 256)
            else:
                result.extend(((x * 3 + y * 2) % 256, (x * 5 + 17 * y) % 256, (211 + x * 7 - y * 3) % 256))
    return result


for name, width, height, gray, options in [
    ('gray', 37, 29, True, ['-slice', '97']),
    ('color', 65, 49, False, ['-slice', '97', '-crcbfull']),
    ('progressive', 65, 49, False, ['-slice', '74+10+13', '-crcbfull']),
    ('chroma-half', 65, 49, False, ['-slice', '97', '-crcbhalf']),
    ('tiny', 1, 1, True, ['-slice', '97']),
    ('narrow', 3, 7, False, ['-slice', '97', '-crcbfull']),
    ('foreground-layer', 6, 5, False, ['-slice', '97', '-crcbfull']),
]:
    source = out / (name + ('.pgm' if gray else '.ppm'))
    pnm(source, width, height, pattern(width, height, gray), gray)
    run('c44', *options, source, out / f'{name}.djvu')
    oracle(name, width, height)

# One page with colored synthetic glyphs. R6 is DjVuLibre's documented separated
# input format; each run has a 12-bit color index and a 20-bit length.
width, height = 65, 49
palette = [(176, 24, 47), (0, 91, 188), (33, 119, 19)]
mask = []
encoded = bytearray(f'R6\n{width} {height} {len(palette)}\n'.encode())
for rgb in palette:
    encoded.extend(rgb)
for y in range(height):
    row = []
    for x in range(width):
        lx, ly = x % 16, y % 15
        ink = (lx in (3, 4) and 3 <= ly <= 11) or (ly in (3, 4, 7, 10, 11) and 3 <= lx <= 10)
        row.append((x // 16 + y // 15) % 3 if ink else 0xfff)
    mask.extend(row)
    start = 0
    for i in range(1, width + 1):
        if i == width or row[i] != row[start]:
            encoded.extend(((row[start] << 20) | (i - start)).to_bytes(4, 'big'))
            start = i

for name, background in [('palette', False), ('compound', True)]:
    content = bytearray(encoded)
    if background:
        bw, bh = (width + 2) // 3, (height + 2) // 3
        content.extend(f'P6\n{bw} {bh}\n255\n'.encode())
        for y in range(bh):
            for x in range(bw):
                content.extend((170 + (x * 3) % 60, 180 + (y * 3) % 60, 210 + (x + y) % 40))
    source = out / f'{name}.sep'
    source.write_bytes(content)
    run('csepdjvu', '-q', '74+10+13', source, out / f'{name}.djvu')

compound = chunks(out / 'compound.djvu')
info = next(payload for tag, payload in compound if tag == b'INFO')
stencil = next(payload for tag, payload in compound if tag == b'Sjbz')
bg = [(tag, payload) for tag, payload in compound if tag == b'BG44']
fg = next(payload for tag, payload in chunks(out / 'foreground-layer.djvu') if tag == b'BG44')
# Optional chunks may surround the mask; only progressive BG44 order is fixed.
djvu(out / 'foreground.djvu', [(b'INFO', info), (b'FG44', fg), bg[0], (b'Sjbz', stencil), *bg[1:]])

# Obtain an independent native-resolution background, without display scaling.
bg_info = bytearray(info)
bg_info[0:4] = (22).to_bytes(2, 'big') + (17).to_bytes(2, 'big')
djvu(out / 'background-layer.djvu', [(b'INFO', bytes(bg_info)), *bg])
oracle('background-layer', 22, 17)


def sample(image, reduction, x, y):
    """Bilinear pixel centres on an integer grid anchored at the bottom left."""
    w, h, raw = image
    den = 2 * reduction
    nx, ny = 2 * x + 1 - reduction, 2 * (height - 1 - y) + 1 - reduction
    ix, fx = divmod(nx, den)
    iy, fy = divmod(ny, den)
    rgb = [0, 0, 0]
    for dx, dy, weight in [(0, 0, (den - fx) * (den - fy)), (1, 0, fx * (den - fy)),
                           (0, 1, (den - fx) * fy), (1, 1, fx * fy)]:
        px, py = min(w - 1, max(0, ix + dx)), min(h - 1, max(0, iy + dy))
        index = ((h - 1 - py) * w + px) * 3
        for c in range(3):
            rgb[c] += raw[index + c] * weight
    return bytes((value + den * den // 2) // (den * den) for value in rgb)


background = ppm(out / 'background-layer-expected.ppm')
foreground = ppm(out / 'foreground-layer-expected.ppm')
fg_reduction = next(r for r in range(1, 13)
                    if (width + r - 1) // r == foreground[0] and (height + r - 1) // r == foreground[1])
for name in ['palette', 'compound', 'foreground']:
    raw = bytearray()
    for y in range(height):
        for x in range(width):
            index = mask[y * width + x]
            if index != 0xfff:
                raw.extend(sample(foreground, fg_reduction, x, y) if name == 'foreground' else palette[index])
            else:
                raw.extend((255, 255, 255) if name == 'palette' else sample(background, 3, x, y))
    pnm(out / f'{name}-reference.ppm', width, height, raw)
    oracle(name, width, height)

for name, gamma, rotation in [('gamma', 10, 1), ('rotated-color', 22, 6)]:
    parts = chunks(out / 'color.djvu')
    info = bytearray(parts[0][1])
    info[8], info[9] = gamma, rotation
    djvu(out / f'{name}.djvu', [(b'INFO', bytes(info)), *parts[1:]])
    oracle(name, 49 if rotation == 6 else 65, 65 if rotation == 6 else 49)

# Real-file findings reproduced with our own pixels: legal reduced backgrounds,
# empty arithmetic segments, and signed 16-bit inverse-filter stores.
djvu(out / 'reduced-background.djvu', [(b'INFO', next(data for tag, data in compound if tag == b'INFO')), *bg])
pnm(out / 'reduced-background-reference.ppm', width, height,
    b''.join(sample(background, 3, x, y) for y in range(height) for x in range(width)))
for name, w, h, pixels in [
    ('iw44-empty-parts', 7, 9, bytes([255]) * 63),
    ('iw44-filter-range', 33, 35, None),
]:
    # Use repeated choice, whose sequence is fixed independently of c44.
    if name == 'iw44-filter-range':
        rng = random.Random(0)
        pixels = bytes(rng.choice([0, 255]) for _ in range(w*h))
    source = out / f'{name}.pgm'
    pnm(source, w, h, pixels, True)
    run('c44', '-slice', '74+10+13+6', source, out / f'{name}.djvu')
    oracle(name, w, h)

djvu(out / 'blank-page.djvu', [(b'INFO', bytes.fromhex('0011000d18002c011601'))])
pnm(out / 'blank-page-reference.ppm', 17, 13, bytes([255]) * (17*13*3))

# A palette without correspondence assigns no colors to the JB2 blits. Even a
# single blue entry must not paint every symbol blue. Reuse our original mask.
unmapped = b'\x00\x00\x03' + b''.join(bytes(rgb[::-1]) for rgb in palette)
for name, source, payload in [
    ('palette-unmapped', 'palette', b'\x00\x00\x01' + bytes(palette[1][::-1])),
    ('palette-unmapped-bg', 'compound', unmapped),
]:
    djvu(out / f'{name}.djvu', [(tag, payload if tag == b'FGbz' else data)
                               for tag, data in chunks(out / f'{source}.djvu')])
packed = bytearray(((width + 7) // 8) * height)
for y in range(height):
    for x in range(width):
        if mask[y * width + x] != 0xfff:
            packed[y * ((width + 7) // 8) + x // 8] |= 1 << (7 - x % 8)
(out / 'palette-mask.pbm').write_bytes(f'P4\n{width} {height}\n'.encode() + packed)
pnm(out / 'palette-unmapped-bg-reference.ppm', width, height,
    b''.join(b'\0\0\0' if mask[y * width + x] != 0xfff else sample(background, 3, x, y)
             for y in range(height) for x in range(width)))

# A present empty table is valid for an empty JB2 image. bzz emits no bytes for
# that table; it is distinct from a missing table on a nonempty mask.
with tempfile.TemporaryDirectory() as temp:
    empty = Path(temp) / 'empty.pbm'
    empty.write_bytes(b'P4\n17 13\n' + bytes(3 * 13))
    run('cjb2', empty, out / 'palette-empty.djvu')
    djvu(out / 'palette-empty.djvu', [*chunks(out / 'palette-empty.djvu'),
         (b'FGbz', b'\x80' + unmapped[1:] + b'\0\0\0')])

# Standalone IW44 uses the same progressive payloads, without INFO. Keep the
# color fixtures prefixed and the grayscale fixtures bare, as djvuextract does.
# Pixel references remain those of the original synthetic c44 images.
for name, source, kind, magic in [
    ('pm44', 'color', b'PM44', True),
    ('pm44-progressive', 'progressive', b'PM44', True),
    ('bm44', 'gray', b'BM44', False),
    ('bm44-progressive', 'iw44-empty-parts', b'BM44', False),
]:
    parts = [(kind, data) for tag, data in chunks(out / f'{source}.djvu') if tag == b'BG44']
    djvu(out / f'{name}.iw4', parts, form=kind, magic=magic)

print('Regenerated synthetic wavelet, palette, compound, gamma and rotation fixtures')
