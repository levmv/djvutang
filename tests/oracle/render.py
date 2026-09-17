#!/usr/bin/env python3
"""Compare native/WASM with independent pixel references; measure DjVuLibre differences."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--out', type=Path, default=root / 'tests/out')
args = p.parse_args()
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)
subprocess.run(['node', str(root / 'tests/wasm/render.mjs'), str(out)], check=True, timeout=60)
wasm = json.loads((out / 'wasm.json').read_text())
fixtures = {f['name']: f for f in json.loads((root / 'tests/fixtures/cases.json').read_text())}


def ppm(data):
    header, pixels = data.split(b'\n255\n', 1)
    width, height = map(int, header.splitlines()[-1].split())
    assert len(pixels) == width * height * 3
    return width, height, pixels


def rotate(width, height, rgb, rotation):
    if rotation == 0:
        return width, height, rgb
    assert rotation == 1  # this fixture requests one counterclockwise turn
    result = bytearray(len(rgb))
    for y in range(width):
        for x in range(height):
            source = (x * width + width - 1 - y) * 3
            dest = (y * height + x) * 3
            result[dest:dest + 3] = rgb[source:source + 3]
    return height, width, bytes(result)


def color_reference(fixture, subsample, page):
    reference = fixture['references'][page] if 'references' in fixture else fixture['reference']
    width, height, rgb = ppm((root / reference).read_bytes())
    rotation = fixture['rotation']
    if rotation:
        # Undo the INFO rotation before applying the bottom-left reduction grid.
        for _ in range(3):
            width, height, rgb = rotate(width, height, rgb, 1)
    w = (width + subsample - 1) // subsample
    h = (height + subsample - 1) // subsample
    result = bytearray()
    area = subsample * subsample
    for y in range(h):
        for x in range(w):
            sums = [0, 0, 0]
            for dy in range(subsample):
                sy = min(height - 1, max(0, y * subsample + dy - (h * subsample - height)))
                for dx in range(subsample):
                    sx = min(width - 1, x * subsample + dx)
                    index = (sy * width + sx) * 3
                    for c in range(3):
                        sums[c] += rgb[index + c]
            result.extend((value + area // 2) // area for value in sums)
    w, h, pixels = rotate(w, h, result, rotation)
    return f'P6\n{w} {h}\n255\n'.encode() + pixels


def mask_reference(fixture, subsample):
    # Source PBM, independent of both decoders. In very small images ddjvu's
    # -size can choose a different reduction; -subsample can round a size to 0.
    data = (root / fixture['source']).read_bytes()
    magic, dimensions, packed = data.split(b'\n', 2)
    assert magic == b'P4'
    width, height = map(int, dimensions.split())
    stride = (width + 7) // 8
    assert len(packed) == stride * height
    w, h = (width + subsample - 1) // subsample, (height + subsample - 1) // subsample
    top_padding, area = h * subsample - height, subsample * subsample
    pixels = bytearray()
    for y in range(h):
        for x in range(w):
            ink = 0
            for sy in range(max(0, y * subsample - top_padding), min(height, (y + 1) * subsample - top_padding)):
                for sx in range(x * subsample, min(width, (x + 1) * subsample)):
                    ink += (packed[sy * stride + sx // 8] >> (7 - sx % 8)) & 1
            # An explicit white color background uses the color box policy:
            # round the mean display samples. Bare masks use coverage rounding.
            gray = ((area - ink) * 255 + area // 2) // area if fixture['profile'] == 'color' else 255 - (ink * 255 + area // 2) // area
            pixels.extend([gray] * 3)
    return f'P6\n{w} {h}\n255\n'.encode() + pixels


rows = []
for result in wasm['results']:
    name, page, ss = result['name'], result['page'], result['subsample']
    stem = f'{name}-{page}-{ss}'
    native = out / f'{stem}-native.ppm'
    oracle = out / f'{stem}-oracle.ppm'
    fixture = fixtures[name]
    source = root / fixture['path']
    oracle_source = root / fixture.get('oracle_path', fixture['path'])
    n = subprocess.run([str(root / 'zig-out/bin/djvutang'), 'render', str(source), str(native), str(page + 1), str(ss)], check=True, capture_output=True, text=True, timeout=30)
    # Match both dimensions explicitly: ddjvu's default aspect correction can
    # round one dimension differently from the requested integer reduction.
    size = f'{result["width"]}x{result["height"]}'
    subprocess.run(['ddjvu', '-format=ppm', f'-page={page + 1}', f'-size={size}', '-aspect=no', str(oracle_source), str(oracle)], check=True, capture_output=True, timeout=30)
    native_hash = hashlib.sha256(native.read_bytes()).hexdigest()
    oracle_hash = hashlib.sha256(oracle.read_bytes()).hexdigest()
    if 'source' in fixture:
        reference = mask_reference(fixture, ss)
        reference_kind = fixture.get('reference_kind', 'source PBM/coverage reference')
    elif fixture['profile'] == 'bilevel':
        reference = oracle.read_bytes()
        reference_kind = 'DjVuLibre'
    else:
        reference = color_reference(fixture, ss, page)
        reference_kind = fixture.get('reference_kind', 'independent color/box reference')
    reference_hash = hashlib.sha256(reference).hexdigest()
    (out / f'{stem}-reference.ppm').write_bytes(reference)
    native_pixels = ppm(native.read_bytes())[2]
    oracle_pixels = ppm(oracle.read_bytes())[2]
    delta = [abs(a - b) for a, b in zip(native_pixels, oracle_pixels, strict=True)]
    row = dict(name=name, page=page, subsample=ss, native=native_hash,
               wasm=result['sha256'], oracle=oracle_hash,
               reference=reference_hash,
               reference_kind=reference_kind,
               exact=native_hash == result['sha256'] == reference_hash,
               djvulibre_exact=native_hash == oracle_hash,
               djvulibre_max_error=max(delta), djvulibre_mean_error=sum(delta) / len(delta),
               oracle_source=str(oracle_source.relative_to(root)), native_stats=json.loads(n.stdout))
    rows.append(row)
report = dict(date=datetime.now(timezone.utc).date().isoformat(), cases=rows,
              all_exact=all(r['exact'] for r in rows))
(out / 'comparison.json').write_text(json.dumps(report, indent=2) + '\n')
for row in rows:
    if not row['exact']: print('Mismatch:', row['name'], row['page'], row['subsample'])
assert report['all_exact'], 'See comparison.json and the PPM files'
print(f'{len(rows)} native / WASM / reference comparisons are byte-exact; '
      f'{sum(r["djvulibre_exact"] for r in rows)} also match DjVuLibre display pixels directly')
