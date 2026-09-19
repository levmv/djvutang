// Complete metadata discovery through the import-free ABI, including sparse IO.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { componentInfo, supply } from '../support/component-host.mjs';

const root = resolve(import.meta.dirname, '../..');
const fixture = name => resolve(root, 'tests/fixtures', name);
const module = await WebAssembly.compile(readFileSync(resolve(root, 'zig-out/bin/djvutang.wasm')));
assert.deepEqual(WebAssembly.Module.imports(module), []);
const core = (await WebAssembly.instantiate(module, {})).exports;
const check = status => assert.equal(status, 0);
const copy = (ptr, bytes) => { assert(ptr); new Uint8Array(core.memory.buffer, ptr, bytes.length).set(bytes); };
const original = 0xffffffff;

function open(size, read, ranged = true, limit = 64 << 20) {
  if (!ranged) {
    copy(core.input_alloc(size, limit), read(0, size));
    check(core.open());
    return;
  }
  check(core.source_start(size, limit));
  for (;;) {
    const ptr = core.source_range(); check(core.last_status());
    if (!ptr) return;
    const view = new DataView(core.memory.buffer, ptr, 8);
    const bytes = read(view.getUint32(0, true), view.getUint32(4, true));
    copy(core.source_alloc(), bytes); check(core.source_commit());
  }
}

function scan(size, read, path, work = 31, wholeExternal = false) {
  check(core.metadata_start());
  for (let steps = 0; steps < 100000; steps++) {
    const status = core.metadata_step(work);
    if (status !== 1) {
      check(status);
      const result = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(
        new Uint8Array(core.memory.buffer, core.metadata_ptr(), core.metadata_len())));
      core.metadata_release();
      return result;
    }
    const ptr = core.metadata_range(); check(core.last_status());
    if (!ptr) continue;
    const view = new DataView(core.memory.buffer, ptr, 12);
    const component = view.getUint32(0, true), offset = view.getUint32(4, true), length = view.getUint32(8, true);
    let bytes, sourceSize = size;
    if (component === original) bytes = read(offset, length);
    else {
      const input = readFileSync(resolve(dirname(path), componentInfo(core, component).name));
      if (wholeExternal === true) { check(supply(core, component, input)); continue; }
      if (wholeExternal === 'during-range') check(supply(core, component, input));
      sourceSize = input.length;
      bytes = input.subarray(offset, offset + length);
    }
    assert.equal(bytes.length, length);
    copy(core.metadata_alloc(), bytes); check(core.metadata_commit(sourceSize));
  }
  throw new Error('Metadata work limit');
}

const files = ['metadata-book.djvu', 'metadata-context.djvu', 'metadata-none.djvu', 'metadata-links.djvu',
  'metadata-indirect/index.djvu', 'metadata-indirect/standalone.djvu', 'annotations-a.djvu', 'annotations-z.djvu',
  'annotations-split.djvu', 'annotations-recovered-split.djvu', 'annotations-utf8.djvu', 'annotations-empty.djvu',
  'annotations-shared.djvu', 'shared.djvu'];
for (const name of files) {
  const path = fixture(name), bytes = readFileSync(path);
  const read = (offset, length) => bytes.subarray(offset, offset + length);
  let expected;
  for (const ranged of [false, true]) {
    open(bytes.length, read, ranged);
    const result = scan(bytes.length, read, path, ranged ? 1 : 64);
    if (!ranged) expected = result;
    else assert.deepEqual(result, expected, name);
    assert.equal(core.dictionary_decodes(), 0);
    if (name === 'metadata-book.djvu') {
      assert.deepEqual(result.metadata.map(({ key, value }) => [key, value]), [
        ['Title', 'Shared'], ['Creator', 'Scanner'], ['Unknown', 'A\nB'], ['Title', 'Shared'],
        ['Title', 'Late'], ['title', 'lower'], ['Extra', 'same'], ['Extra', 'same'], ['Unreferenced', 'kept'],
      ]);
      assert.deepEqual(result.xmp.map(({ value }) => value), ['packet-one', 'packet-two']);
      assert.deepEqual(result.metadata.map(({ page }) => page), [null, null, null, null, 2, 2, 2, 2, null]);
      assert.deepEqual(result.xmp.map(({ page }) => page), [null, null]);
    }
    if (name === 'metadata-context.djvu') {
      assert.deepEqual(result.metadata.map(({ value, page }) => [value, page]), [
        ['start-middle-end', 0], ['A\nB', null], ['A\\nB', null], ['C:\\query', 2],
        ['Common-end', 3], ['Shared-end', null], ['Common-end', 4],
      ]);
    }
    if (['metadata-none.djvu', 'metadata-links.djvu', 'annotations-empty.djvu', 'shared.djvu'].includes(name)) {
      assert.deepEqual(result, { metadata: [], xmp: [] });
    }
    assert.deepEqual(Object.keys(result), ['metadata', 'xmp']);
    for (const [entries, keys] of [[result.metadata, ['key', 'value', 'page']], [result.xmp, ['value', 'page']]]) {
      for (const entry of entries) {
        assert.deepEqual(Object.keys(entry), keys);
        assert.equal(typeof entry.value, 'string');
        if (entry.page !== null) assert(Number.isInteger(entry.page) && entry.page >= 0);
      }
    }
    if (name === 'annotations-shared.djvu') {
      for (;;) {
        const missing = core.next_missing(0, 1); check(core.last_status());
        if (!missing) break;
        const { range } = componentInfo(core, missing - 1);
        check(supply(core, missing - 1, read(range.offset, range.length)));
      }
      check(core.render_start_sized(0, 90, 120, 0, 0, 0, 0, 0));
      let status; do { status = core.render_step(4096); } while (status === 1);
      check(status); assert(core.result_len());
    }
    core.close(); assert.equal(core.live_bytes(), 0);
  }
  if (name.startsWith('metadata-indirect/')) {
    for (const supplyMode of [true, 'during-range']) {
      open(bytes.length, read);
      assert.deepEqual(scan(bytes.length, read, path, 17, supplyMode), expected, 'component supply between scan steps');
      core.close(); assert.equal(core.live_bytes(), 0);
    }
  }
}

