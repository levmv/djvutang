import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { componentInfo, supply } from '../support/component-host.mjs';
const root = resolve(import.meta.dirname, '../..');
const fixture = name => readFileSync(resolve(root, 'tests/fixtures', name));
const core = (await WebAssembly.instantiate(readFileSync(resolve(root, 'zig-out/bin/djvutang.wasm')))).instance.exports;
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
function openFull(bytes) {
  const ptr = core.input_alloc(bytes.length, 64 << 20);
  assert(ptr); new Uint8Array(core.memory.buffer, ptr, bytes.length).set(bytes);
  assert.equal(core.open(), 0);
}
function openSource(size, read, limit = 64 << 20) {
  assert.equal(core.source_start(size, limit), 0);
  for (let i = 0; i < 100000; i++) {
    const ptr = core.source_range();
    assert.equal(core.last_status(), 0);
    if (!ptr) return;
    const view = new DataView(core.memory.buffer, ptr, 8);
    const offset = view.getUint32(0, true), length = view.getUint32(4, true);
    const bytes = read(offset, length);
    assert.equal(bytes.length, length);
    const target = core.source_alloc();
    assert(target, `allocation status ${core.last_status()}`);
    new Uint8Array(core.memory.buffer, target, length).set(bytes);
    assert.equal(core.source_commit(), 0, `commit at ${offset}+${length}`);
  }
  throw new Error('Source work limit');
}
function prepare(bytes, page, scope = 1) {
  for (;;) {
    const missing = core.next_missing(page, scope); assert.equal(core.last_status(), 0);
    if (!missing) return;
    const { range } = componentInfo(core, missing - 1); assert(range);
    assert.equal(supply(core, missing - 1, bytes.subarray(range.offset, range.offset + range.length)), 0);
  }
}
function finish() {
  for (let i = 0; i < 100000; i++) {
    const status = core.render_step(8192);
    if (!status) return hash(new Uint8Array(core.memory.buffer, core.result_ptr(), core.result_len()));
    assert.equal(status, 1);
  }
  throw new Error('Render work limit');
}
function json(kind, ...args) {
  const status = core[`${kind}_load`](...args);
  if (status) return { error: status };
  try { return core[`${kind}_present`]() ? JSON.parse(new TextDecoder().decode(
    new Uint8Array(core.memory.buffer, core[`${kind}_ptr`](), core[`${kind}_len`]()))) : null; }
  finally { core[`${kind}_release`](); }
}
function snapshot(bytes, thumbnailsOnly = false) {
  const result = { outline: json('outline'), pages: [] };
  for (let page = 0; page < core.page_count(); page++) {
    const entry = {};
    if (!thumbnailsOnly) {
      prepare(bytes, page);
      assert.equal(core.render_start_sized(page, 37, 53, 1, 0, 0, 0, 0), 0);
      entry.image = finish();
      entry.annotations = json('annotations', page);
      const status = core.text_load(page);
      entry.text = status ? { error: status } : core.text_present() ? hash(new Uint8Array(core.memory.buffer, core.text_ptr(), core.text_len())) : null;
      core.text_release();
    }
    prepare(bytes, page, 2);
    assert.equal(core.thumbnail_start(page), 0);
    entry.thumbnail = core.thumbnail_present() ? finish() : null;
    result.pages.push(entry);
    assert.equal(core.drop_components(), 0);
  }
  return result;
}
function verify(bytes, label, thumbnailsOnly = false) {
  openFull(bytes);
  const expected = snapshot(bytes, thumbnailsOnly);
  core.close(); assert.equal(core.live_bytes(), 0);
  const reads = [];
  openSource(bytes.length, (offset, length) => { reads.push({ offset, length }); return bytes.subarray(offset, offset + length); });
  const components = Array.from({ length: core.component_count() }, (_, i) => componentInfo(core, i));
  for (const { range } of components) if (range) {
    assert(!reads.some(r => r.offset < range.offset + range.length && r.offset + r.length > range.offset + 12), `${label}: opening read page content`);
  }
  assert.deepEqual(snapshot(bytes, thumbnailsOnly), expected, label);
  core.close(); assert.equal(core.live_bytes(), 0);
}
for (const name of ['shared.djvu', 'reordered.djvu', 'shared-layers.djvu', 'annotations-shared.djvu', 'outline-late.djvu',
  'thumbnails.djvu', 'color.djvu', 'pm44-progressive.iw4', 'thumbnails.thum']) verify(fixture(name), name);
