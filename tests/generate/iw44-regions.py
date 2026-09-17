#!/usr/bin/env python3
"""Generate a compressible large IW44 layer and its independent full-RGB hash.

Pixels are synthetic. Only the encoded input and the hash are retained; c44 and
DjVuLibre are development oracles, never runtime dependencies.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile

out = Path(__file__).resolve().parents[1] / 'fixtures'
width, height = 2305, 3651
with tempfile.TemporaryDirectory() as temp:
    source = Path(temp) / 'source.ppm'
    rows = []
    for y in range(height):
        row = bytearray()
        for x in range(width):
            ink = ((x % 769 in (30, 31, 32) and y % 613 < 109) or
                   (y % 613 in (64, 65) and x % 769 < 139))
            color = ((40 + (x // 769) * 17) % 256,
                     (67 + (y // 613) * 23) % 256,
                     (221 + (x // 769 - y // 613) * 13) % 256)
            row.extend((8, 19, 30) if ink else color)
        rows.append(row)
    source.write_bytes(f'P6\n{width} {height}\n255\n'.encode() + b''.join(rows))
    encoded = out / 'iw44-regions.djvu'
    subprocess.run(['c44', '-slice', '74+10+13', '-crcbhalf', str(source), str(encoded)], check=True)
    expected = Path(temp) / 'expected.ppm'
    subprocess.run(['ddjvu', '-format=ppm', str(encoded), str(expected)], check=True)
    rgb = expected.read_bytes().split(b'\n255\n', 1)[1]
    reference = dict(width=width, height=height, rgb_sha256=hashlib.sha256(rgb).hexdigest())
    (out / 'iw44-regions.json').write_text(json.dumps(reference, indent=2) + '\n')
