// Usage: node tests/wasm/regions.mjs [output-directory] [--native]
import assert from 'node:assert/strict';
import { readFileSync, mkdirSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { prepare } from '../support/component-host.mjs';

const root = resolve(import.meta.dirname, '../..');
const out = resolve(process.argv.slice(2).find(arg => arg !== '--native') ?? resolve(root, 'tests/out'));
const native = process.argv.includes('--native');
if (native) mkdirSync(out, { recursive: true });
const module = await WebAssembly.compile(readFileSync(resolve(root, 'zig-out/bin/djvutang.wasm')));
const core = (await WebAssembly.instantiate(module, {})).exports;
const fixtures = JSON.parse(readFileSync(resolve(root, 'tests/fixtures/cases.json'), 'utf8'));
function open(path) {
  const bytes = readFileSync(resolve(root, path));
  const ptr = core.input_alloc(bytes.length, 64 * 1024 * 1024);
  assert(ptr > 0);
  new Uint8Array(core.memory.buffer, ptr, bytes.length).set(bytes);
  assert.equal(core.open(), 0);
}
function finish() {
  for (let calls = 0; calls < 1_000_000; calls++) {
    const status = core.render_step(4096);
    if (status === 0) return snapshot();
    assert.equal(status, 1);
    assert.equal(core.result_len(), 0);
  }
  throw new Error('Work limit');
}
function snapshot() {
  return { x: core.result_x(), y: core.result_y(), width: core.result_width(), height: core.result_height(),
    pageWidth: core.result_page_width(), pageHeight: core.result_page_height(),
    rgba: new Uint8Array(core.memory.buffer, core.result_ptr(), core.result_len()).slice() };
}
function crop(full, region) {
  const rgba = new Uint8Array(region.width * region.height * 4);
  for (let y = 0; y < region.height; y++) {
    const start = ((region.y + y) * full.width + region.x) * 4;
    rgba.set(full.rgba.subarray(start, start + region.width * 4), y * region.width * 4);
  }
  return rgba;
}
function expectTile(tile, full, region) {
  assert.deepEqual({ x: tile.x, y: tile.y, width: tile.width, height: tile.height }, region);
  assert.equal(tile.pageWidth, full.width);
  assert.equal(tile.pageHeight, full.height);
  assert.deepEqual(tile.rgba, crop(full, region));
}
const coords = r => [r.x, r.y, r.width, r.height];
// Exercise each composition path. render.mjs covers the full format inventory;
// codec variants and container layouts do not need another geometry matrix.
const names = ['shared', 'rotated-color', 'chroma-half', 'compound', 'foreground',
  'mmr-striped', 'mmr-foreground', 'jpeg-compound', 'jpeg-background', 'jpeg-foreground', 'blank-page', 'thum'];
let cases = 0, tiles = 0;
for (const name of names) {
  const { path, pages } = fixtures.find(f => f.name === name);
  open(path);
  for (let page = 0; page < pages; page++) {
    prepare(core, resolve(root, path), page);
    for (const ss of [1, 2, 3, 4, 256]) for (let rotation = 0; rotation < 4; rotation++) {
      const before = core.live_bytes();
      const width = core.render_width(page, ss, rotation), height = core.render_height(page, ss, rotation);
      assert.equal(core.last_status(), 0);
      assert.equal(core.live_bytes(), before, 'geometry does not allocate');
      const corner = { x: Math.floor(width / 2), y: Math.floor(height / 2),
        width: width - Math.floor(width / 2), height: height - Math.floor(height / 2) };
      // Every configuration starts with a cold tile, including all INFO/user rotations.
      assert.equal(core.render_start_region(page, ss, rotation, ...coords(corner)), 0);
      const cold = finish();
      assert.equal(core.render_restart(ss, rotation), 0);
      const full = finish();
      assert.equal(full.width, width); assert.equal(full.height, height);
      expectTile(cold, full, corner);
      const assembled = new Uint8Array(full.rgba.length);
      const regions = [];
      const tw = Math.ceil(width / 3), th = Math.ceil(height / 3);
      for (let y = 0; y < height; y += th) for (let x = 0; x < width; x += tw) {
        regions.push({ x, y, width: Math.min(tw, width - x), height: Math.min(th, height - y) });
      }
      for (const region of regions.reverse()) {
        assert.equal(core.render_restart_region(ss, rotation, ...coords(region)), 0);
        const tile = finish();
        expectTile(tile, full, region);
        for (let y = 0; y < region.height; y++) {
          assembled.set(tile.rgba.subarray(y * region.width * 4, (y + 1) * region.width * 4),
            ((region.y + y) * width + region.x) * 4);
        }
      }
      assert.deepEqual(assembled, full.rgba);
      // An overlapping request must retain the same phase as the nonoverlapping grid.
      assert.equal(core.render_restart_region(ss, rotation, ...coords(corner)), 0);
      expectTile(finish(), full, corner);
      if (native) {
        const target = resolve(out, 'region-native.ppm');
        const run = spawnSync(resolve(root, 'zig-out/bin/djvutang'),
          ['region', resolve(root, path), target, page + 1, ss, rotation, ...coords(corner)].map(String),
          { encoding: 'utf8', timeout: 30000 });
        assert.equal(run.status, 0, run.stderr);
        const stats = JSON.parse(run.stdout);
        assert.equal(stats.x, corner.x); assert.equal(stats.y, corner.y);
        assert.equal(stats.page_width, width); assert.equal(stats.page_height, height);
        const ppm = readFileSync(target);
        const expected = Buffer.alloc(cold.rgba.length / 4 * 3);
        for (let p = 0; p < cold.rgba.length / 4; p++) expected.set(cold.rgba.subarray(p * 4, p * 4 + 3), p * 3);
        assert.deepEqual(ppm, Buffer.concat([Buffer.from(`P6\n${corner.width} ${corner.height}\n255\n`), expected]));
        rmSync(target);
      }
      cases++;
      tiles += regions.length;
    }
  }
  if (name === 'shared') assert.equal(core.dictionary_decodes(), 1);
  core.close(); assert.equal(core.live_bytes(), 0);
}

open('tests/fixtures/large-page.djvu');
assert.equal(core.render_start_region(0, 1, 0, 0, 0, 256, 256), 0);
const first = finish();
assert.deepEqual([first.pageWidth, first.pageHeight], [8192, 6144]);
for (let y = 0; y < 256; y++) for (let x = 0; x < 256; x++) {
  const value = x < 16 && y < 16 ? 0 : 255;
  assert.deepEqual([...first.rgba.subarray((y * 256 + x) * 4, (y * 256 + x) * 4 + 4)], [value, value, value, 255]);
}
const live = core.live_bytes(), peak = core.peak_bytes();
assert(peak < 8 * 1024 * 1024);
assert.equal(core.render_restart(1, 0), 4);
assert.equal(core.live_bytes(), live);
assert.deepEqual(snapshot(), first, 'failed growth preserves the completed tile');
for (const r of [[0, 0, 0, 1], [0, 6144, 1, 1], [8191, 0, 2, 1], [1, 1, 0xffffffff, 0xffffffff], [0xffffffff, 0, 2, 1]]) {
  assert.equal(core.render_restart_region(1, 0, ...r), 7);
  assert.deepEqual(snapshot(), first);
  assert.equal(core.live_bytes(), live);
}
for (let i = 0; i < 12; i++) {
  assert.equal(core.render_restart_region(1, 0, 7936, 5888, 256, 256), 0);
  const tile = finish();
  assert.equal(core.live_bytes(), live);
  for (let y = 0; y < 256; y++) for (let x = 0; x < 256; x++) {
    assert.equal(tile.rgba[(y * 256 + x) * 4], x >= 240 && y >= 240 ? 0 : 255);
  }
}
assert.equal(core.render_restart_region(3, 1, 0, 0, 64, 64), 0);
assert.equal(core.render_step(1), 1);
assert.equal(core.result_len(), 0);
core.render_cancel();
assert.equal(core.result_len(), 0);
assert.equal(core.render_start(0, 1, 0), 0);
let status = 1;
for (let calls = 0; status === 1 && calls < 100000; calls++) status = core.render_step(4096);
assert.equal(status, 4, 'cold full render also fails within the same 64 MiB budget');
assert.equal(core.result_len(), 0);
assert.equal(core.render_start_region(0, 1, 0, 0, 0, 256, 256), 0);
assert.deepEqual(finish().rgba, first.rgba);
core.close(); assert.equal(core.live_bytes(), 0);

console.log(`WASM regions: ${cases} cases, ${tiles} tiles passed${native ? ' (also matched native)' : ''}`);
