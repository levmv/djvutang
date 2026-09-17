import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { prepare } from '../support/component-host.mjs';

const root = resolve(import.meta.dirname, '../..');
// An explicit output directory saves images for the external oracle runner.
const out = process.argv[2] && resolve(process.argv[2]);
if (out) mkdirSync(out, { recursive: true });
const bytes = readFileSync(resolve(root, 'zig-out/bin/djvutang.wasm'));
const module = await WebAssembly.compile(bytes);
assert.deepEqual(WebAssembly.Module.imports(module), []);
const core = (await WebAssembly.instantiate(module, {})).exports;
const hash = data => createHash('sha256').update(data).digest('hex');
const fixtures = JSON.parse(readFileSync(resolve(root, 'tests/fixtures/cases.json'), 'utf8'));
const results = [];
let cases = 0;
function open(path, limit = 64 * 1024 * 1024) {
  const input = readFileSync(resolve(root, path));
  const ptr = core.input_alloc(input.length, limit);
  assert(ptr > 0);
  new Uint8Array(core.memory.buffer, ptr, input.length).set(input);
  assert.equal(core.open(), 0);
}
function finish(work = 71) {
  let calls = 0;
  while (true) {
    const status = core.render_step(work);
    calls++;
    assert(calls < 1000000);
    if (status === 0) return calls;
    assert.equal(status, 1);
    assert.equal(core.result_len(), 0, 'partial output must not be exposed');
  }
}
function save(name, page, subsample, calls) {
  const rgba = new Uint8Array(core.memory.buffer, core.result_ptr(), core.result_len());
  cases++;
  if (out) {
    const width = core.result_width(), height = core.result_height();
    const rgb = Buffer.alloc(width * height * 3);
    for (let i = 0; i < width * height; i++) rgb.set(rgba.subarray(i * 4, i * 4 + 3), i * 3);
    const ppm = Buffer.concat([Buffer.from(`P6\n${width} ${height}\n255\n`), rgb]);
    writeFileSync(resolve(out, `${name}-${page}-${subsample}-wasm.ppm`), ppm);
    results.push({ name, page, subsample, width, height, sha256: hash(ppm), calls });
  }
  return hash(rgba);
}

function expectPpm(path) {
  const ppm = readFileSync(resolve(root, path));
  const end = ppm.indexOf('\n255\n');
  const dimensions = ppm.subarray(0, end).toString().trim().split(/\s+/).slice(-2).map(Number);
  assert.deepEqual([core.result_width(), core.result_height()], dimensions, path);
  const rgb = ppm.subarray(end + 5);
  const rgba = new Uint8Array(core.memory.buffer, core.result_ptr(), core.result_len());
  assert.equal(rgba.length / 4 * 3, rgb.length, path);
  for (let i = 0; i < rgba.length / 4; i++) {
    assert.deepEqual(rgba.subarray(i * 4, i * 4 + 3), new Uint8Array(rgb.subarray(i * 3, i * 3 + 3)), `${path}: pixel ${i}`);
    assert.equal(rgba[i * 4 + 3], 255);
  }
}

for (const { name, path, pages, source, reference, references } of fixtures) {
  open(path);
  assert.equal(core.page_count(), pages);
  for (let page = 0; page < pages; page++) {
    prepare(core, resolve(root, path), page);
    assert.equal(core.render_start(page, 1, 0), 0);
    const initial = save(name, page, 1, finish());
    const expected = references?.[page] ?? reference;
    if (expected) expectPpm(expected);
    if (source) {
      const pbm = readFileSync(resolve(root, source));
      const end = pbm.indexOf('\n', 3);
      const [width, height] = pbm.subarray(3, end).toString().split(' ').map(Number);
      assert.equal(core.result_width(), width);
      assert.equal(core.result_height(), height);
      const rgba = new Uint8Array(core.memory.buffer, core.result_ptr(), core.result_len());
      for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
        const ink = (pbm[end + 1 + y * Math.ceil(width / 8) + (x >> 3)] >> (7 - x % 8)) & 1;
        const i = (y * width + x) * 4, gray = ink ? 0 : 255;
        assert.deepEqual([...rgba.subarray(i, i + 4)], [gray, gray, gray, 255], `${name} at ${x},${y}`);
      }
    }
    for (const ss of [2, 3, 4]) {
      assert.equal(core.render_restart(ss, 0), 0);
      save(name, page, ss, finish());
    }
    assert.equal(core.render_restart(1, 0), 0);
    finish();
    assert.equal(hash(new Uint8Array(core.memory.buffer, core.result_ptr(), core.result_len())), initial);
    if (name === 'shared') assert.equal(core.dictionary_decodes(), 1);
  }
  core.close();
  assert.equal(core.live_bytes(), 0);
}

