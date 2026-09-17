#!/usr/bin/env python3
"""Generate synthetic JB2 benchmarks under tests/out/bench, using DjVuLibre.

Geometric glyph variants exercise symbol matches and refinements. A connected
line drawing exercises a large symbol. No downloaded documents or fonts.
"""
from pathlib import Path
import subprocess
import tempfile

out = Path(__file__).resolve().parents[1] / 'out' / 'bench'
out.mkdir(parents=True, exist_ok=True)
width, height = 2400, 3200
stride = (width + 7) // 8


def set_pixel(pixels, x, y):
    pixels[y * stride + x // 8] |= 128 >> (x % 8)


with tempfile.TemporaryDirectory(prefix='djvutang-jb2-bench-') as temporary:
    root = Path(temporary)
    pixels = bytearray(stride * height)
    for row, top in enumerate(range(80, height - 80, 48)):
        for column, left in enumerate(range(80, width - 80, 40)):
            variant = (column * 13 + row * 37) % 127
            # Similar connected shapes with varying arms, bars and widths.
            stem = 2 + (variant % 3)
            arm = 13 + (variant // 3 % 9)
            middle = 12 + (variant // 27 % 4)
            for y in range(29):
                for x in range(27):
                    ink = (x < stem or (y < 3 and x < arm) or
                           (middle <= y < middle + 2 and x < arm - 3) or
                           (y >= 26 and x < arm + 2) or
                           (variant & 1 and arm - 2 <= x < arm and y < 16))
                    if ink:
                        set_pixel(pixels, left + x, top + y)
    source = root / 'glyphs.pbm'
    source.write_bytes(f'P4\n{width} {height}\n'.encode() + pixels)
    subprocess.run(['cjb2', str(source), str(out / 'jb2-glyphs.djvu')], check=True)

    pixels = bytearray(stride * height)
    for y in range(80, height - 80):
        for x in range(80, width - 80):
            # Grid lines connect the varying diagonal hatching into one symbol.
            if (x % 96 < 2 or y % 112 < 2 or
                    ((x + y * (1 + (y // 112) % 3)) % 47 < 3 and x % 96 < 64)):
                set_pixel(pixels, x, y)
    source = root / 'lineart.pbm'
    source.write_bytes(f'P4\n{width} {height}\n'.encode() + pixels)
    subprocess.run(['cjb2', str(source), str(out / 'jb2-lineart.djvu')], check=True)

for name in ['jb2-glyphs', 'jb2-lineart']:
    path = out / f'{name}.djvu'
    print(f'{path}: {path.stat().st_size} bytes, {width}x{height}')
