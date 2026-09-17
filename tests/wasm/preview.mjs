import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { wavelets, packChunks, openProbe, finish, result, preview } from '../support/iw44-probe.mjs';

const artifacts = process.argv[2] ?? 'zig-out/bin';
const production = await WebAssembly.compile(readFileSync(`${artifacts}/djvutang.wasm`));
const probe = await WebAssembly.compile(readFileSync(`${artifacts}/preview-probe.wasm`));
const codec = await WebAssembly.compile(readFileSync(`${artifacts}/iw44-probe.wasm`));
assert.deepEqual(WebAssembly.Module.imports(probe), []);
assert(!WebAssembly.Module.exports(production).some(e => e.name.startsWith('preview_')));

async function open(module, bytes, budget = 32 << 20) {
  const core = (await WebAssembly.instantiate(module, {})).exports;
  const ptr = core.input_alloc(bytes.length, budget);
  assert(ptr);
  new Uint8Array(core.memory.buffer, ptr, bytes.length).set(bytes);
  assert.equal(core.open(), 0);
  return core;
}

function render(core, work = 127) {
  for (let calls = 0; calls < 1_000_000; calls++) {
    const status = core.render_step(work);
    if (status === 0) return new Uint8Array(core.memory.buffer, core.result_ptr(), core.result_len()).slice();
    assert.equal(status, 1);
    assert.equal(core.result_len(), 0, 'partial images stay private');
  }
  throw new Error('Work limit');
}

for (const name of ['iw44-reduced-full', 'iw44-reduced-half', 'iw44-reduced-gray']) {
  const bytes = readFileSync(`tests/fixtures/${name}.djvu`), input = wavelets(bytes);
  const core = await open(probe, bytes), raw = await openProbe(codec, packChunks(input.chunks), 32);
  finish(raw);
  for (const reduction of [2, 4, 8, 16, 32]) for (let rotation = 0; rotation < 4; rotation++) {
    assert.equal(core.preview_start(0, 4, 4, rotation, reduction), 0);
    const actual = render(core);
    assert.equal(core.preview_reduction(0), reduction);
    assert.equal(core.preview_reduction(1), 0);
    assert.equal(core.preview_has_mask(), 0);
    assert.equal(core.preview_layer_dimension(0, 0), input.width);
    assert.equal(core.preview_layer_dimension(0, 1), input.height);
    assert.equal(core.preview_layer_dimension(1, 0), 0);
    assert.equal(core.preview_layer_dimension(2, 0), 0);
    assert.equal(core.preview_layer_dimension(0, 2), 0);
    assert.equal(raw.reconstruct(reduction, 0, 0, 0, 0), 0);
    finish(raw);
    const expected = preview(result(raw), input, reduction, { width: 4, height: 4 }, rotation);
    assert.deepEqual(actual, expected.rgba);
  }
  assert.equal(core.render_restart_sized(128, 128, 0, 0, 0, 0, 0), 0);
  const full = render(core);
  assert.equal(core.preview_reduction(0), 1);
  const publicCore = await open(production, bytes);
  assert.equal(publicCore.render_start_sized(0, 128, 128, 0, 0, 0, 0, 0), 0);
  assert.deepEqual(full, render(publicCore));
  // Small layers also reduce after a restart from cached full RGB. Compare with
  // the codec/host cell filter and a fresh public job at the same geometry.
  for (let rotation = 0; rotation < 4; rotation++) {
    for (const [edge, reduction] of [[32, 4], [33, 2], [64, 2], [65, 1], [128, 1], [256, 1], [1, 4]]) {
      assert.equal(publicCore.render_restart_sized(edge, edge, rotation, 0, 0, 0, 0), 0);
      const restarted = render(publicCore, 7);
      if (reduction > 1) {
        assert.equal(raw.reconstruct(reduction, 0, 0, 0, 0), 0);
        finish(raw);
        assert.deepEqual(restarted, preview(result(raw), input, reduction, { width: edge, height: edge }, rotation).rgba);
      } else {
        assert.equal(core.preview_start(0, edge, edge, rotation, 1), 0);
        assert.deepEqual(restarted, render(core));
      }
      assert.equal(publicCore.render_start_sized(0, edge, edge, rotation, 0, 0, 0, 0), 0);
      assert.deepEqual(render(publicCore), restarted);
    }
  }
  assert.equal(core.preview_start(0, 128, 128, 0, 8), 0);
  render(core);
  assert.equal(core.render_restart_sized(32, 32, 0, 3, 5, 7, 9), 0);
  const crop = render(core, 1);
  assert.equal(core.preview_reduction(0), 4);
  assert.equal(core.render_restart_sized(32, 32, 0, 0, 0, 0, 0), 0);
  const page = render(core);
  for (let y = 0; y < 9; y++) assert.deepEqual(crop.subarray(y * 7 * 4, (y + 1) * 7 * 4), page.subarray(((y + 5) * 32 + 3) * 4, ((y + 5) * 32 + 10) * 4));
  for (const instance of [core, raw, publicCore]) { instance.close(); assert.equal(instance.live_bytes(), 0); }
}

