#!/usr/bin/env python3
"""Synthetic metadata and reference graphs. Requires DjVuLibre's bzz encoder."""
from pathlib import Path
import struct
import subprocess

out = Path(__file__).resolve().parents[1] / 'fixtures'


def chunk(tag, data):
    return tag + struct.pack('>I', len(data)) + data + bytes(len(data) % 2)


def form(kind, *parts):
    return chunk(b'FORM', kind + b''.join(parts))


def bzz(data):
    return subprocess.check_output(['bzz', '-e50', '-', '-'], input=data)


def directory(entries, bundled):
    sizes = b''.join((8 + int.from_bytes(data[4:8], 'big')).to_bytes(3, 'big') for _, _, data in entries)
    flags = bytes(kind for _, kind, _ in entries)
    names = b''.join(name.encode() + b'\0' for name, _, _ in entries)
    payload = bzz(sizes + flags + names)
    header = bytes([129 if bundled else 1]) + len(entries).to_bytes(2, 'big')
    if bundled:
        length = len(header) + 4 * len(entries) + len(payload)
        offset = 24 + length + length % 2
        for _, _, data in entries:
            header += struct.pack('>I', offset)
            offset += len(data)
    return chunk(b'DIRM', header + payload)


def bundle(name, entries):
    (out / name).write_bytes(b'AT&T' + form(b'DJVM', directory(entries, True), *(data for _, _, data in entries)))


info = chunk(b'INFO', bytes([0, 1, 0, 1, 26, 0, 44, 1, 22, 1]))
# These payloads intentionally cannot be decoded; their structural boundaries
# are valid and reading metadata must never invoke image/OCR/dictionary codecs.
image = chunk(b'Sjbz', b'not an image')
ocr = chunk(b'TXTz', b'not compressed text')
dictionary = chunk(b'Djbz', b'not a dictionary')
shared = (b'(metadata (Title "Shared") (Creator "Scanner") (Unknown "A\\nB") (Title "Shared"))'
          b'(xmp "packet-one")(xmp "packet-two")')
entries = [
    ('shared.djvi', 3, form(b'DJVI', dictionary, chunk(b'ANTz', bzz(shared)))),
    ('first.djvu', 1, form(b'DJVU', info, chunk(b'INCL', b'shared.djvi'), image, ocr)),
    ('second.djvu', 1, form(b'DJVU', info, chunk(b'INCL', b'shared.djvi'), chunk(b'INCL', b'shared.djvi'), image)),
    ('late.djvu', 1, form(b'DJVU', info, image, chunk(b'ANTa', b'(metadata (Title "Late") (title "lower") (Extra "same") (Extra "same"))'))),
    ('orphan.djvi', 0, form(b'DJVI', chunk(b'ANTa', b'(metadata (Unreferenced "kept"))'))),
]
bundle('metadata-book.djvu', entries)
folder = out / 'metadata-indirect'
folder.mkdir(exist_ok=True)
(folder / 'index.djvu').write_bytes(b'AT&T' + form(b'DJVM', directory(entries, False)))
for name, _, data in entries:
    (folder / name).write_bytes(b'AT&T' + data)
(folder / 'standalone.djvu').write_bytes(b'AT&T' + entries[1][2])

bundle('metadata-context.djvu', [
    ('fragment', 0, form(b'DJVI', chunk(b'ANTa', b'middle'))),
    ('escaped', 0, form(b'DJVI', chunk(b'ANTa', b'(metadata (Title "A\\nB"))'))),
    ('split', 1, form(b'DJVU', info, chunk(b'ANTa', b'(metadata (Title "start-'), chunk(b'INCL', b'fragment'), chunk(b'ANTz', bzz(b'-end"))')))),
    ('modern', 1, form(b'DJVU', info, chunk(b'INCL', b'escaped'))),
    ('legacy', 1, form(b'DJVU', info, chunk(b'INCL', b'escaped'), chunk(b'ANTa', b'(metadata (Path "C:\\query"))'))),
    ('prefix', 0, form(b'DJVI', chunk(b'ANTa', b'(metadata (Title "Common-'))),
    ('shared-prefix', 0, form(b'DJVI', chunk(b'ANTa', b'(metadata (Title "Shared-'))),
    ('shared-suffix', 0, form(b'DJVI', chunk(b'ANTa', b'end"))'))),
    *[(name, 1, form(b'DJVU', info, chunk(b'INCL', b'prefix'), chunk(b'ANTa', b'end"))'),
                    chunk(b'INCL', b'shared-prefix'), chunk(b'INCL', b'shared-suffix')))
      for name in ('joined-first', 'joined-second')],
])
bundle('metadata-cycle.djvu', [
    ('a', 0, form(b'DJVI', chunk(b'INCL', b'b'))),
    ('b', 0, form(b'DJVI', chunk(b'INCL', b'a'))),
    ('page', 1, form(b'DJVU', info, chunk(b'INCL', b'a'))),
])
bundle('metadata-bad-length.djvu', [('page', 1, form(b'DJVU', info, b'Sjbz\xff\xff\xff\xff'))])
for name, parts in [
    ('metadata-none.djvu', [image, ocr]),
    ('metadata-links.djvu', [image, chunk(b'ANTz', bzz(b'(maparea "#1" "link only" (rect 0 0 1 1))'))]),
]:
    (out / name).write_bytes(b'AT&T' + form(b'DJVU', info, *parts))
print('Metadata fixtures generated')
