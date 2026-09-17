import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { componentInfo, prepare, supply } from '../support/component-host.mjs';

const root = resolve(import.meta.dirname, '../..');
const fixture = (name) => resolve(root, 'tests/fixtures', name);
const module = await WebAssembly.compile(readFileSync(resolve(root, 'zig-out/bin/djvutang.wasm')));
const c = (await WebAssembly.instantiate(module, {})).exports;
function open(path, limit = 64 * 1024 * 1024) {
  const bytes = readFileSync(path),
    ptr = c.input_alloc(bytes.length, limit);
  assert(ptr > 0);
  new Uint8Array(c.memory.buffer, ptr, bytes.length).set(bytes);
  assert.equal(c.open(), 0);
}
function thumbnail(page) {
  assert.equal(c.thumbnail_start(page), 0);
  if (!c.thumbnail_present()) {
    assert.equal(c.result_len(), 0);
    return null;
  }
  assert.equal(c.result_ptr(), 0);
  let status = 1;
  for (let i = 0; status === 1 && i < 1000000; i++) status = c.render_step(2048);
  assert.equal(status, 0);
  const rgba = new Uint8Array(c.memory.buffer, c.result_ptr(), c.result_len());
  const rgb = Buffer.alloc((rgba.length / 4) * 3);
  for (let i = 0, j = 0; i < rgba.length; i += 4, j += 3) {
    assert.equal(rgba[i + 3], 255);
    rgb.set(rgba.subarray(i, i + 3), j);
  }
  return Buffer.concat([Buffer.from(`P6\n${c.result_width()} ${c.result_height()}\n255\n`), rgb]);
}
const sparse = [null, 'color', 'gray', null, 'gray', null];
const inline = ['color', 'gray', 'gray', 'color', null];
const scenarios = [
  { name: 'thumbnails.djvu', expected: sparse },
  { name: 'thumbnails-indirect/index.djvu', expected: sparse, loads: [1, 1, 0, 1, 1, 2], loadedPages: [0, 3, 5] },
  { name: 'thumbnails-inline.djvu', expected: inline },
  { name: 'thumbnails-inline-indirect/index.djvu', expected: inline, loads: [1, 1, 1, 2, 1], loadedPages: [0, 2, 3, 4] },
  { name: 'thumbnail-inline.djvu', expected: ['color'] },
  { name: 'thumbnail-inline-progressive.djvu', expected: ['color'] },
  { name: 'thumbnails.thum', expected: ['color', 'gray'] },
];
for (const { name, expected, loads: expectedLoads, loadedPages } of scenarios) {
  const path = fixture(name);
  open(path);
  assert.equal(c.page_count(), expected.length);
  const baseline = c.live_bytes();
  for (let round = 0; round < 2; round++) {
    const loads = [];
    for (let page = 0; page < expected.length; page++) {
      loads.push(prepare(c, path, page, 2));
      const actual = thumbnail(page);
      if (expected[page]) assert.deepEqual(actual, readFileSync(fixture(`thumbnail-${expected[page]}-expected.ppm`)));
      else assert.equal(actual, null);
      if (c.document_indirect()) {
        assert.equal(componentInfo(c, c.page_component(page)).loaded, loadedPages.includes(page), 'only fallback reads page files');
      }
    }
    assert.deepEqual(loads, expectedLoads ?? expected.map(() => 0));
    assert.equal(c.dictionary_decodes(), 0);
    assert.equal(c.drop_components(), 0);
    assert.equal(c.live_bytes(), baseline);
  }
  assert.equal(c.thumbnail_start(expected.length), 7);
  c.close();
  assert.equal(c.live_bytes(), 0);
}
open(fixture('thumbnails-djvused.djvu'));
for (const page of [0, 1]) assert.deepEqual(thumbnail(page), readFileSync(fixture('thumbnail-djvused-expected.ppm')));
c.close();
assert.equal(c.live_bytes(), 0);

