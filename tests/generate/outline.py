#!/usr/bin/env python3
"""Own NAVM trees/directories, plus an external encoder's equivalent outline."""
from pathlib import Path
import json
import struct
import subprocess
import tempfile

out = Path(__file__).resolve().parents[1] / 'fixtures'

def chunk(tag, data):
    return tag + struct.pack('>I', len(data)) + data + bytes(len(data) % 2)

def form(kind, parts):
    return chunk(b'FORM', kind + b''.join(parts))

def bzz(raw):
    return subprocess.check_output(['bzz', '-e50', '-', '-'], input=raw)

def node(title, href, *children):
    return dict(title=title, href=href, children=children)

def encode(tree):
    records, expected = [], []
    def walk(nodes, parent=None):
        for item in nodes:
            index = len(expected)
            expected.append(dict(title=item['title'], href=item['href'], parent=parent, subtreeEnd=None))
            title, href = item['title'].encode(), item['href'].encode()
            records.append(bytes([len(item['children'])]) + len(title).to_bytes(3, 'big') + title + len(href).to_bytes(3, 'big') + href)
            walk(item['children'], index)
            expected[index]['subtreeEnd'] = len(expected)
    walk(tree)
    return struct.pack('>H', len(records)) + b''.join(records), dict(entries=expected)

tree = [node('Contents α🙂', '',
             node('Introduction', '#1'),
             node('Chapter', '#page-a', node('Numeric ID', '#2'), node('Unicode title', '#Приложение α'), node('View', '?page=2&zoom=width')),
             node('<b>Literal title</b>', 'https://example.invalid/α?q=a%20b'),
             node('A B\nQuote " slash \\', '#sheet b.djvu')),
        node('Relative', '#+2'), node('Missing', '#missing'), node('', '')]
raw, expected = encode(tree)
(out / 'outline.raw').write_bytes(raw)
(out / 'outline-expected.json').write_text(json.dumps(expected, ensure_ascii=False, indent=2) + '\n')
navm = chunk(b'NAVM', bzz(raw))
source = (out / 'text-z.djvu').read_bytes()
parts, pos = [], 16
end = 12 + int.from_bytes(source[8:12], 'big')
while pos < end:
    size = int.from_bytes(source[pos+4:pos+8], 'big')
    parts.append(chunk(source[pos:pos+4], source[pos+8:pos+8+size]))
    pos += 8 + size + size % 2
# Add a real annotation href so the same resolver can be used without rewriting
# either annotation or outline snapshots.
page = form(b'DJVU', parts + [chunk(b'ANTa', b'(maparea "#+2" "Next section" (rect 1 2 3 4))')])
entries = [('shared', 'shared.iff', 'Shared', 0, form(b'DJVI', []))]
for id, name, title in [('page-a', 'sheet a.djvu', 'Repeat'), ('page-b', 'sheet b.djvu', '3'),
                        ('2', 'sheet c.djvu', 'Repeat'), ('+1', 'sheet d.djvu', 'Last'),
                        ('page e', 'file e.djvu', 'Приложение α'), ('page%20e', 'dup.djvu', 'Repeat'),
                        ('page-g', 'dup.djvu', 'Appendix')]:
    entries.append((id, name, title, 1, page))

def directory(bundled, extra, entries=entries):
    sizes = b''.join((int.from_bytes(data[4:8], 'big') + 8).to_bytes(3, 'big') for _, _, _, _, data in entries)
    flags = bytes(kind | 192 for _, _, _, kind, _ in entries)
    strings = b''.join((id + '\0' + name + '\0' + title + '\0').encode() for id, name, title, _, _ in entries)
    compressed = bzz(sizes + flags + strings)
    header = bytes([129 if bundled else 1]) + len(entries).to_bytes(2, 'big')
    if bundled:
        length = len(header) + 4 * len(entries) + len(compressed)
        offset = 16 + 8 + length + length % 2 + len(extra)
        for _, _, _, _, data in entries:
            header += struct.pack('>I', offset)
            offset += len(data)
    return chunk(b'DIRM', header + compressed)

