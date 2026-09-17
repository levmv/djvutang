#!/usr/bin/env python3
"""Generate synthetic cover benchmarks under tests/out/bench, using DjVuLibre.

Keep generated inputs and results disposable. No downloaded documents or fonts.
"""
from pathlib import Path
import random
import subprocess
import tempfile

out = Path(__file__).resolve().parents[1] / 'out' / 'bench'
out.mkdir(parents=True, exist_ok=True)
width, height = 2400, 3200

with tempfile.TemporaryDirectory(prefix='djvutang-bench-') as temporary:
    root = Path(temporary)
    # Repeated synthetic glyphs and diagonal strokes; packed PBM rows.
    mask = bytearray(width * height // 8)
    for y in range(height):
        for x in range(width):
            gx, gy = x % 40, y % 48
            if 80 <= x < width - 80 and 80 <= y < height - 80 and (
                (5 <= gx < 9 and 8 <= gy < 36) or
                (8 <= gx < 26 and (8 <= gy < 12 or 20 <= gy < 24)) or
                (gx == gy // 2 + 12 and 8 <= gy < 36)
            ):
                i = y * width + x
                mask[i // 8] |= 128 >> (i % 8)
    source = root / 'text.pbm'
    source.write_bytes(f'P4\n{width} {height}\n'.encode() + mask)
    subprocess.run(['cjb2', str(source), str(out / 'text.djvu')], check=True)

    # Smooth color fields with sharp edges, at full page resolution.
    rgb = bytearray(width * height * 3)
    for y in range(height):
        for x in range(width):
            i = (y * width + x) * 3
            rgb[i:i+3] = bytes((x * 255 // width, y * 255 // height,
                                64 if (x // 200 + y // 240) % 2 else 224))
    source = root / 'color.ppm'
    source.write_bytes(f'P6\n{width} {height}\n255\n'.encode() + rgb)
    subprocess.run(['c44', '-slice', '74+10+13', str(source), str(out / 'color.djvu')], check=True)

    # Compose the same JB2 mask with an IW44 background reduced by three.
    source.write_bytes(f'P6\n{width // 3} {height // 3 + 1}\n255\n'.encode() +
                      b''.join(rgb[(y * width + x) * 3:(y * width + x) * 3 + 3]
                               for y in range(0, height, 3) for x in range(0, width, 3)))
    background = root / 'background.djvu'
    subprocess.run(['c44', '-slice', '74+10+13', str(source), str(background)], check=True)

    def chunks(path):
        data = path.read_bytes()
        pos = 16
        while pos < len(data):
            length = int.from_bytes(data[pos + 4:pos + 8], 'big')
            end = pos + 8 + length
            yield data[pos:pos + 4], data[pos:end] + (b'\0' if length & 1 else b'')
            pos = end + (length & 1)

    body = b'DJVU' + b''.join(chunk for tag, chunk in chunks(out / 'text.djvu'))
    body += b''.join(chunk for tag, chunk in chunks(background) if tag == b'BG44')
    (out / 'compound.djvu').write_bytes(b'AT&TFORM' + len(body).to_bytes(4, 'big') + body)

    # Scanned text sometimes has a full IW44 background that is actually flat.
    # Keep this separate from the varying background and pure bilevel controls.
    source.write_bytes(f'P6\n{width // 3} {height // 3 + 1}\n255\n'.encode() +
                       bytes((254, 254, 254)) * (width // 3) * (height // 3 + 1))
    subprocess.run(['c44', '-slice', '74+10+13', str(source), str(background)], check=True)
    body = b'DJVU' + b''.join(chunk for tag, chunk in chunks(out / 'text.djvu'))
    body += b''.join(chunk for tag, chunk in chunks(background) if tag == b'BG44')
    (out / 'uniform.djvu').write_bytes(b'AT&TFORM' + len(body).to_bytes(4, 'big') + body)

    # A dense coefficient control case guards against measuring only easy input.
    source.write_bytes(b'P6\n513 385\n255\n' + random.Random(17).randbytes(513 * 385 * 3))
    subprocess.run(['c44', '-slice', '160', '-crcbfull', str(source), str(out / 'noise.djvu')], check=True)

for name, w, h in [('text', width, height), ('color', width, height),
                   ('compound', width, height), ('uniform', width, height),
                   ('noise', 513, 385)]:
    path = out / f'{name}.djvu'
    print(f'{path}: {path.stat().st_size} bytes, {w}x{h}')
