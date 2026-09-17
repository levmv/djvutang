#!/usr/bin/env python3
"""Generate a tiny, sparse 8192×6144 JB2 page for the 64 MiB tile budget test.

Only the compressed synthetic DjVu is kept. Requires external cjb2 to regenerate;
normal tests need no DjVu tools and never allocate the full RGBA reference.
"""
from pathlib import Path
import subprocess
import tempfile

width, height = 8192, 6144
pixels = bytearray(width * height // 8)
# Four small squares, including the corners and an off-grid interior position.
for left, top in [(0, 0), (width - 16, height - 16), (1021, 767), (width // 2, height // 2)]:
    for y in range(top, top + 16):
        for x in range(left, left + 16):
            i = y * width + x
            pixels[i // 8] |= 128 >> (i % 8)
with tempfile.TemporaryDirectory(prefix='djvu-region-fixture-') as temporary:
    source = Path(temporary) / 'page.pbm'
    source.write_bytes(f'P4\n{width} {height}\n'.encode() + pixels)
    target = Path(__file__).resolve().parents[1] / 'fixtures/large-page.djvu'
    subprocess.run(['cjb2', str(source), str(target)], check=True, timeout=60)
print(f'{target.name}: {target.stat().st_size} bytes, {width}×{height}')
