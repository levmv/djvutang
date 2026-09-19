// Usage: node tests/wasm/annotations.mjs [--native] [--oracle]
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { prepare } from '../support/component-host.mjs';

const root = resolve(import.meta.dirname, '../..');
const fixture = name => resolve(root, 'tests/fixtures', name);
const native = process.argv.includes('--native'), oracle = process.argv.includes('--oracle');
const module = await WebAssembly.compile(readFileSync(resolve(root, 'zig-out/bin/djvutang.wasm')));
assert.deepEqual(WebAssembly.Module.imports(module), []);
const core = (await WebAssembly.instantiate(module, {})).exports;
const utf8 = new TextDecoder('utf-8', { fatal: true });
function open(bytes, limit = 64 * 1024 * 1024) {
  const ptr = core.input_alloc(bytes.length, limit);
  assert(ptr > 0);
  new Uint8Array(core.memory.buffer, ptr, bytes.length).set(bytes);
  assert.equal(core.open(), 0);
}
function read(page = 0) {
  assert.equal(core.annotations_load(page), 0);
  return core.annotations_present() ? JSON.parse(utf8.decode(new Uint8Array(core.memory.buffer, core.annotations_ptr(), core.annotations_len()))) : null;
}
const files = ['annotations-a.djvu', 'annotations-z.djvu', 'annotations-split.djvu',
  ...Array.from({ length: 4 }, (_, i) => `annotations-rot${i}.djvu`), 'annotations-legacy.djvu',
  'annotations-empty.djvu', 'annotations-shared.djvu', 'annotations-indirect/index.djvu', 'text-z.djvu',
  'annotations-utf8.djvu', 'annotations-recovered-a.djvu', 'annotations-recovered-z.djvu', 'annotations-recovered-split.djvu'];
let pages = 0;
for (const name of files) {
  open(readFileSync(fixture(name)));
  for (let page = 0; page < core.page_count(); page++) {
    prepare(core, fixture(name), page);
    const before = core.live_bytes();
    const data = read(page);
    if (data) {
      if (name.startsWith('annotations-recovered-')) {
        assert.equal(data.hasReplacements, true);
        const raw = readFileSync(fixture('annotations-recovered.raw'));
        assert.deepEqual(data.bytes, [...raw]);
        assert.equal(data.source, new TextDecoder('utf-8', { ignoreBOM: true }).decode(raw));
        assert.equal(data.metadata.find(e => e.key === 'Title').value, 'A�B');
        assert.equal(data.metadata.find(e => e.key === 'Escaped').value, '�X�');
        assert.equal(data.areas.length, 1);
        assert.equal(data.areas[0].comment, 'C�D');
        const span = data.expressions[data.areas[0].expression];
        assert.deepEqual(Buffer.from(data.bytes).subarray(span.start, span.start + span.length), Buffer.from('(maparea "#1" "C\xc2D" (rect 5 7 23 11))', 'latin1'));
      } else if (name === 'annotations-utf8.djvu') {
        assert.equal(data.hasReplacements, true);
        assert.equal(data.bytes, null, 'valid source preserves octal escape bytes');
        assert.equal(data.metadata[0].value, '�');
      } else { assert.equal(data.hasReplacements, false); assert.equal(data.bytes, null); }
      const copy = JSON.stringify(data);
      core.annotations_release();
      assert.equal(core.live_bytes(), before);
      assert.equal(core.annotations_present(), 0);
      assert.equal(JSON.stringify(read(page)), copy);
      core.annotations_release();
      assert.equal(core.live_bytes(), before);
    }
    if (native) {
      const result = spawnSync(resolve(root, 'zig-out/bin/djvutang'), ['annotations', fixture(name), String(page + 1)], { encoding: 'utf8' });
      assert.equal(result.status, 0, result.stderr);
      assert.deepEqual(JSON.parse(result.stdout), data);
    }
    pages++;
  }
  core.close();
  assert.equal(core.live_bytes(), 0);
}
for (const name of ['annotations-bad', 'annotations-bzz-bad']) {
  open(readFileSync(fixture(`${name}.djvu`)));
  assert.equal(core.render_start(0, 1, 0), 0);
  assert.equal(core.render_step(1), 1);
  assert.equal(core.annotations_load(0), 2);
  assert.equal(core.annotations_present(), 0);
  let status; do { status = core.render_step(4096); } while (status === 1);
  assert.equal(status, 0);
  if (native) {
    const result = spawnSync(resolve(root, 'zig-out/bin/djvutang'), ['annotations', fixture(`${name}.djvu`)], { encoding: 'utf8' });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /InvalidData/);
  }
  core.close(); assert.equal(core.live_bytes(), 0);
}
open(readFileSync(fixture('annotations-a.djvu')));
assert.equal(core.render_start(0, 1, 0), 0);
assert.equal(core.render_step(1), 1);
const data = read();
assert.equal(core.text_load(0), 0);
assert.equal(core.annotations_present(), 1);
assert.equal(core.annotations_load(999), 7);
assert.equal(core.annotations_present(), 0);
let status; do { status = core.render_step(4096); } while (status === 1);
assert.equal(status, 0);
assert.equal(data.areas[0].comment, 'Quote: "; slash: \\; octal: α');
core.close(); assert.equal(core.live_bytes(), 0);
// The budget covers parsing and JSON serialization, and denial releases both.
open(readFileSync(fixture('annotations-a.djvu')), 12 * 1024);
const before = core.live_bytes();
assert.equal(core.annotations_load(0), 4);
assert.equal(core.live_bytes(), before);
const message = new TextDecoder().decode(new Uint8Array(core.memory.buffer, core.error_message_ptr(), core.error_message_len()));
assert.match(message, /^LimitExceeded in annotations_load: memory budget;/);
assert(Number(message.match(/live (\d+)/)[1]) > before, 'diagnostic retains memory freed during cleanup');
core.close(); assert.equal(core.live_bytes(), 0);

if (oracle) {
  // Parse the external tool's normalized/merged output on the same INFO page;
  // semantic results must survive its independent compression/string rewriting.
  const semantic = ({ source, bytes, hasReplacements, chunks, expressions, legacyEscapes, areas, metadata, ...rest }) => ({
    ...rest, areas: areas.map(({ expression, ...area }) => area), metadata: metadata.map(({ expression, ...entry }) => entry),
  });
  const iffChunk = (tag, payload) => {
    const bytes = Buffer.alloc(8 + payload.length + payload.length % 2);
    bytes.write(tag); bytes.writeUInt32BE(payload.length, 4); payload.copy(bytes, 8); return bytes;
  };
  for (const [name, command] of [['annotations-z.djvu', 'print-ant'], ['annotations-shared.djvu', 'print-merged-ant'], ['annotations-legacy.djvu', 'print-ant']]) {
    const bytes = readFileSync(fixture(name));
    open(bytes); const expected = semantic(read());
    const result = spawnSync('djvused', ['-u', fixture(name), '-e', `select 1; ${command}`]);
    assert.equal(result.status, 0, result.stderr?.toString());
    const base = readFileSync(fixture('annotations-a.djvu'));
    const infoLength = base.readUInt32BE(20);
    const page = Buffer.concat([Buffer.from('AT&T'), iffChunk('FORM', Buffer.concat([
      Buffer.from('DJVU'), iffChunk('INFO', base.subarray(24, 24 + infoLength)), iffChunk('ANTa', result.stdout),
    ]))]);
    open(page);
    assert.deepEqual(semantic(read()), expected);
    core.close(); assert.equal(core.live_bytes(), 0);
  }
}
console.log(`WASM annotations: ${pages} pages passed`);
