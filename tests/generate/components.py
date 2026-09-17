#!/usr/bin/env python3
"""Synthetic directories and shared components; bzz/djvmcvt are test tools only."""
from pathlib import Path
import struct
import subprocess
import tempfile

out = Path(__file__).resolve().parents[1] / 'fixtures'


def chunk(tag, data):
    return tag + struct.pack('>I', len(data)) + data + bytes(len(data) % 2)


def form(kind, parts):
    return chunk(b'FORM', kind + b''.join(chunk(tag, data) for tag, data in parts))


def children(name):
    data, pos, result = (out / f'{name}.djvu').read_bytes(), 16, []
    while pos < len(data):
        length = int.from_bytes(data[pos+4:pos+8], 'big')
        result.append((data[pos:pos+4], data[pos+8:pos+8+length]))
        pos += 8 + length + length % 2
    return result


def directory(entries, bundled, version=1, zero_sizes=False):
    # entry: id, name, title, kind, FORM bytes. Names/IDs deliberately differ.
    sizes = b''.join((0 if zero_sizes else int.from_bytes(data[4:8], 'big')+8).to_bytes(3, 'big') for _, _, _, _, data in entries)
    flags = bytes(kind | (128 if name != id else 0) | (64 if title != id else 0) for id, name, title, kind, _ in entries)
    strings = b''
    for id, name, title, _, _ in entries:
        strings += id.encode() + b'\0'
        if name != id: strings += name.encode() + b'\0'
        if title != id: strings += title.encode() + b'\0'
    compressed = subprocess.check_output(['bzz', '-e50', '-', '-'], input=(sizes if version else b'') + flags + strings)
    header = bytes([version | (128 if bundled else 0)]) + struct.pack('>H', len(entries))
    if bundled:
        prefix_size = len(header) + len(entries)*(4 if version else 7) + len(compressed)
        offset = 16 + 8 + prefix_size + prefix_size % 2
        for i, (_, _, _, _, data) in enumerate(entries):
            header += struct.pack('>I', offset)
            if not version: header += sizes[i*3:i*3+3]
            offset += len(data)
    return chunk(b'DIRM', header + compressed)


def save(name, entries, indirect=False, version=1, zero_sizes=False):
    payload = b'DJVM' + directory(entries, not indirect, version, zero_sizes)
    if indirect:
        folder = out / name
        folder.mkdir(exist_ok=True)
        for _, filename, _, _, data in entries:
            (folder / filename).write_bytes(b'AT&T' + data)
        target = folder / 'index.djvu'
    else:
        payload += b''.join(data for _, _, _, _, data in entries)
        target = out / f'{name}.djvu'
    target.write_bytes(b'AT&T' + chunk(b'FORM', payload))


# A real external encoder's conversion of our shared-JB2 document.
(out / 'indirect').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='djvu-indirect-') as temp:
    subprocess.run(['djvmcvt', '-i', str(out / 'shared.djvu'), temp, 'index.djvu'], check=True)
    for path in Path(temp).iterdir():
        (out / 'indirect' / path.name).write_bytes(path.read_bytes())

source = children('foreground')
info = next(data for tag, data in source if tag == b'INFO')
mask = next(data for tag, data in source if tag == b'Sjbz')
background = [(tag, data) for tag, data in source if tag == b'BG44']
text = 'Shared α text\n'.encode()
text_payload = len(text).to_bytes(3, 'big') + text + b'\x01'
compressed_text = subprocess.check_output(['bzz', '-e50', '-', '-'], input=text_payload)
includes = [(b'INCL', name.encode()) for name in ['paint', 'foreground', 'mask', 'text']]
entries = [
    ('page-a', 'sheet a.djvu', 'Opening', 1, form(b'DJVU', [(b'INFO', info), *includes])),
    ('paint', 'paint.iff', 'paint', 0, form(b'DJVI', [(b'INCL', b'tail')])),
    ('tail', 'tail.iff', 'tail', 0, form(b'DJVI', background)),
    ('foreground', 'foreground.iff', 'foreground', 0, form(b'DJVI', [(b'INCL', b'tail'), (b'FGjp', (out / 'jpeg-foreground-layer.jpg').read_bytes())])),
    ('mask', 'mask.iff', 'mask', 0, form(b'DJVI', [(b'Sjbz', mask)])),
    ('text', 'text.iff', 'text', 0, form(b'DJVI', [(b'TXTz', compressed_text), (b'JUNK', b'preserved')])),
    ('page-b', 'sheet b.djvu', 'Second', 1, form(b'DJVU', [(b'INFO', info), *includes])),
]
save('shared-layers', entries)
save('indirect-layers', entries, indirect=True)
save('indirect-v0', entries, indirect=True, version=0)
save('indirect-zero-sizes', entries, indirect=True, zero_sizes=True)
# The same page opened without DIRM; IDs themselves name the sibling files.
standalone = out / 'standalone-layers'
standalone.mkdir(exist_ok=True)
for id, _, _, _, data in entries[:-1]:
    if id == 'text':
        data = chunk(b'FORM', data[8:] + chunk(b'ANTa', b'(background #123456)'))
    (standalone / ('page.djvu' if id == 'page-a' else id)).write_bytes(b'AT&T' + data)
flat = (out / 'jpeg-foreground.djvu').read_bytes()[4:]
save('shared-layers-reference', [('a', 'a', 'a', 1, flat), ('b', 'b', 'b', 1, flat)])

page = ('page', 'page', 'page', 1, form(b'DJVU', [(b'INFO', info), (b'INCL', b'a')]))
def shared(id, parts, kind=0):
    return (id, id, id, kind, form(b'DJVI' if kind == 0 else b'DJVU', parts))
save('include-cycle', [page, shared('a', [(b'INCL', b'b')]), shared('b', [(b'INCL', b'a')])])
save('include-page', [page, shared('a', [(b'INFO', info)], kind=1)])
save('include-info', [page, shared('a', [(b'INFO', info)])])
save('include-missing', [page])
save('include-conflict', [page, shared('a', [(b'Sjbz', mask), (b'INCL', b'b')]), shared('b', [(b'Sjbz', mask)])])

# Identical shared dictionaries under different IDs occur in producer files.
# Rebuild this case entirely from our minidjvu geometric-symbol fixture.
forms = [data for tag, data in children('shared') if tag == b'FORM']
dictionary = next(data for data in forms if data[:4] == b'DJVI')
aliases = [('a', 'a', 'a', 0, chunk(b'FORM', dictionary)),
           ('b', 'b', 'b', 0, chunk(b'FORM', dictionary))]
for i, data in enumerate(data for data in forms if data[:4] == b'DJVU'):
    pos, parts = 4, []
    while pos < len(data):
        tag, size = data[pos:pos+4], int.from_bytes(data[pos+4:pos+8], 'big')
        if tag != b'INCL': parts.append((tag, data[pos+8:pos+8+size]))
        pos += 8 + size + size % 2
    aliases.append((f'p{i}', f'p{i}', f'p{i}', 1,
                    form(b'DJVU', [parts[0], (b'INCL', b'a'), (b'INCL', b'b'), *parts[1:]])))
save('dictionary-aliases', aliases)
print('Generated indirect directories, nested shared layers/text and malformed include graphs')
