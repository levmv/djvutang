// Usage: node tests/wasm/text.mjs [output-directory] [--native] [--oracle]
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { zoneText, mapPoint, mapRect } from '../../web/decoder.mjs';

const root = resolve(import.meta.dirname, '../..');
const out = resolve(process.argv.slice(2).find(arg => !arg.startsWith('--')) ?? resolve(root, 'tests/out'));
const native = process.argv.includes('--native'), oracle = process.argv.includes('--oracle');
if (native) mkdirSync(out, { recursive: true });
const wasm = readFileSync(resolve(root, 'zig-out/bin/djvutang.wasm'));
const module = await WebAssembly.compile(wasm);
assert.deepEqual(WebAssembly.Module.imports(module), []);
const core = (await WebAssembly.instantiate(module, {})).exports;
const decoder = new TextDecoder('utf-8', { ignoreBOM: true });
const expected = JSON.parse(readFileSync(resolve(root, 'tests/fixtures/text-expected.json'), 'utf8'));
const names = ['', 'page', 'column', 'region', 'paragraph', 'line', 'word', 'character'];
function open(input, limit = 64 * 1024 * 1024, mutate = null) {
  const bytes = typeof input === 'string' ? readFileSync(resolve(root, input)) : input;
  mutate?.(bytes);
  const ptr = core.input_alloc(bytes.length, limit);
  assert(ptr > 0);
  new Uint8Array(core.memory.buffer, ptr, bytes.length).set(bytes);
  assert.equal(core.open(), 0);
}
function readText(page = 0) {
  assert.equal(core.text_load(page), 0);
  if (!core.text_present()) return null;
  const bytes = new Uint8Array(core.memory.buffer, core.text_ptr(), core.text_len()).slice().buffer;
  const count = core.text_zones_count();
  const view = new DataView(core.memory.buffer, core.text_zones_ptr(), count * 36);
  const zones = Array.from({ length: count }, (_, i) => {
    const words = Array.from({ length: 9 }, (_, j) => view.getUint32(i * 36 + j * 4, true));
    return { type: names[words[0]], parent: words[1] === 0xffffffff ? null : words[1],
      x: words[2] | 0, y: words[3] | 0, width: words[4] | 0, height: words[5] | 0,
      start: words[6], length: words[7], subtreeEnd: words[8] };
  });
  return { text: decoder.decode(bytes), bytes, hasReplacements: !!core.text_has_replacements(), zones };
}
const jsonText = text => text && { text: text.text, bytes: text.hasReplacements ? [...new Uint8Array(text.bytes)] : null,
  hasReplacements: text.hasReplacements, zones: text.zones };
