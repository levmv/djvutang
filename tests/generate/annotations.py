#!/usr/bin/env python3
"""Own annotation text on own raster; bzz/djvused/djvmcvt are test tools only."""
from pathlib import Path
import struct
import subprocess
import tempfile

out = Path(__file__).resolve().parents[1] / 'fixtures'

def chunk(tag, data):
    return tag + struct.pack('>I', len(data)) + data + bytes(len(data) % 2)

def children(data):
    pos, result = 16, []
    while pos < len(data):
        size = int.from_bytes(data[pos+4:pos+8], 'big')
        result.append((data[pos:pos+4], data[pos+8:pos+8+size]))
        pos += 8 + size + size % 2
    return result

def page(parts):
    return b'AT&T' + chunk(b'FORM', b'DJVU' + b''.join(chunk(tag, data) for tag, data in parts))

def bzz(data):
    return subprocess.check_output(['bzz', '-e50', '-', '-'], input=data)

raw = r'''(background #123456) (zoom d175) (mode back) (align left bottom)
(metadata (Title "Synthetic α notes") (Author "A\nB") (Title "Last title") (__proto__ "ordinary key"))
(xmp "<rdf:RDF xmlns:rdf=\"urn:synthetic\"><title>α</title></rdf:RDF>")
(phead "left::Header" "right::Page") (pfoot "center::Footer")
(maparea (url "https://example.invalid/α?q=1&b=2" "_blank") "Quote: \"; slash: \\; octal: \316\261"
 (rect 5 7 23 11) (border #ABCDEF) (border_avis) (hilite #FF8000) (opacity 75) (future_style 9))
(maparea "#+1" "Oval" (oval -2 3 15 9) (xor))
(maparea "#page-a" "Polygon" (poly 10 5 30 8 20 22) (none))
(maparea "" "Arrow" (line 4 6 40 25) (arrow) (width 3) (lineclr #010203))
(maparea "" "Note\nTwo lines" (text 30 12 20 10) (pushpin) (backclr #FFFF80) (textclr #123456) (border #000000))
(maparea "#2" "Shadow" (rect 1 1 4 4) (shadow_eout 7))
(future_extension (nested "unchanged (α)" 999999999999999999999))
(maparea "bad" "negative size" (rect 0 0 -2 3)) (zoom d0) (background #oops)
'''.encode()
(out / 'annotations.raw').write_bytes(raw)
base = [(tag, data) for tag, data in children((out / 'text-z.djvu').read_bytes()) if tag != b'TXTz']
for tag, name in [(b'ANTa', 'annotations-a'), (b'ANTz', 'annotations-z')]:
    (out / (name + '.djvu')).write_bytes(page(base + [(tag, bzz(raw) if tag == b'ANTz' else raw)]))
# Concatenation is literal, even in the middle of an expression/string.
split = raw.index(b'Synthetic') + 4
(out / 'annotations-split.djvu').write_bytes(page(base + [(b'ANTa', raw[:split]), (b'ANTz', bzz(raw[split:]))]))
for rotation, flag in enumerate([1, 6, 2, 5]):
    parts = [(tag, data[:9] + bytes([flag]) if tag == b'INFO' else data) for tag, data in base]
    (out / f'annotations-rot{rotation}.djvu').write_bytes(page(parts + [(b'ANTa', raw)]))
legacy = br'(metadata (path "C:\query\notes") (literal "keep\n") (quote "a\"b"))'
(out / 'annotations-legacy.djvu').write_bytes(page(base + [(b'ANTa', legacy)]))
(out / 'annotations-empty.djvu').write_bytes(page(base + [(b'ANTz', bzz(b''))]))
(out / 'annotations-bad.djvu').write_bytes(page(base + [(b'ANTa', b'(maparea "unterminated')]))
(out / 'annotations-utf8.djvu').write_bytes(page(base + [(b'ANTa', br'(metadata (bad "\377"))')]))
(out / 'annotations-bzz-bad.djvu').write_bytes(page(base + [(b'ANTz', bzz(raw)[:12])]))

# Raw damage, escape-produced damage, valid Unicode and independent directives.
# Damaged navigation identifiers stay in source rather than becoming new links.
recovered = (b'\xef\xbb\xbf(metadata (Title "A\x95B") (Escaped "\\342\\202X\\377") (Good "' + 'Ж🙂'.encode() + b'") (\xff "unknown key"))\n'
             b'(maparea "#1" "C\xc2D" (rect 5 7 23 11))\n'
             b'(maparea "#\xff" "damaged href" (rect 1 1 2 2))\n'
             b'(maparea (url "#2" "_bl\xffank") "damaged target" (rect 1 1 2 2))\n'
             b'(future "\xe2\x82") (zoom d175)\n')
(out / 'annotations-recovered.raw').write_bytes(recovered)
for tag, suffix in [(b'ANTa', 'a'), (b'ANTz', 'z')]:
    (out / f'annotations-recovered-{suffix}.djvu').write_bytes(page(base + [(tag, bzz(recovered) if tag == b'ANTz' else recovered)]))
split = recovered.index('Ж'.encode()) + 1
(out / 'annotations-recovered-split.djvu').write_bytes(page(base + [(b'ANTa', recovered[:split]), (b'ANTz', bzz(recovered[split:]))]))

# DjVuLibre generates its dedicated DIRM kind 3 shared annotation component.
with tempfile.TemporaryDirectory(prefix='djvu-annotations-') as temp:
    temp = Path(temp)
    shared = temp / 'shared.ant'
    shared.write_text('(background #FFFFFF) (zoom page) (metadata (Author "Shared author") (Book "Shared book"))\n(maparea "#2" "Shared link" (rect 2 3 4 5))\n')
    local = temp / 'local.ant'
    local.write_bytes(raw)
    bundle = temp / 'annotations-shared.djvu'
    subprocess.run(['djvm', '-c', str(bundle), str(out / 'annotations-a.djvu'), str(out / 'annotations-a.djvu')], check=True)
    subprocess.run(['djvused', '-s', str(bundle), '-e', f'create-shared-ant; set-ant {shared}; select 1; set-ant {local}; select 2; remove-ant'], check=True)
    (out / bundle.name).write_bytes(bundle.read_bytes())
    indirect = temp / 'indirect'
    indirect.mkdir()
    subprocess.run(['djvmcvt', '-i', str(bundle), str(indirect), 'index.djvu'], check=True)
    (out / 'annotations-indirect').mkdir(exist_ok=True)
    for file in indirect.iterdir():
        (out / 'annotations-indirect' / file.name).write_bytes(file.read_bytes())
print('Annotation fixtures generated')
