#!/usr/bin/env python3
"""Generate a tiny dense progressive IW44 stream and independent prefix hashes.

Uses c44 and ddjvu only as development tools. The random pixels are synthetic;
each reference includes every complete chunk up to the indicated refinement.
"""
from pathlib import Path
import hashlib
import json
import random
import subprocess
import tempfile

out = Path(__file__).resolve().parents[1] / 'fixtures'
width, height = 65, 67
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    source = root / 'source.ppm'
    source.write_bytes(f'P6\n{width} {height}\n255\n'.encode() +
                       random.Random(44).randbytes(width * height * 3))
    encoded = out / 'iw44-storage.djvu'
    subprocess.run(['c44', '-slice', '74+23+63', '-crcbfull', str(source), str(encoded)], check=True)
    data = encoded.read_bytes()
    body = b'DJVU'
    position = 16
    hashes = []
    while position < len(data):
        size = int.from_bytes(data[position + 4:position + 8], 'big')
        end = position + 8 + size + (size & 1)
        body += data[position:end]
        if data[position:position + 4] == b'BG44':
            prefix = root / 'prefix.djvu'
            prefix.write_bytes(b'AT&TFORM' + len(body).to_bytes(4, 'big') + body)
            expected = root / 'expected.ppm'
            subprocess.run(['ddjvu', '-format=ppm', str(prefix), str(expected)], check=True)
            rgb = expected.read_bytes().split(b'\n255\n', 1)[1]
            hashes.append(hashlib.sha256(rgb).hexdigest())
        position = end
    reference = dict(width=width, height=height, rgb_sha256=hashes)
    (out / 'iw44-storage.json').write_text(json.dumps(reference, indent=2) + '\n')
