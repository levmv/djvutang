#!/usr/bin/env python3
"""Own TH44 images, DIRM groups, page-local thumbnails and standalone THUM."""
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

out = Path(__file__).resolve().parents[1] / 'fixtures'


def chunk(tag, data):
    return tag + len(data).to_bytes(4, 'big') + data + bytes(len(data) % 2)


def form(kind, parts):
    return chunk(b'FORM', kind + b''.join(chunk(tag, data) for tag, data in parts))


def children(data):
    pos = 16
    while pos < len(data):
        size = int.from_bytes(data[pos+4:pos+8], 'big')
        yield data[pos:pos+4], data[pos+8:pos+8+size]
        pos += 8 + size + size % 2


def save(entries, indirect=False, name='thumbnails', page_files=()):
    # Physical order differs from DIRM order. Shared components do not consume pages.
    order = list(reversed(range(len(entries))))
    sizes = b''.join((len(data)).to_bytes(3, 'big') for _, _, _, data in entries)
    flags = bytes(kind | (128 if name != id else 0) for id, name, kind, _ in entries)
    names = b''.join(id.encode() + b'\0' + (name.encode() + b'\0' if name != id else b'') for id, name, _, _ in entries)
    compressed = subprocess.check_output(['bzz', '-e50', '-', '-'], input=sizes + flags + names)
    prefix = bytes([1 if indirect else 129]) + len(entries).to_bytes(2, 'big')
    if not indirect:
        offsets = [0] * len(entries)
        pos = 16 + len(chunk(b'DIRM', prefix + bytes(len(entries)*4) + compressed))
        for i in order:
            offsets[i] = pos
            pos += len(entries[i][3])
        prefix += b''.join(offset.to_bytes(4, 'big') for offset in offsets)
    data = b'DJVM' + chunk(b'DIRM', prefix + compressed)
    if indirect:
        folder = out / f'{name}-indirect'
        folder.mkdir(exist_ok=True)
        # Covered pages and all shared files can remain unavailable. Fallback
        # checks only pages that have no corresponding TH44 in a DIRM group.
        for _, filename, kind, content in entries:
            if kind == 2 or filename in page_files:
                (folder / filename).write_bytes(b'AT&T' + content)
        target = folder / 'index.djvu'
    else:
        data += b''.join(entries[i][3] for i in order)
        target = out / f'{name}.djvu'
    target.write_bytes(b'AT&T' + chunk(b'FORM', data))