def bundle(extra, late=False, entries=entries):
    return b'AT&T' + form(b'DJVM', [directory(True, b'' if late else extra, entries),
                       *([extra] if not late else []), *(data for _, _, _, _, data in entries),
                       *([extra] if late else [])])

(out / 'outline.djvu').write_bytes(bundle(navm))
# DjVuLibre rejects duplicate NAME records; use unique ID/NAME pairs for its
# independent NAVM decoder comparison, retaining ambiguity cases above.
(out / 'outline-oracle.djvu').write_bytes(bundle(navm, entries=[(id, id, title, kind, data) for id, _, title, kind, data in entries]))
(out / 'outline-late.djvu').write_bytes(bundle(navm, late=True))
(out / 'outline-duplicate.djvu').write_bytes(bundle(navm + navm))
(out / 'outline-single.djvu').write_bytes(b'AT&T' + chunk(b'FORM', page[8:] + navm))
# djvused drops NUL while writing editor strings. Test counted binary strings
# separately so their preservation does not depend on that editor behavior.
strings = encode([node('\ufeffA\0B\n"\\α', '#page-a\0')])[0]
(out / 'outline-strings.djvu').write_bytes(b'AT&T' + chunk(b'FORM', page[8:] + chunk(b'NAVM', bzz(strings))))
folder = out / 'outline-indirect'
folder.mkdir(exist_ok=True)
(folder / 'index.djvu').write_bytes(b'AT&T' + form(b'DJVM', [directory(False, navm), navm]))
for _, name, _, _, data in entries:
    (folder / name).write_bytes(b'AT&T' + data)

bad = {'count': b'\x00\xff' + raw[2:], 'children': raw[:2] + b'\xff' + raw[3:],
       'unfinished': b'\0\3' + b'\2' + b'\0' * 6 + b'\1' + b'\0' * 6 + b'\0' * 7,
       'title-utf8': raw[:6] + b'\xff' + raw[7:], 'href-utf8': encode([node('', 'x')])[0][:-1] + b'\xff',
       'length': raw[:3] + b'\xff\xff\xff' + raw[6:], 'trailing': raw + b'\0',
       'short': raw[:-1], 'empty-stream': b''}
for name, data in bad.items():
    (out / f'outline-bad-{name}.navm').write_bytes(bzz(data))
(out / 'outline-bad.djvu').write_bytes(bundle(chunk(b'NAVM', bzz(bad['children']))))
(out / 'outline-empty.djvu').write_bytes(bundle(chunk(b'NAVM', bzz(b'\0\0'))))
for depth in [64, 65]:
    chain = node('', '')
    for _ in range(depth - 1): chain = node('', '', chain)
    (out / f'outline-depth{depth}.navm').write_bytes(bzz(encode([chain])[0]))
(out / 'outline-wide.navm').write_bytes(bzz(encode([node('Wide', '', *(node('', '') for _ in range(255))), node('Second root', '')])[0]))
# UINT16 count's upper boundary with tiny empty leaf records.
(out / 'outline-max.navm').write_bytes(bzz(b'\xff\xff' + b'\0' * (65535 * 7)))

# DjVuLibre independently encodes the same logical tree from its editor syntax.
def quoted(value):
    result = '"'
    for c in value:
        if c in ['"', '\\']: result += '\\' + c
        elif ord(c) < 32: result += '\\%03o' % ord(c)
        else: result += c
    return result + '"'
def sexpr(item):
    return '(' + quoted(item['title']) + ' ' + quoted(item['href']) + ''.join(' ' + sexpr(c) for c in item['children']) + ')'
script = '(bookmarks\n' + '\n'.join(sexpr(n) for n in tree) + '\n)\n'
(out / 'outline.dsed').write_text(script)
with tempfile.TemporaryDirectory(prefix='djvu-outline-') as temp:
    target = Path(temp) / 'outline.djvu'
    target.write_bytes((out / 'shared.djvu').read_bytes())
    subprocess.run(['djvused', str(target), '-s', '-e', f'set-outline {out / "outline.dsed"}'], check=True)
    (out / 'outline-djvused.djvu').write_bytes(target.read_bytes())
print('Outline fixtures generated')
