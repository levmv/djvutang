import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { wavelets, packChunks, openProbe, finish, result, preview } from '../support/iw44-probe.mjs';

const module = await WebAssembly.compile(readFileSync('zig-out/bin/iw44-probe.wasm'));
assert.deepEqual(WebAssembly.Module.imports(module), []);
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
for (const fixture of JSON.parse(readFileSync('tests/fixtures/iw44-reduced.json'))) {
  const input = wavelets(readFileSync(`tests/fixtures/${fixture.name}.djvu`));
  const core = await openProbe(module, packChunks(input.chunks), 1);
  finish(core, 17);
  for (const level of fixture.levels) {
    assert.equal(core.reconstruct(level.reduction, 0, 0, 0, 0), 0);
    finish(core, 127);
    const image = result(core);
    assert.deepEqual([image.width, image.height], [level.width, level.height]);
    assert.equal(hash(image.rgb), level.rgb_sha256);
  }
  core.close();
  assert.equal(core.live_bytes(), 0);
}

const large = wavelets(readFileSync('tests/fixtures/iw44-regions.djvu'));
const packed = packChunks(large.chunks);
const small = await openProbe(module, packed, 8);
finish(small);
assert.equal(small.reconstruct(8, 0, 0, 0, 0), 0);
finish(small);
small.close();
assert.equal(small.live_bytes(), 0);
const core = await openProbe(module, packed, 16);
finish(core);
let first, firstHash;
for (const reduction of [8, 2, 32, 4, 16, 8]) {
  assert.equal(core.reconstruct(reduction, 0, 0, 0, 0), 0);
  finish(core);
  const full = result(core);
  if (reduction === 8) {
    if (first) assert.deepEqual(full, first);
    else { first = full; firstHash = hash(full.rgb); }
  }
  for (const [x, y, width, height] of [
    [0, 0, 1, 1], [full.width - 1, full.height - 1, 1, 1],
    [Math.floor(full.width / 2), Math.floor(full.height / 2), 3, 5],
  ]) {
    assert.equal(core.reconstruct(reduction, x, y, width, height), 0);
    finish(core, 17);
    const tile = result(core);
    for (let row = 0; row < height; row++) {
      const start = ((y + row) * full.width + x) * 3;
      assert.deepEqual(tile.rgb.subarray(row * width * 3, (row + 1) * width * 3), full.rgb.subarray(start, start + width * 3));
    }
  }
}
assert.equal(core.reconstruct(8, 0, 0, 0, 0), 0);
finish(core);
for (const bad of [0, 3, 64, 0xffffffff]) assert.equal(core.reconstruct(bad, 0, 0, 1, 1), 2);
assert.equal(core.reconstruct(1, 0, 0, 0, 0), 4);
assert.deepEqual(result(core), first, 'failed growth preserves the previous compact raster');
assert.equal(core.reconstruct(1, 973, 1007, 33, 35), 0);
finish(core);
assert.equal(core.reconstruct(8, 0, 0, 0, 0), 0);
finish(core);
assert.deepEqual(result(core), first);
assert.equal(core.reconstruct(4, 0, 0, 0, 0), 0);
assert.equal(core.step(1), 1);
assert.equal(core.result_len(), 0);
core.close();
assert.equal(core.live_bytes(), 0);
assert.equal(hash(first.rgb), firstHash, 'the host retains its owned copy');

// The final-filter helper must preserve the original odd extent, bottom-left
// cells, gamma and rotations. Its 5 x 3 page occupies a partial last row/column.
const image = { width: 3, height: 2, rgb: new Uint8Array([
  200, 200, 200, 200, 200, 200, 200, 200, 200,
  0, 0, 0, 0, 0, 0, 0, 0, 0,
]) };
const input = { info: { width: 5, height: 3, gamma: 22, rotation: 0 }, layerReduction: 1 };
assert.deepEqual([...preview(image, input, 2, { width: 1, height: 1 }).rgba], [67, 67, 67, 255]);
const bright = preview(image, { ...input, info: { ...input.info, gamma: 44 } }, 2, { width: 1, height: 1 });
assert.deepEqual([...bright.rgba], [52, 52, 52, 255]);
for (let rotation = 0; rotation < 4; rotation++) {
  assert.deepEqual([...preview(image, input, 2, { width: 1, height: 1 }, rotation).rgba], [67, 67, 67, 255]);
}
const horizontal = { ...image, rgb: new Uint8Array([
  0, 0, 0, 120, 120, 120, 240, 240, 240,
  0, 0, 0, 120, 120, 120, 240, 240, 240,
]) };
for (let rotation = 0; rotation < 4; rotation++) {
  const output = preview(horizontal, input, 2, { width: 2, height: 2 }, rotation);
  assert.deepEqual([output.width, output.height], rotation % 2 ? [1, 2] : [2, 1]);
  assert.deepEqual([...output.rgba], (rotation === 1 || rotation === 2 ? [168, 24] : [24, 168])
    .flatMap(value => [value, value, value, 255]));
}
console.log('Reduced IW44: independent power-of-two references, bounded grids, scale changes, exact regions and failure cleanup.');
