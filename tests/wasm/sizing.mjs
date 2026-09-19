import assert from 'node:assert/strict';
import { readFileSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { fitReference } from '../support/resample.mjs';
import { openCompoundReference } from '../support/compound-preview.mjs';
import { wavelets, packChunks, openProbe, finish as finishProbe, result, preview } from '../support/iw44-probe.mjs';
const root = resolve(import.meta.dirname, '../..');
const core = (await WebAssembly.instantiate(readFileSync(resolve(root, 'zig-out/bin/djvutang.wasm')))).instance.exports;
const native = process.argv.includes('--native');
const codec = await WebAssembly.compile(readFileSync(resolve(root, 'zig-out/bin/iw44-probe.wasm')));
function finish() {
  for (let i = 0; i < 100000; i++) {
    const status = core.render_step(8192);
    if (!status) return { width: core.result_width(), height: core.result_height(),
      rgba: new Uint8Array(core.memory.buffer, core.result_ptr(), core.result_len()).slice() };
    assert.equal(status, 1);
  }
  throw new Error('Work limit');
}
let compared = 0;
let extremeTiles = 0;
for (const name of ['plain', 'shared', 'rotated-color', 'palette', 'foreground', 'jpeg-progressive', 'mmr-foreground', 'tiny']) {
  const input = resolve(root, `tests/fixtures/${name}.djvu`);
  const bytes = readFileSync(input);
  const layer = name === 'rotated-color' ? wavelets(bytes) : null;
  const raw = layer ? await openProbe(codec, packChunks(layer.chunks), 32) : null;
  const compound = ['foreground', 'mmr-foreground'].includes(name)
    ? await openCompoundReference(codec, bytes, readFileSync(resolve(root, 'tests/fixtures/palette-mask.pbm'))) : null;
  // Extra small boxes straddle the independent BG/FG reduction boundaries.
  const boxes = compound ? [[19, 27], [111, 89], [8, 8], [5, 5], [2, 2], [1, 1]] : [[19, 27], [111, 89], [1, 1]];
  if (name === 'shared') boxes.push([160, 100], [100, 160]);
  if (raw) finishProbe(raw);
  const ptr = core.input_alloc(bytes.length, 64 << 20);
  assert(ptr); new Uint8Array(core.memory.buffer, ptr, bytes.length).set(bytes);
  assert.equal(core.open(), 0);
  for (let rotation = 0; rotation < 4; rotation++) {
    assert.equal(core.render_start(0, 1, rotation), 0);
    const original = finish();
    for (const [width, height] of boxes) {
      assert.equal(core.render_restart_sized(width, height, rotation, 0, 0, 0, 0), 0);
      const actual = finish();
      let expected = compound ? compound.render({ width, height }, rotation) : fitReference(original, { width, height });
      if (layer) {
        const turn = (layer.info.rotation + rotation) % 4;
        const bw = turn % 2 ? expected.height : expected.width;
        const bh = turn % 2 ? expected.width : expected.height;
        let reduction = 1;
        for (const candidate of [2, 4]) {
          if (bw * layer.layerReduction * candidate <= layer.info.width && bh * layer.layerReduction * candidate <= layer.info.height) reduction = candidate;
        }
        if (reduction > 1) {
          assert.equal(raw.reconstruct(reduction, 0, 0, 0, 0), 0);
          finishProbe(raw);
          expected = preview(result(raw), layer, reduction, { width, height }, rotation);
        }
      }
      assert.equal(actual.width, expected.width); assert.equal(actual.height, expected.height);
      const maxError = actual.rgba.reduce((max, value, i) => Math.max(max, Math.abs(value - expected.rgba[i])), 0);
      assert(maxError <= 1, `${name} turn=${rotation} box=${width}x${height}: ${maxError}`);
      if (native) {
        const output = resolve(root, 'tests/out/fit-native.ppm');
        const run = spawnSync(resolve(root, 'zig-out/bin/djvutang'),
          ['fit', input, output, '1', String(width), String(height), String(rotation)], { encoding: 'utf8' });
        assert.equal(run.status, 0, run.stderr);
        const ppm = readFileSync(output), rgb = ppm.subarray(ppm.indexOf('\n255\n') + 5);
        assert.equal(rgb.length * 4, actual.rgba.length * 3);
        for (let i = 0; i < rgb.length; i++) assert.equal(rgb[i], actual.rgba[Math.floor(i / 3) * 4 + i % 3]);
        rmSync(output);
      }
      const x = Math.floor(actual.width / 2), y = Math.floor(actual.height / 2);
      const w = actual.width - x, h = actual.height - y;
      assert.equal(core.render_restart_sized(width, height, rotation, x, y, w, h), 0);
      const tile = finish();
      for (let row = 0; row < h; row++) assert.deepEqual(tile.rgba.subarray(row * w * 4, (row + 1) * w * 4),
        actual.rgba.subarray(((y + row) * actual.width + x) * 4, ((y + row) * actual.width + x + w) * 4));
      const live = core.live_bytes();
      const transform = core.page_transform_sized(0, width, height, rotation, x, y, w, h);
      assert(transform); assert.equal(core.live_bytes(), live);
      const view = new DataView(core.memory.buffer, transform, 128);
      assert.equal(view.getUint32(16, true), actual.width); assert.equal(view.getUint32(20, true), actual.height);
      compared++;
    }
    // A tiny tile near the far edge of a huge enlargement exercises wide
    // coordinates and weights totaling exactly 2^32 without a huge allocation.
    const max = 0xffffffff;
    const transform = core.page_transform_sized(0, max, max, rotation, 0, 0, 0, 0);
    assert(transform);
    const view = new DataView(core.memory.buffer, transform, 128);
    const pageWidth = view.getUint32(16, true), pageHeight = view.getUint32(20, true);
    assert.equal(core.render_restart_sized(max, max, rotation, pageWidth - 2, pageHeight - 2, 2, 2), 0);
    const corner = finish();
    const expectedCorner = original.rgba.subarray(-4);
    for (let i = 0; i < 4; i++) assert.deepEqual(corner.rgba.subarray(i * 4, i * 4 + 4), expectedCorner);
    extremeTiles++;
  }
  assert.equal(core.render_restart_sized(0xffffffff, 0xffffffff, 0, 0, 0, 0, 0), 4);
  assert.equal(new TextDecoder().decode(new Uint8Array(core.memory.buffer, core.error_message_ptr(), core.error_message_len())),
    'LimitExceeded in render_restart: format or complexity limit');
  assert.equal(core.render_restart_sized(0, 30, 0, 0, 0, 0, 0), 7);
  assert.equal(core.render_restart_sized(30, 30, 0, 0, 0, 0, 1), 7);
  assert.equal(core.render_restart_sized(1, 1, 0, 0, 0, 0, 0), 0);
  assert.equal(core.render_step(1), name === 'tiny' ? 0 : 1);
  core.render_cancel(); assert.equal(core.result_len(), 0);
  core.close(); assert.equal(core.live_bytes(), 0);
  if (raw) { raw.close(); assert.equal(raw.live_bytes(), 0); }
  compound?.close();
}
console.log(`Sized rendering: ${compared} area/bilinear references and exact tiles, ${extremeTiles} extreme enlargement tiles${native ? ', native/WASM exact' : ''}.`);