function compareTree(text) {
  let next = 0;
  const walk = (source, parent = null) => {
    const index = next++, z = text.zones[index];
    assert.equal(z.type, source.kind); assert.equal(z.parent, parent);
    for (const name of ['x', 'y', 'width', 'height']) assert.equal(z[name], source.bounds[name]);
    if (Array.isArray(source.children)) for (const child of source.children) walk(child, index);
    else assert.equal(zoneText(text, z), source.children + (z.type === 'word' ? ' ' : ''));
    assert.equal(z.subtreeEnd, next);
  };
  walk(expected.tree);
  assert.equal(next, text.zones.length);
  assert.equal(text.text, expected.text);
}
function finish() {
  for (let calls = 0; calls < 1000000; calls++) {
    const status = core.render_step(4096);
    if (status === 0) return new Uint8Array(core.memory.buffer, core.result_ptr(), core.result_len()).slice();
    assert.equal(status, 1);
  }
  throw new Error('Work limit');
}
function geometry(ss, rotation, region = null) {
  const before = core.live_bytes();
  const ptr = region ? core.page_transform_region(0, ss, rotation, ...region) : core.page_transform(0, ss, rotation);
  assert(ptr > 0); assert.equal(core.last_status(), 0); assert.equal(core.live_bytes(), before);
  const view = new DataView(core.memory.buffer, ptr, 128);
  return { x: view.getUint32(0, true), y: view.getUint32(4, true), width: view.getUint32(8, true), height: view.getUint32(12, true),
    pageWidth: view.getUint32(16, true), pageHeight: view.getUint32(20, true), rotation: view.getUint32(24, true),
    matrix: Array.from({ length: 6 }, (_, i) => view.getFloat64(32 + i * 8, true)),
    inverse: Array.from({ length: 6 }, (_, i) => view.getFloat64(80 + i * 8, true)) };
}
let cases = 0, transforms = 0;
for (const name of ['text-a', 'text-z', 'text-rotated', 'text-only', 'text-empty', 'unicode-text', 'plain', 'text-recovered-a', 'text-recovered-z']) {
  const path = `tests/fixtures/${name}.djvu`;
  open(path);
  const before = core.live_bytes();
  const text = readText();
  if (name === 'plain') assert.equal(text, null);
  else if (name === 'text-empty') { assert.equal(text.text, ''); assert.equal(text.zones.length, 0); }
  else if (name === 'text-only') {
    assert.equal(text.text, '\ufeffA\0Ж\r\nB\x0bC\x1dD\x1eE\x1f🙂');
    assert.equal(zoneText(text, { start: 0, length: 3 }), '\ufeff');
    assert.equal(text.zones.length, 0);
  } else if (name === 'unicode-text') {
    assert.equal(text.text, 'AЖB'); assert.equal(zoneText(text, text.zones[1]), 'Ж');
  } else if (name.startsWith('text-recovered-')) {
    const recovered = JSON.parse(readFileSync(resolve(root, 'tests/fixtures/text-recovered.json')));
    assert.equal(text.hasReplacements, true);
    assert.equal(text.text, recovered.text);
    assert.deepEqual([...new Uint8Array(text.bytes)], recovered.bytes);
    assert.equal(zoneText(text, text.zones[5]), '�Ж� ');
    assert.equal(zoneText(text, text.zones[9]), '����');
    assert.equal(zoneText(text, text.zones[11]), '漢字 ');
    assert.equal(text.zones[9].start, 8); assert.equal(text.zones[9].length, 4);
  } else compareTree(text);
  if (text && !name.startsWith('text-recovered-')) assert.equal(text.hasReplacements, false);
  if (native) {
    const run = spawnSync(resolve(root, 'zig-out/bin/djvutang'), ['text', resolve(root, path)], { encoding: 'utf8', timeout: 30000 });
    assert.equal(run.status, 0, run.stderr);
    assert.deepEqual(JSON.parse(run.stdout), jsonText(text));
  }
  if (oracle && ['text-a', 'text-z', 'text-rotated'].includes(name)) {
    const run = spawnSync('djvused', ['-u', resolve(root, path), '-e', 'select 1; print-txt'], { timeout: 30000 });
    assert.equal(run.status, 0, run.stderr.toString());
    assert.deepEqual(run.stdout, readFileSync(resolve(root, 'tests/fixtures/text-oracle.sexp')));
  }
  const live = core.live_bytes();
  for (let i = 0; i < 5; i++) {
    assert.deepEqual(readText(), text);
    assert.equal(core.live_bytes(), live);
  }
  core.text_release(); assert.equal(core.live_bytes(), before);
  assert.equal(core.text_present(), 0);
  assert.equal(core.render_start(0, 1, 0), 0);
  assert.equal(core.render_step(1), 1);
  assert.deepEqual(readText(), text, 'text read must not cancel the active image');
  core.text_release(); finish();
  if (['text-z', 'text-rotated'].includes(name)) {
    const bitmap = readFileSync(resolve(root, 'tests/fixtures/text-mask.pbm')).subarray('P4\n101 79\n'.length);
    for (const ss of [1, 2, 3, 4, 256]) for (let rotation = 0; rotation < 4; rotation++) {
      const full = geometry(ss, rotation);
      const x = Math.floor(full.width / 3), y = Math.floor(full.height / 3);
      const region = [x, y, full.width - x, full.height - y];
      const g = geometry(ss, rotation, region);
      assert.deepEqual([g.x, g.y, g.width, g.height], region);
      assert.equal(core.render_restart_region(ss, rotation, ...region), 0);
      const rgba = finish();
      for (let y = 0; y < g.height; y++) for (let x = 0; x < g.width; x++) {
        const center = mapPoint(g.inverse, { x: x + 0.5, y: y + 0.5 });
        const left = Math.round(center.x - ss / 2), top = Math.round(center.y - ss / 2);
        let ink = 0;
        for (let dy = 0; dy < ss; dy++) for (let dx = 0; dx < ss; dx++) {
          const sx = left + dx, sy = top + dy;
          if (sx >= 0 && sy >= 0 && sx < 101 && sy < 79) ink += (bitmap[sy * 13 + Math.floor(sx / 8)] >> (7 - sx % 8)) & 1;
        }
        const gray = 255 - Math.floor((ink * 255 + ss * ss / 2) / (ss * ss));
        assert.equal(rgba[(y * g.width + x) * 4], gray);
      }
      for (const zone of text.zones) {
        const a = mapRect(full.matrix, zone), b = mapRect(g.matrix, zone);
        assert(Math.abs(a.x - x - b.x) < 1e-9); assert(Math.abs(a.y - y - b.y) < 1e-9);
        assert(Math.abs(a.width - b.width) < 1e-9); assert(Math.abs(a.height - b.height) < 1e-9);
        const point = mapPoint(g.inverse, mapPoint(g.matrix, zone));
        assert(Math.abs(point.x - zone.x) < 1e-9); assert(Math.abs(point.y - zone.y) < 1e-9);
      }
      transforms++;
    }
  }
  core.close(); assert.equal(core.live_bytes(), 0);
  if (text) assert.equal(decoder.decode(text.bytes), text.text, 'snapshot outlives close');
  cases++;
}