open('tests/fixtures/shared.djvu');
assert.equal(core.render_start(0, 1, 0), 0);
assert.equal(core.render_step(1), 1);
core.render_cancel();
assert.equal(core.result_len(), 0);
assert.equal(core.render_start(1, 1, 0), 0);
finish();
assert.equal(core.drop_dictionaries(), 0);
assert.equal(core.render_start(0, 1, 0), 0);
finish();
assert.equal(core.dictionary_decodes(), 2);
core.close();
assert.equal(core.live_bytes(), 0);

// A sized mask render owns temporary coverage rows. Cancel while those rows
// are active, then verify both the next image and the released working storage.
open('tests/fixtures/shared.djvu');
assert.equal(core.render_start_sized(0, 97, 61, 0, 0, 0, 0, 0), 0);
finish();
{
  const initial = hash(new Uint8Array(core.memory.buffer, core.result_ptr(), core.result_len()));
  const completed = core.live_bytes();
  for (const work of [1, 17, 127]) {
    assert.equal(core.render_restart_sized(97, 61, 0, 0, 0, 0, 0), 0);
    assert.equal(core.render_step(work), 1);
    assert.equal(core.result_len(), 0);
    assert(core.live_bytes() > completed, 'partial mask composition owns workspace');
    core.render_cancel();
    assert.equal(core.result_len(), 0);
    assert.equal(core.render_start_sized(0, 97, 61, 0, 0, 0, 0, 0), 0);
    finish();
    assert.equal(hash(new Uint8Array(core.memory.buffer, core.result_ptr(), core.result_len())), initial);
    assert.equal(core.live_bytes(), completed, 'completed renders release row workspace');
  }
}
core.close();
assert.equal(core.live_bytes(), 0);

for (const name of ['mmr-striped.djvu', 'mmr-palette-bg.djvu', 'palette-unmapped-bg.djvu',
  'progressive.djvu', 'pm44-progressive.iw4', 'jpeg-progressive.djvu']) {
  open(`tests/fixtures/${name}`);
  assert.equal(core.render_start(0, 1, 0), 0);
  assert.equal(core.render_step(17), 1);
  core.render_cancel();
  assert.equal(core.result_len(), 0);
  assert.equal(core.render_start(0, 1, 0), 0);
  finish();
  core.close();
  assert.equal(core.live_bytes(), 0);
}

for (const limit of [8192, 20000, 40000]) {
  open('tests/fixtures/color.djvu', limit);
  assert.equal(core.render_start(0, 1, 0), 0);
  let status = 1;
  for (let calls = 0; status === 1 && calls < 100000; calls++) status = core.render_step(512);
  assert.equal(status, 4, 'insufficient decode/reconstruction budget must fail');
  assert.equal(core.result_len(), 0);
  core.render_cancel();
  core.close();
  assert.equal(core.live_bytes(), 0);
}
// Coefficients, full RGB and output RGBA must fit together in this budget.
open('tests/fixtures/color.djvu', 60000);
assert.equal(core.render_start(0, 1, 0), 0);
finish();
expectPpm('tests/fixtures/color-expected.ppm');
assert(core.peak_bytes() <= 60000);
core.close();
assert.equal(core.live_bytes(), 0);
assert.equal(core.input_alloc(1024, 512), 0);
assert.equal(core.last_status(), 4);
core.close();
assert.equal(core.live_bytes(), 0);

for (const limit of [8192, 24000, 28000]) {
  open('tests/fixtures/jpeg-progressive.djvu', limit);
  assert.equal(core.render_start(0, 1, 0), 0);
  let status = 1;
  for (let calls = 0; status === 1 && calls < 100000; calls++) status = core.render_step(512);
  assert.equal(status, 4, `JPEG memory budget ${limit}`);
  assert.equal(core.result_len(), 0);
  core.close();
  assert.equal(core.live_bytes(), 0);
}

if (out) writeFileSync(resolve(out, 'wasm.json'), JSON.stringify({ results }, null, 2) + '\n');
console.log(`WASM rendering: ${cases} cases passed`);
