import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join } from 'node:path';
import { wavelets, packChunks, openProbe, finish as finishCodec, result, preview as filter } from '../support/iw44-probe.mjs';

const wasm = process.argv[2] ?? 'zig-out/bin/djvutang.wasm';
const module = await WebAssembly.compile(readFileSync(wasm));
const bytes = readFileSync('tests/fixtures/iw44-regions.djvu');
const oracle = JSON.parse(readFileSync('tests/fixtures/iw44-regions.json'));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
async function open(limit) {
  const core = (await WebAssembly.instantiate(module, {})).exports;
  const ptr = core.input_alloc(bytes.length, limit * 1024 * 1024);
  assert(ptr);
  new Uint8Array(core.memory.buffer, ptr, bytes.length).set(bytes);
  assert.equal(core.open(), 0);
  return core;
}
function finish(core) {
  for (let calls = 0; calls < 200_000; calls++) {
    const status = core.render_step(8192);
    if (status === 0) return {
      width: core.result_width(), height: core.result_height(),
      rgba: new Uint8Array(core.memory.buffer, core.result_ptr(), core.result_len()).slice(),
    };
    assert.equal(status, 1);
    assert.equal(core.result_len(), 0);
  }
  throw new Error('Regional reconstruction work limit');
}

// Only the test host retains the full reference. The constrained instance must
// render previews and tiles without allocating a full RGB or scratch plane.
const referenceCore = await open(64);
assert.equal(referenceCore.render_start(0, 1, 0), 0);
const full = finish(referenceCore);
assert.deepEqual([full.width, full.height], [oracle.width, oracle.height]);
const rgb = new Uint8Array(full.width * full.height * 3);
for (let i = 0; i < rgb.length / 3; i++) rgb.set(full.rgba.subarray(i * 4, i * 4 + 3), i * 3);
assert.equal(hash(rgb), oracle.rgb_sha256);
referenceCore.close();
assert.equal(referenceCore.live_bytes(), 0);

const core = await open(16);
assert.equal(core.render_start_sized(0, 137, 181, 0, 0, 0, 0, 0), 0);
const preview = finish(core);
// Check r4 previews with the independent cell filter; exact tiles use the
// full-resolution RGB reference above.
const source = wavelets(bytes);
const codec = await openProbe(await WebAssembly.compile(readFileSync(join(dirname(wasm), 'iw44-probe.wasm'))), packChunks(source.chunks), 16);
finishCodec(codec);
assert.equal(codec.reconstruct(4, 0, 0, 0, 0), 0);
finishCodec(codec);
assert.deepEqual(preview, filter(result(codec), source, 4, { width: 137, height: 181 }));
codec.close(); assert.equal(codec.live_bytes(), 0);

for (const [x, y, width, height] of [[973, 1007, 333, 257], [0, 0, 1, 1], [oracle.width - 1, oracle.height - 1, 1, 1]]) {
  assert.equal(core.render_restart_region(1, 0, x, y, width, height), 0);
  const tile = finish(core);
  for (let row = 0; row < height; row++) {
    const start = ((y + row) * full.width + x) * 4;
    assert.deepEqual(tile.rgba.subarray(row * width * 4, (row + 1) * width * 4), full.rgba.subarray(start, start + width * 4));
  }
}
assert.equal(core.render_restart_sized(137, 181, 0, 0, 0, 0, 0), 0);
assert.deepEqual(finish(core), preview);
assert.equal(core.render_restart(1, 0), 4, 'failed full-size restart preserves the preview');
assert.deepEqual(new Uint8Array(core.memory.buffer, core.result_ptr(), core.result_len()), preview.rgba);

// Cancel during reconstruction of another strip.
assert.equal(core.render_restart_region(1, 0, 100, 100, 33, 35), 0);
assert.equal(core.render_step(1), 1);
core.render_cancel();
assert.equal(core.result_len(), 0);
core.close();
assert.equal(core.live_bytes(), 0);
console.log('Regional IW44: independent full RGB and automatic preview references, exact tiles/restarts, bounded memory, allocation failure and cancellation.');