// Independent TextDecoder oracle over malformed leads, every second byte and
// deterministic noise. Generated output only; no heavyweight fixture is stored.
{
  const parts = [];
  for (let byte = 0; byte < 256; byte++) parts.push(Buffer.from([byte, 0x41]));
  for (const lead of [0xc2, 0xdf, 0xe0, 0xe1, 0xed, 0xef, 0xf0, 0xf4]) {
    for (let byte = 0; byte < 256; byte++) parts.push(Buffer.from([lead, byte, 0x80, 0x80, 0x41]));
  }
  let state = 0x55544638;
  const noise = Buffer.alloc(4096);
  for (let i = 0; i < noise.length; i++) { state ^= state << 13; state ^= state >>> 17; state ^= state << 5; noise[i] = state & 255; }
  parts.push(noise, Buffer.from([0xf0, 0x9f, 0x92]));
  const bytes = Buffer.concat(parts), length = Buffer.alloc(3);
  length.writeUIntBE(bytes.length, 0, 3);
  const chunk = (tag, payload) => {
    const out = Buffer.alloc(8 + payload.length + payload.length % 2);
    out.write(tag); out.writeUInt32BE(payload.length, 4); payload.copy(out, 8); return out;
  };
  const encoded = Buffer.concat([Buffer.from('AT&T'), chunk('FORM', Buffer.concat([
    Buffer.from('DJVU'), chunk('INFO', Buffer.from('0011000d18002c011601', 'hex')), chunk('TXTa', Buffer.concat([length, bytes])),
  ]))]);
  open(encoded);
  const text = readText();
  assert.deepEqual(new Uint8Array(text.bytes), new Uint8Array(bytes));
  assert.equal(text.hasReplacements, true);
  assert.equal(text.text, decoder.decode(bytes));
  if (native) {
    const file = resolve(out, 'text-encoding.djvu');
    writeFileSync(file, encoded);
    const run = spawnSync(resolve(root, 'zig-out/bin/djvutang'), ['text', file], { encoding: 'utf8', timeout: 30000 });
    assert.equal(run.status, 0, run.stderr);
    assert.deepEqual(JSON.parse(run.stdout), jsonText(text));
  }
  core.close(); assert.equal(core.live_bytes(), 0);
}

open('tests/fixtures/bad-text.djvu');
assert.equal(core.render_start(0, 1, 0), 0); assert.equal(core.render_step(1), 1);
const before = core.live_bytes();
assert.equal(core.text_load(0), 2); assert.equal(core.text_present(), 0); assert.equal(core.live_bytes(), before);
finish();
open('tests/fixtures/text-z.djvu', undefined, bytes => bytes.write('BGzz', bytes.indexOf('Sjbz')));
assert.equal(core.render_start(0, 1, 0), 3); compareTree(readText());
core.close(); assert.equal(core.live_bytes(), 0);
open('tests/fixtures/text-z.djvu', 2048);
const low = core.live_bytes();
assert.equal(core.text_load(0), 4); assert.equal(core.text_present(), 0); assert.equal(core.live_bytes(), low);
core.close(); assert.equal(core.live_bytes(), 0);
console.log(`WASM text: ${cases} fixtures, ${transforms} transforms passed`);