open(fixture('thumbnails.djvu'));
const baseline = c.live_bytes();
const openingPeak = c.peak_bytes();
assert.equal(c.thumbnail_start(1), 0);
assert.equal(c.render_step(1), 1);
c.render_cancel();
assert.equal(c.thumbnail_present(), 0);
assert.equal(c.live_bytes(), baseline);
assert.deepEqual(thumbnail(1), readFileSync(fixture('thumbnail-color-expected.ppm')));
assert.equal(c.render_start(1, 1, 0), 0, 'page rendering replaces thumbnail state');
assert.equal(c.thumbnail_present(), 0);
assert.equal(thumbnail(0), null, 'absence clears the previous image job');
open(fixture('thumbnails.djvu'), openingPeak);
let status = c.thumbnail_start(1);
for (let i = 0; status === 0 || status === 1; i++) {
  assert(i < 10000);
  status = c.render_step(2048);
  if (status === 0) break;
}
assert.equal(status, 4);
assert.equal(c.result_len(), 0);
c.render_cancel();
assert.equal(c.live_bytes(), baseline);
c.close();
assert.equal(c.live_bytes(), 0);

open(fixture('thumbnails-indirect/index.djvu'));
const missing = c.next_missing(1, 2) - 1;
assert.equal(c.last_status(), 0);
assert.equal(c.thumbnail_start(1), 9);
assert.equal(supply(c, missing, readFileSync(fixture('plain.djvu'))), 2);
assert.equal(c.thumbnail_start(1), 9);
assert.equal(supply(c, missing, readFileSync(fixture('thumbnails-indirect/first.thumb'))), 0);
assert.deepEqual(thumbnail(1), readFileSync(fixture('thumbnail-color-expected.ppm')));
c.close();
assert.equal(c.live_bytes(), 0);

if (process.argv.includes('--native')) {
  const temp = mkdtempSync(join(tmpdir(), 'djvu-thumbnails-'));
  const cli = resolve(root, 'zig-out/bin/djvutang');
  const run = (path, page, output) =>
    spawnSync(cli, ['thumbnail', path, output, String(page)], { encoding: 'utf8', timeout: 15000 });
  try {
    for (const { name, expected } of scenarios)
      for (let page = 0; page < expected.length; page++) {
        const output = join(temp, 'page.ppm');
        writeFileSync(output, 'previous output');
        const result = run(fixture(name), page + 1, output);
        assert.equal(result.status, 0, result.stderr);
        if (expected[page])
          assert.deepEqual(readFileSync(output), readFileSync(fixture(`thumbnail-${expected[page]}-expected.ppm`)));
        else {
          assert.equal(JSON.parse(result.stdout), null);
          assert.equal(readFileSync(output, 'utf8'), 'previous output');
        }
      }
    const invalid = run(fixture('thumbnails.djvu'), 0, join(temp, 'invalid.ppm'));
    assert.notEqual(invalid.status, 0);
    assert.match(invalid.stderr, /InvalidArgument/);
    if (process.argv.includes('--oracle')) {
      // DjVuLibre 3.5.28 crashes on this THUM group containing JUNK. The color
      // group with JUNK uses the independent c44/ordinary IW44 reference above;
      // normal producer output and the clean gray group also use its thumbnail API.
      for (const [name, page, width, height, reference] of [
        ['thumbnails.djvu', 5, 9, 13, 'gray'],
        ['thumbnails-djvused.djvu', 1, 32, 24, 'djvused'],
        ['thumbnails-djvused.djvu', 2, 32, 24, 'djvused'],
        ['thumbnails-inline.djvu', 2, 9, 13, 'gray'],
      ]) {
        const output = join(temp, 'oracle.ppm');
        const oracle = spawnSync(
          'python3',
          [
            resolve(root, 'tests/oracle/thumbnails.py'),
            fixture(name),
            String(page),
            String(width),
            String(height),
            output,
          ],
          { encoding: 'utf8', timeout: 20000 },
        );
        assert.equal(oracle.status, 0, oracle.stderr);
        assert.deepEqual(readFileSync(output), readFileSync(fixture(`thumbnail-${reference}-expected.ppm`)));
      }
    }
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
}
console.log(
  'thumbnails: DIRM precedence, inline/progressive fallback, standalone THUM, lazy loading, cancellation and ownership passed',
);