with tempfile.TemporaryDirectory(prefix='djvu-thumbnails-') as temp:
    temp = Path(temp)
    images = []
    for name, width, height, color in [('color', 11, 7, True), ('gray', 9, 13, False)]:
        pixels = bytes(value for y in range(height) for x in range(width)
                       for value in ((x*23 % 256, y*39 % 256, (x*17+y*11) % 256) if color else ((x*21+y*13) % 256,)))
        source = out / f'thumbnail-{name}.pnm'
        source.write_bytes(f'{"P6" if color else "P5"}\n{width} {height}\n255\n'.encode() + pixels)
        encoded = temp / f'{name}.djvu'
        subprocess.run(['c44', '-slice', '100', str(source), str(encoded)], check=True)
        layers = [data for tag, data in children(encoded.read_bytes()) if tag == b'BG44']
        assert len(layers) == 1
        (out / f'thumbnail-{name}.th44').write_bytes(layers[0])
        subprocess.run(['ddjvu', '-format=ppm', str(encoded), str(out / f'thumbnail-{name}-expected.ppm')], check=True)
        images.append(layers[0])
    # Page INFO deliberately differs in dimensions, gamma and orientation.
    page = form(b'DJVU', [(b'INFO', struct.pack('>HH', 73, 47) + bytes([24, 0, 44, 1, 14, 6]))])
    shared = form(b'DJVI', [(b'JUNK', b'ignored')])
    entries = [
        ('p0', 'p0', 1, page),
        ('group-a', 'first.thumb', 2, form(b'THUM', [(b'JUNK', b'kept'), (b'TH44', images[0]), (b'JUNK', b'odd'), (b'TH44', images[1])])),
        ('shared', 'shared', 0, shared),
        ('p1', 'p1', 1, page), ('p2', 'p2', 1, page), ('p3', 'p3', 1, page),
        ('group-b', 'second.thumb', 2, form(b'THUM', [(b'TH44', images[1])])),
        ('p4', 'p4', 1, page),
        ('empty', 'empty.thumb', 2, form(b'THUM', [])),
        ('p5', 'p5', 1, page),
    ]
    save(entries)
    save(entries, indirect=True, page_files=('p0', 'p3', 'p5'))
    # A producer compatibility layout: one TH44 directly inside the page.
    # The unresolved INCL makes thumbnail independence observable.
    info = next(children(b'AT&T' + page))[1]
    def inline(image):
        return form(b'DJVU', [(b'INFO', info), (b'INCL', b'unavailable.djvi'), (b'TH44', image)])
    (out / 'thumbnail-inline.djvu').write_bytes(b'AT&T' + inline(images[0]))
    progressive = temp / 'progressive.djvu'
    subprocess.run(['c44', '-slice', '50,100', str(out / 'thumbnail-color.pnm'), str(progressive)], check=True)
    parts = [(b'TH44', data) for tag, data in children(progressive.read_bytes()) if tag == b'BG44']
    assert len(parts) == 2 and [data[0] for _, data in parts] == [0, 1]
    (out / 'thumbnail-inline-progressive.djvu').write_bytes(b'AT&T' + form(b'DJVU', [(b'INFO', info), *parts]))
    inline_entries = [
        ('p0', 'p0', 1, inline(images[0])),
        ('group', 'group.thumb', 2, form(b'THUM', [(b'TH44', images[1])])),
        ('p1', 'p1', 1, inline(images[0])), # DIRM gray wins over inline color.
        ('p2', 'p2', 1, inline(images[1])), # Short THUM falls back to the page.
        ('empty', 'empty.thumb', 2, form(b'THUM', [])),
        ('p3', 'p3', 1, inline(images[0])), # Empty THUM also permits fallback.
        ('p4', 'p4', 1, page),
    ]
    save(inline_entries, name='thumbnails-inline')
    save(inline_entries, indirect=True, name='thumbnails-inline', page_files=('p0', 'p2', 'p3', 'p4'))
    (out / 'thumbnails.thum').write_bytes(b'AT&T' + form(b'THUM', [
        (b'JUNK', b'odd'), (b'TH44', images[0]), (b'INCL', b'not-a-page'), (b'TH44', images[1]),
    ]))
    # Same untouched IW44 bytes in ordinary pages for ddjvu, whose document
    # renderer does not treat standalone THUM as an image collection.
    references = []
    for i, (image, width, height) in enumerate(zip(images, [11, 9], [7, 13])):
        header = struct.pack('>HH', width, height) + bytes([24, 0, 44, 1, 22, 1])
        references.append((f'p{i}', f'p{i}', 1, form(b'DJVU', [(b'INFO', header), (b'BG44', image)])))
    save(references, name='thumbnails-reference')
    # An independent producer builds a normal grouped thumbnail document.
    producer = temp / 'producer.djvu'
    producer.write_bytes((out / 'shared-layers-reference.djvu').read_bytes())
    subprocess.run(['djvused', str(producer), '-e', 'set-thumbnails 32', '-s'], check=True)
    (out / 'thumbnails-djvused.djvu').write_bytes(producer.read_bytes())
    subprocess.run([sys.executable, str(out.parent / 'oracle/thumbnails.py'), str(producer), '1', '32', '24',
                    str(out / 'thumbnail-djvused-expected.ppm')], check=True)
print('Generated own thumbnails: sparse DIRM groups, inline TH44 and standalone THUM')
