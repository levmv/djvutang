#!/usr/bin/env python3
"""Tiny IW44 grids and direct-reduction RGB hashes.

Requires c44 and ddjvu (fixture generation only).

Dimensions are divisible by 32 so ddjvu's page-size rounding does not choose a
different final resize. Its page renderer uses another filter beyond reduction
8; levels 16/32 and odd/tiny grids use the stopped-lifting tests instead.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile

out = Path(__file__).resolve().parents[1] / 'fixtures'
width, height = 128, 96
references = []
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    rgb = bytearray()
    for y in range(height):
        for x in range(width):
            rgb.extend((8, 19, 30) if (x in (1, 31, 32, 95, 126) or y in (1, 47, 94)) else
                       (x * 255 // (width - 1), y * 255 // (height - 1),
                        27 if (x // 13 + y // 17) % 2 else 231))
    for mode in ('full', 'half', 'gray'):
        source = root / ('source.pgm' if mode == 'gray' else 'source.ppm')
        pixels = bytes(rgb[::3]) if mode == 'gray' else bytes(rgb)
        source.write_bytes(f'P{5 if mode == "gray" else 6}\n{width} {height}\n255\n'.encode() + pixels)
        name = f'iw44-reduced-{mode}'
        encoded = out / f'{name}.djvu'
        subprocess.run(['c44', '-slice', '74+10+13', f'-crcb{mode}' if mode != 'gray' else '-crcbnone',
                        str(source), str(encoded)], check=True)
        levels = []
        for reduction in (1, 2, 4, 8):
            expected = root / 'expected.ppm'
            subprocess.run(['ddjvu', '-format=ppm', f'-subsample={reduction}', str(encoded), str(expected)], check=True)
            header, pixels = expected.read_bytes().split(b'\n255\n', 1)
            w, h = map(int, header.splitlines()[-1].split())
            assert (w, h) == (width // reduction, height // reduction)
            levels.append(dict(reduction=reduction, width=w, height=h, rgb_sha256=hashlib.sha256(pixels).hexdigest()))
        references.append(dict(name=name, levels=levels))
(out / 'iw44-reduced.json').write_text(json.dumps(references, indent=2) + '\n')