for (const name of ['metadata-cycle.djvu', 'metadata-bad-length.djvu', 'annotations-bad.djvu', 'annotations-bzz-bad.djvu']) {
  const bytes = readFileSync(fixture(name));
  for (const ranged of [false, true]) {
    open(bytes.length, (offset, length) => bytes.subarray(offset, offset + length), ranged);
    assert.throws(() => scan(bytes.length, (offset, length) => bytes.subarray(offset, offset + length), fixture(name)));
    assert.equal(core.last_status(), 2, name);
    assert.equal(core.metadata_ptr(), 0);
    core.metadata_release(); core.close(); assert.equal(core.live_bytes(), 0);
  }
}

const sample = readFileSync(fixture('metadata-book.djvu'));
open(sample.length, (offset, length) => sample.subarray(offset, offset + length));
check(core.metadata_start());
assert.equal(core.metadata_start(), 8);
assert.equal(core.metadata_step(1), 1);
assert(core.metadata_range());
core.metadata_cancel(); assert.equal(core.metadata_step(1), 5);
assert.equal(core.metadata_ptr(), 0);
core.metadata_release(); check(core.drop_components()); core.close(); assert.equal(core.live_bytes(), 0);

open(sample.length, (offset, length) => sample.subarray(offset, offset + length), false, 4096);
const beforeScan = core.live_bytes();
check(core.metadata_start());
let limited; do { limited = core.metadata_step(128); } while (limited === 1);
assert.equal(limited, 4);
assert.equal(core.metadata_ptr(), 0);
assert.equal(core.annotations_load(999), 7); // Resets the allocator's last denied request.
core.metadata_cancel(); // Cancellation must not replace the original failure.
assert.equal(core.metadata_step(1), 4, 'a failed scan retains its allocation failure');
const diagnostic = new TextDecoder().decode(new Uint8Array(core.memory.buffer, core.error_message_ptr(), core.error_message_len()));
assert.match(diagnostic, /^LimitExceeded in metadata_step: memory budget; requested \d+/);
core.metadata_release(); assert.equal(core.live_bytes(), beforeScan);
core.close(); assert.equal(core.live_bytes(), 0);

open(sample.length, (offset, length) => sample.subarray(offset, offset + length));
check(core.metadata_start()); assert.equal(core.metadata_step(1), 1);
const request = new DataView(core.memory.buffer, core.metadata_range(), 12);
const offset = request.getUint32(4, true), length = request.getUint32(8, true);
copy(core.metadata_alloc(), sample.subarray(offset, offset + length));
assert.equal(core.metadata_commit(sample.length - 1), 2, 'changed source size cannot confirm absence');
assert.equal(core.metadata_step(1), 2);
core.close(); assert.equal(core.live_bytes(), 0);

// A virtual file increases only skipped image bytes. Neither requested bytes nor
// peak live allocations may scale with that payload, including standalone opening.
const tail = Buffer.from('ANTa0000(metadata (Title "Sparse"))');
tail.writeUInt32BE(tail.length - 8, 4);
let reference;
for (const payload of [128, 1024 * 1024 * 1024]) {
  const prefix = Buffer.from('AT&TFORM0000DJVUSjbz0000');
  const size = prefix.length + payload + tail.length;
  prefix.writeUInt32BE(size - 12, 8); prefix.writeUInt32BE(payload, 20);
  let count = 0;
  const read = (offset, length) => {
    count += length;
    if (offset + length <= prefix.length) return prefix.subarray(offset, offset + length);
    const start = offset - prefix.length - payload;
    assert(start >= 0 && start + length <= tail.length, 'image payload was requested');
    return tail.subarray(start, start + length);
  };
  open(size, read, true, 128 * 1024);
  const result = scan(size, read);
  assert.equal(result.metadata[0].value, 'Sparse');
  const measurements = [count, core.peak_bytes()];
  if (reference) assert.deepEqual(measurements, reference);
  else reference = measurements;
  core.close(); assert.equal(core.live_bytes(), 0);
}
console.log(`Document metadata: ${files.length} fixtures, shared/late/context records, sparse IO, failure, cancellation and ownership passed`);
