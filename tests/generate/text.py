#!/usr/bin/env python3
"""Own geometric/text fixtures, encoded by external cjb2/djvused/BZZ.

No books, fonts or downloaded artwork. Normal tests use the saved tiny fixtures.
"""
import json
from pathlib import Path
import struct
import subprocess
import tempfile

out = Path(__file__).resolve().parents[1] / 'fixtures'
width, height = 101, 79


def zone(kind, x, y, w, h, children):
    return dict(kind=kind, bounds=dict(x=x, y=y, width=w, height=h), children=children)


tree = zone('page', 0, 0, width, height, [
    zone('column', 3, 4, 48, 70, [
        zone('region', 3, 4, 48, 36, [
            zone('paragraph', 3, 4, 48, 36, [
                zone('line', 5, 7, 42, 13, [
                    zone('word', 5, 7, 16, 12, 'AЖB'),
                    zone('word', 26, 8, 20, 11, [
                        zone('character', 26, 8, 5, 11, 'e'),
                        zone('character', 29, 5, 3, 4, '\u0301'),
                        zone('character', 35, 8, 11, 11, '🙂'),
                    ]),
                ]),
                zone('line', 5, 26, 38, 10, [zone('word', 5, 26, 38, 10, '漢字')]),
            ]),
        ]),
        zone('region', 4, 47, 46, 25, [
            zone('paragraph', 4, 47, 46, 12, [zone('line', 6, 48, 39, 10, [zone('word', 6, 48, 39, 10, 'строка')])]),
            zone('paragraph', 4, 62, 46, 10, [zone('line', 6, 62, 39, 10, [zone('word', 6, 62, 39, 10, 'אבג')])]),
        ]),
    ]),
    zone('column', 56, 3, 42, 70, [
        zone('line', 57, 5, 38, 12, [zone('word', 57, 5, 38, 12, 'right')]),
        zone('line', 57, 29, 38, 12, [zone('word', 57, 29, 38, 12, 'end')]),
    ]),
])


def sexp(z):
    b = z['bounds']
    rect = (b['x'], height - b['y'] - b['height'], b['x'] + b['width'], height - b['y'])
    children = z['children']
    body = json.dumps(children, ensure_ascii=False) if isinstance(children, str) else '\n'.join(sexp(c) for c in children)
    kind = {'paragraph': 'para', 'character': 'char'}.get(z['kind'], z['kind'])
    return f'({kind} {" ".join(map(str, rect))}\n{body})'


def run(*args):
    result = subprocess.run(list(map(str, args)), capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError(result.stderr.decode())
    return result.stdout


def chunks(data):
    result, pos = [], 16
    while pos < len(data):
        length = int.from_bytes(data[pos + 4:pos + 8], 'big')
        result.append((data[pos:pos + 4], data[pos + 8:pos + 8 + length]))
        pos += 8 + length + length % 2
    return result


def document(parts):
    body = b'DJVU'
    for kind, payload in parts:
        body += kind + struct.pack('>I', len(payload)) + payload + bytes(len(payload) % 2)
    return b'AT&TFORM' + struct.pack('>I', len(body)) + body


pixels = bytearray((width + 7) // 8 * height)


def paint(z):
    if z['kind'] == 'word':
        b = z['bounds']
        for y in range(b['y'], b['y'] + b['height']):
            for x in range(b['x'], b['x'] + b['width']):
                pixels[y * ((width + 7) // 8) + x // 8] |= 128 >> (x % 8)
    elif isinstance(z['children'], list):
        for child in z['children']:
            paint(child)


paint(tree)
with tempfile.TemporaryDirectory(prefix='djvu-text-fixture-') as temp:
    temp = Path(temp)
    bitmap = f'P4\n{width} {height}\n'.encode() + pixels
    (temp / 'page.pbm').write_bytes(bitmap)
    (out / 'text-mask.pbm').write_bytes(bitmap)
    (temp / 'text.sexp').write_text(sexp(tree) + '\n')
    run('cjb2', temp / 'page.pbm', out / 'text-z.djvu')
    run('djvused', '-s', out / 'text-z.djvu', '-e', f'select 1; set-txt {temp / "text.sexp"}')
    parts = chunks((out / 'text-z.djvu').read_bytes())
    compressed = next(payload for kind, payload in parts if kind == b'TXTz')
    (temp / 'text.bzz').write_bytes(compressed)
    run('bzz', '-d', temp / 'text.bzz', temp / 'text.raw')
    raw = (temp / 'text.raw').read_bytes()
    (out / 'text.raw').write_bytes(raw)
    (out / 'text-a.djvu').write_bytes(document([(b'TXTa', raw) if k == b'TXTz' else (k, p) for k, p in parts]))
    rotated = [(k, p[:9] + bytes([6]) + p[10:] if k == b'INFO' else p) for k, p in parts]
    (out / 'text-rotated.djvu').write_bytes(document(rotated))
    # Text without layout, and a present empty text layer, are distinct from absent.
    plain_parts = [(k, p) for k, p in parts if k != b'TXTz']
    literal = '\ufeffA\x00Ж\r\nB\x0bC\x1dD\x1eE\x1f🙂'.encode()
    for name, data in [('text-only', len(literal).to_bytes(3, 'big') + literal), ('text-empty', b'\x00\x00\x00\x01')]:
        (out / f'{name}.djvu').write_bytes(document(plain_parts + [(b'TXTa', data)]))
    oracle = run('djvused', '-u', out / 'text-z.djvu', '-e', 'select 1; print-txt').decode()
    (out / 'text-oracle.sexp').write_text(oracle)
    size = int.from_bytes(raw[:3], 'big')
    expected = dict(width=width, height=height, text=raw[3:3 + size].decode(), tree=tree)
    (out / 'text-expected.json').write_text(json.dumps(expected, ensure_ascii=False, indent=2) + '\n')
    # Keep every original zone offset while corrupting bytes before and inside
    # multibyte/combining/emoji spans. No source encoding can be inferred here.
    recovered = bytearray(raw)
    for offset, byte in [(0, 0x95), (3, 0xe2), (5, 0xc2), (9, 0xff)]:
        recovered[3 + offset] = byte
    (out / 'text-recovered.raw').write_bytes(recovered)
    (temp / 'recovered.raw').write_bytes(recovered)
    run('bzz', '-e50', temp / 'recovered.raw', temp / 'recovered.bzz')
    for tag, suffix, data in [(b'TXTa', 'a', recovered), (b'TXTz', 'z', (temp / 'recovered.bzz').read_bytes())]:
        (out / f'text-recovered-{suffix}.djvu').write_bytes(document(plain_parts + [(tag, data)]))
    original = bytes(recovered[3:3 + size])
    (out / 'text-recovered.json').write_text(json.dumps(dict(bytes=list(original), text=original.decode('utf8', errors='replace')), ensure_ascii=False) + '\n')
    print(json.dumps(dict(text=expected['text'], rawBytes=len(raw), compressedBytes=len(compressed)), ensure_ascii=False))
