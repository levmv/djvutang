import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const module = await WebAssembly.compile(readFileSync('zig-out/bin/djvutang.wasm'));
const input = readFileSync('tests/fixtures/iw44-storage.djvu');
const oracle = JSON.parse(readFileSync('tests/fixtures/iw44-storage.json'));
const core = (await WebAssembly.instantiate(module, {})).exports;
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
let prefix = 0;
for (let position = 16; position < input.length;) {
  const size = input.readUInt32BE(position + 4);
  const end = position + 8 + size + (size & 1);
  if (input.toString('ascii', position, position + 4) === 'BG44') {
    const bytes = Buffer.from(input.subarray(0, end));
    bytes.writeUInt32BE(end - 12, 8);
    const ptr = core.input_alloc(bytes.length, 1024 * 1024);
    assert(ptr);
    new Uint8Array(core.memory.buffer, ptr, bytes.length).set(bytes);
    assert.equal(core.open(), 0);
    assert.equal(core.render_start(0, 1, 0), 0);
    let status, calls = 0;
    do {
      status = core.render_step(127);
      assert(++calls < 100_000);
    } while (status === 1);
    assert.equal(status, 0);
    assert.deepEqual([core.result_width(), core.result_height()], [oracle.width, oracle.height]);
    const rgba = new Uint8Array(core.memory.buffer, core.result_ptr(), core.result_len());
    const rgb = new Uint8Array(oracle.width * oracle.height * 3);
    for (let i = 0; i < rgb.length / 3; i++) rgb.set(rgba.subarray(i * 4, i * 4 + 3), i * 3);
    assert.equal(hash(rgb), oracle.rgb_sha256[prefix++]);
    core.close();
    assert.equal(core.live_bytes(), 0);
  }
  position = end;
}
assert.equal(prefix, oracle.rgb_sha256.length);
console.log('IW44 storage: dense progressive prefixes match independent RGB hashes.');