verify(fixture('thumbnails-inline.djvu'), 'inline thumbnail without loading its missing includes', true);

// Reuse our tiny compressed directory strings, assembling fresh containers in memory.
function bundle(version, alias = false) {
  const base = fixture('shared-layers.djvu');
  const n = base.readUInt16BE(25);
  const forms = Array.from({ length: n }, (_, i) => {
    const offset = base.readUInt32BE(27 + i * 4);
    return base.subarray(offset, offset + 8 + base.readUInt32BE(offset + 4));
  });
  const index = fixture(version === 0 ? 'indirect-v0/index.djvu' : 'indirect-zero-sizes/index.djvu');
  const compressed = index.subarray(27, 24 + index.readUInt32BE(20));
  const dirm = Buffer.alloc(3 + n * (version === 0 ? 7 : 4) + compressed.length);
  dirm[0] = 0x80 | version; dirm.writeUInt16BE(n, 1); compressed.copy(dirm, dirm.length - compressed.length);
  let cursor = 24 + dirm.length + (dirm.length & 1);
  const pieces = [];
  for (let i = n - 1; i >= 0; i--) {
    dirm.writeUInt32BE(cursor, 3 + i * (version === 0 ? 7 : 4));
    if (version === 0) dirm.writeUIntBE(forms[i].length, 7 + i * 7, 3);
    pieces.push(forms[i]); cursor += forms[i].length;
    if (forms[i].length & 1) { pieces.push(Buffer.alloc(1)); cursor++; }
  }
  if (alias) {
    dirm.writeUInt32BE(dirm.readUInt32BE(3), 3 + (n - 1) * (version === 0 ? 7 : 4));
    if (version === 0) dirm.writeUIntBE(forms[0].length, 7 + (n - 1) * 7, 3);
  }
  const header = Buffer.from('AT&TFORM0000DJVMDIRM0000');
  header.writeUInt32BE(dirm.length, 20);
  const tail = Buffer.from('JUNK0000x'); tail.writeUInt32BE(1, 4); // Final odd chunk without padding.
  const result = Buffer.concat([header, dirm, ...(dirm.length & 1 ? [Buffer.alloc(1)] : []), ...pieces, tail]);
  result.writeUInt32BE(result.length - 12, 8);
  return result;
}
for (const version of [0, 1]) for (const alias of [false, true]) verify(bundle(version, alias), `DIRM v${version}, zero sizes=${version === 1}, alias=${alias}`);

const unused = Buffer.concat([fixture('shared.djvu'), Buffer.from('FORM\0\0\0\0')]);
unused.writeUInt32BE(unused.length - 12, 8);
verify(unused, 'an unreferenced short FORM does not prevent reading pages');

// File length can exceed the input allocation limit. No large fixture or buffer.
const original = fixture('shared.djvu'), size = 0xffffffff;
const prefix = Buffer.from(original); prefix.writeUInt32BE(size - 12, 8);
const junk = Buffer.from('JUNK0000'); junk.writeUInt32BE(size - prefix.length - 8, 4);
let readBytes = 0;
openSource(size, (offset, length) => {
  readBytes += length;
  if (offset === prefix.length) { assert.equal(length, 8); return junk; }
  assert(offset + length <= prefix.length, 'must skip the large unused payload');
  return prefix.subarray(offset, offset + length);
}, 128 << 10);
assert(readBytes < original.length);
prepare(original, 1);
const otherPage = core.page_component(0);
assert.equal(componentInfo(core, otherPage).loaded, false);
assert.equal(core.render_start_sized(1, 40, 60, 0, 0, 0, 0, 0), 0); const first = finish();
assert.equal(core.drop_components(), 0);
prepare(original, 1);
assert.equal(core.render_start_sized(1, 40, 60, 0, 0, 0, 0, 0), 0); assert.equal(finish(), first);
core.close(); assert.equal(core.live_bytes(), 0);

// A failed transfer/open can be closed and followed by a successful open.
assert.equal(core.source_start(original.length, 64 << 20), 0);
let ptr = core.source_alloc(); assert(ptr);
new Uint8Array(core.memory.buffer, ptr, 16).fill(0);
assert.equal(core.source_commit(), 2);
core.close(); assert.equal(core.live_bytes(), 0);
openSource(original.length, (offset, length) => original.subarray(offset, offset + length));
core.close(); assert.equal(core.live_bytes(), 0);
console.log(`Range input: pixels and metadata, DIRM v0/v1, aliases, odd chunks, eviction; 4 GiB source opened with ${readBytes} bytes read.`);
