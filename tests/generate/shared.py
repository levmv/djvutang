#!/usr/bin/env python3
"""Regenerate our synthetic shared-symbol fixture. Requires minidjvu, not at build time."""
import argparse
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--minidjvu', default='minidjvu')
args = p.parse_args()
out = Path(__file__).resolve().parents[1] / 'fixtures'
out.mkdir(exist_ok=True)
for page in range(2):
    width, height = 160, 100
    pixels = bytearray((width + 7) // 8 * height)
    for y in range(height):
        for x in range(width):
            lx, ly = x % 20, y % 18
            shape = ((lx == 3 and 3 <= ly <= 12)
                     or (ly in [3, 7, 12] and 3 <= lx <= 10)
                     or (page == 1 and (x // 20) % 2 == 1 and lx == 10 and 3 <= ly <= 7))
            if shape and x > 20 and y > 10:
                i = y * width + x
                pixels[i // 8] |= 128 >> (i % 8)
    (out / f'page{page}.pbm').write_bytes(f'P4\n{width} {height}\n'.encode() + pixels)
subprocess.run([args.minidjvu, str(out / 'page0.pbm'), str(out / 'page1.pbm'), str(out / 'shared.djvu')], check=True, timeout=30)
