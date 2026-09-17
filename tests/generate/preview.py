#!/usr/bin/env python3
"""A tiny shared-dictionary book with a shared IW44 background.

Reuses our geometric-symbol fixture; c44 and bzz are generation tools only.
"""
from pathlib import Path
import subprocess
import tempfile

out = Path(__file__).resolve().parents[1] / 'fixtures'


def chunk(tag, data):
    return tag + len(data).to_bytes(4, 'big') + data + bytes(len(data) % 2)


def parts(data, start):
    result = []
    while start < len(data):
        size = int.from_bytes(data[start + 4:start + 8], 'big')
        result.append((data[start:start + 4], data[start + 8:start + 8 + size]))
        start += 8 + size + size % 2
    return result


with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    pixels = bytearray()
    for y in range(100):
        for x in range(160):
            pixels.extend((190 + x % 53, 175 + y % 67, 200 + (x + y) % 43))
    (root / 'bg.ppm').write_bytes(b'P6\n160 100\n255\n' + pixels)
    subprocess.run(['c44', '-slice', '74+10+13', '-crcbfull', str(root / 'bg.ppm'), str(root / 'bg.djvu')], check=True)
    background = [(tag, data) for tag, data in parts((root / 'bg.djvu').read_bytes(), 16) if tag == b'BG44']

entries = []
for tag, data in parts((out / 'shared.djvu').read_bytes(), 16):
    if tag != b'FORM':
        continue
    children = parts(data, 4)
    if data[:4] == b'DJVI':
        entries.append(('paint', 0, chunk(b'FORM', b'DJVI' + b''.join(chunk(t, d) for t, d in [*children, *background]))))
    else:
        children = [(t, b'paint' if t == b'INCL' else d) for t, d in children]
        entries.append((f'page-{len(entries)}', 1, chunk(b'FORM', b'DJVU' + b''.join(chunk(t, d) for t, d in children))))

sizes = b''.join(len(form).to_bytes(3, 'big') for _, _, form in entries)
flags = bytes(kind for _, kind, _ in entries)
names = b''.join(name.encode() + b'\0' for name, _, _ in entries)
compressed = subprocess.check_output(['bzz', '-e50', '-', '-'], input=sizes + flags + names)
header = b'\x81' + len(entries).to_bytes(2, 'big')
length = len(header) + 4 * len(entries) + len(compressed)
offset = 24 + length + length % 2
for _, _, form in entries:
    header += offset.to_bytes(4, 'big')
    offset += len(form)
body = b'DJVM' + chunk(b'DIRM', header + compressed) + b''.join(form for _, _, form in entries)
(out / 'preview-shared.djvu').write_bytes(b'AT&T' + chunk(b'FORM', body))