for (const name of ['preview-shared', 'compound', 'foreground', 'shared-layers', 'shared', 'mmr-foreground', 'mmr-palette-bg', 'jpeg-background', 'jpeg-foreground', 'jpeg-compound', 'jpeg-progressive']) {
  const bytes = readFileSync(`tests/fixtures/${name}.djvu`);
  const core = await open(probe, bytes), publicCore = await open(production, bytes);
  for (let page = 0; page < core.page_count(); page++) {
    assert.equal(core.preview_start(page, 3, 3, 1, 4), 0);
    assert.equal(publicCore.render_start_sized(page, 3, 3, 1, 0, 0, 0, 0), 0);
    assert.deepEqual(render(core), render(publicCore), name);
    assert.equal(publicCore.render_start(page, 1, 0), 0);
    const exact = render(publicCore);
    // Public restarts promote BG and FG independently, including either mixed
    // JPEG layer. Compare fresh jobs and rotated crops at the same fitted size.
    for (const edge of [8, 5, 2, 1, 65]) {
      assert.equal(publicCore.render_restart_sized(edge, edge, 1, 0, 0, 0, 0), 0);
      const full = render(publicCore, 7), width = publicCore.result_width(), height = publicCore.result_height();
      assert.equal(core.preview_start(page, edge, edge, 1, 4), 0);
      assert.deepEqual(render(core), full, `${name} promoted at ${edge}`);
      if (name === 'foreground' || name === 'mmr-foreground') {
        const expected = { 8: [2, 1], 5: [4, 1], 2: [4, 2], 1: [4, 4], 65: [1, 1] }[edge];
        assert.deepEqual([core.preview_reduction(0), core.preview_reduction(1)], expected);
      }
      const x = Math.floor(width / 2), y = Math.floor(height / 2), w = width - x, h = height - y;
      assert.equal(publicCore.render_restart_sized(edge, edge, 1, x, y, w, h), 0);
      const crop = render(publicCore, 1);
      for (let row = 0; row < h; row++) assert.deepEqual(crop.subarray(row * w * 4, (row + 1) * w * 4),
        full.subarray(((y + row) * width + x) * 4, ((y + row) * width + x + w) * 4));
    }
    assert.equal(publicCore.render_restart(1, 0), 0);
    assert.deepEqual(render(publicCore), exact, `${name} back to exact`);
    assert.equal(core.preview_has_mask(), name === 'jpeg-progressive' ? 0 : 1, name);
    assert.equal(core.preview_start(page, 3, 3, 1, 8), 0);
    const reduced = render(core, 7);
    assert(reduced.length);
    // Restarting changes grids using the retained coefficients, never a stale
    // raster. A new job must produce the same result at this output geometry.
    assert.equal(core.render_restart_sized(32, 32, 0, 0, 0, 0, 0), 0);
    const restarted = render(core);
    assert.equal(core.preview_start(page, 32, 32, 0, 8), 0);
    assert.deepEqual(render(core), restarted, name);
  }
  assert.equal(core.preview_start(0, 32, 32, 0, 3), 7);
  assert.equal(core.preview_start(0, 32, 32, 0, 4), 0);
  assert.equal(core.render_step(1), 1);
  core.render_cancel();
  assert.equal(core.result_len(), 0);
  for (const instance of [core, publicCore]) { instance.close(); assert.equal(instance.live_bytes(), 0); }
  assert.equal(core.preview_has_mask(), 0);
  assert.equal(core.preview_layer_dimension(0, 0), 0);
}
// A compact grid can itself exceed the raster cache: reuse strips, including
// reverse/vertical traversal and partial final cells at an odd INFO extent.
const large = await open(probe, readFileSync('tests/fixtures/iw44-regions.djvu'));
for (const rotation of [0, 1, 2, 3]) {
  assert.equal(large.preview_start(0, 256, 256, rotation, 2), 0);
  const full = render(large, 16384), width = large.result_width();
  assert.equal(large.preview_reduction(0), 2);
  assert.equal(large.render_restart_sized(256, 256, rotation, 3, 5, 17, 19), 0);
  const tile = render(large, 16384);
  for (let y = 0; y < 19; y++) assert.deepEqual(tile.subarray(y * 17 * 4, (y + 1) * 17 * 4), full.subarray(((y + 5) * width + 3) * 4, ((y + 5) * width + 20) * 4));
}
large.close(); assert.equal(large.live_bytes(), 0);
console.log('Full-document previews: automatic small-layer grids and RGB cache promotion, shared dictionaries/layers, masks, palettes, JPEG, independent cell filter, bounded strips, crops and cleanup.');
