// Usage: node tests/wasm/outline.mjs [--native] [--oracle]
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { prepare } from '../support/component-host.mjs';

const root = resolve(import.meta.dirname, '../..');
const fixture = name => resolve(root, 'tests/fixtures', name);
const native = process.argv.includes('--native'), oracle = process.argv.includes('--oracle');
const expected = JSON.parse(readFileSync(fixture('outline-expected.json'), 'utf8'));
const module = await WebAssembly.compile(readFileSync(resolve(root, 'zig-out/bin/djvutang.wasm')));
assert.deepEqual(WebAssembly.Module.imports(module), []);
const core = (await WebAssembly.instantiate(module, {})).exports;
const utf8 = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });
const kinds = ['none', 'page', 'url', 'options', 'unresolved'];
function open(name, limit = 64 * 1024 * 1024) {
  const bytes = readFileSync(fixture(name));
  const ptr = core.input_alloc(bytes.length, limit);
  assert(ptr > 0); new Uint8Array(core.memory.buffer, ptr, bytes.length).set(bytes);
  assert.equal(core.open(), 0);
}
function outline() {
  assert.equal(core.outline_load(), 0);
  return core.outline_present() ? JSON.parse(utf8.decode(new Uint8Array(core.memory.buffer, core.outline_ptr(), core.outline_len()))) : null;
}
function link(href, from = null) {
  const bytes = new TextEncoder().encode(href), ptr = core.link_alloc(bytes.length);
  assert(ptr > 0); new Uint8Array(core.memory.buffer, ptr, bytes.length).set(bytes);
  try {
    const result = core.link_resolve(from ?? 0xffffffff);
    assert(result > 0, `link resolve status ${core.last_status()}`);
    const view = new DataView(core.memory.buffer, result, 8), page = view.getUint32(4, true);
    return { kind: kinds[view.getUint32(0, true)], page: page === 0xffffffff ? null : page };
  } finally { core.link_release(); }
}
function cli(...args) {
  const result = spawnSync(resolve(root, 'zig-out/bin/djvutang'), args, { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}
const names = ['outline.djvu', 'outline-indirect/index.djvu', 'outline-single.djvu', 'outline-late.djvu', 'outline-djvused.djvu', 'outline-oracle.djvu', 'outline-empty.djvu', 'text-z.djvu'];
for (const name of names) {
  open(name);
  const before = core.live_bytes();
  const data = outline();
  assert.deepEqual(data, name === 'text-z.djvu' ? null : name === 'outline-empty.djvu' ? { entries: [] } : expected, name);
  if (native) assert.deepEqual(cli('outline', fixture(name)), data, name);
  core.outline_release(); assert.equal(core.live_bytes(), before);
  assert.deepEqual(outline(), data);
  assert.equal(core.drop_components(), 0);
  if (data) assert.deepEqual(JSON.parse(utf8.decode(new Uint8Array(core.memory.buffer, core.outline_ptr(), core.outline_len()))), data);
  core.close(); assert.equal(core.live_bytes(), 0);
  if (data?.entries.length) assert.equal(data.entries[0].title, 'Contents α🙂');
}
open('outline-strings.djvu');
assert.deepEqual(outline().entries, [{ title: '\ufeffA\0B\n"\\α', href: '#page-a\0', parent: null, subtreeEnd: 1 }]);
core.close(); assert.equal(core.live_bytes(), 0);
const cases = [
  ['', null, 'none', null], ['#1', null, 'page', 0], ['#2', null, 'page', 2], ['#3', null, 'page', 1],
  ['#+1', null, 'page', 3], ['#+2', null, 'unresolved', null], ['#+2', 4, 'page', 6], ['#-2', 0, 'unresolved', null],
  ['#Repeat', 3, 'page', 5], ['#Repeat', 6, 'page', 0], ['#Приложение α', null, 'page', 4],
  ['#page%20e', null, 'page', 5], ['#file%20e.djvu', null, 'unresolved', null], ['#dup.djvu', null, 'unresolved', null],
  ['#shared', null, 'unresolved', null], ['#sheet b.djvu', null, 'page', 1],
  ['#99999999999999999999999999999', null, 'unresolved', null],
  ['https://example.invalid/#2', null, 'url', null], ['?page=2&zoom=width', null, 'options', null],
];
open('outline-indirect/index.djvu');
const before = core.live_bytes();
for (const [href, from, kind, page] of cases) {
  assert.deepEqual(link(href, from), { kind, page }); assert.equal(core.live_bytes(), before);
  if (native) assert.deepEqual(cli('resolve-link', fixture('outline-indirect/index.djvu'), href, ...(from == null ? [] : [String(from + 1)])), { kind, page });
}
assert.equal(core.link_resolve(0), 0); assert.equal(core.last_status(), 7);
let ptr = core.link_alloc(1); assert(ptr > 0);
new Uint8Array(core.memory.buffer, ptr, 1)[0] = 0xff;
assert.equal(core.link_resolve(0xffffffff), 0); assert.equal(core.last_status(), 7);
core.link_release(); assert.equal(core.live_bytes(), before);
assert.equal(core.link_alloc(129 * 1024 * 1024), 0); assert.equal(core.last_status(), 4);
assert.equal(core.live_bytes(), before);
ptr = core.link_alloc(0); assert(ptr > 0);
assert.equal(core.link_resolve(7), 0); assert.equal(core.last_status(), 7);
core.link_release();
prepare(core, fixture('outline-indirect/index.djvu'), 0);
assert.equal(core.render_start(0, 1, 0), 0); assert.equal(core.render_step(1), 1);
assert.deepEqual(outline(), expected);
assert.equal(core.annotations_load(0), 0); assert.equal(core.text_load(0), 0);
assert.equal(core.outline_present(), 1);
assert.deepEqual(link('#+2', 0), { kind: 'page', page: 2 });
let status; do { status = core.render_step(4096); } while (status === 1);
assert.equal(status, 0);
core.close(); assert.equal(core.live_bytes(), 0);
for (const name of ['outline-bad.djvu', 'outline-duplicate.djvu']) {
  open(name); assert.equal(core.render_start(0, 1, 0), 0);
  assert.equal(core.outline_load(), 2); assert.equal(core.outline_present(), 0);
  do { status = core.render_step(4096); } while (status === 1);
  assert.equal(status, 0); core.close(); assert.equal(core.live_bytes(), 0);
}
open('outline-single.djvu', 2500);
const live = core.live_bytes();
assert.equal(core.outline_load(), 4); assert.equal(core.live_bytes(), live);
core.close(); assert.equal(core.live_bytes(), 0);

if (oracle) {
  // A small parser for the external editor's test output, not library code.
  function readEditor(text) {
    const tokens = text.match(/\(|\)|"(?:\\[\s\S]|[^"\\])*"|[^\s()]+/gu) ?? [];
    let pos = 0;
    const string = token => {
      const body = token.slice(1, -1), bytes = [];
      for (const part of body.match(/\\[0-7]{1,3}|\\[\s\S]|[^\\]+/gu) ?? []) {
        if (part[0] !== '\\') bytes.push(...new TextEncoder().encode(part));
        else if (/^\\[0-7]/u.test(part)) bytes.push(parseInt(part.slice(1), 8));
        else bytes.push(({ n: 10, r: 13, t: 9, b: 8, f: 12, v: 11, a: 7 })[part[1]] ?? part.charCodeAt(1));
      }
      return utf8.decode(Uint8Array.from(bytes));
    };
    const parse = () => {
      const token = tokens[pos++];
      if (token === '(') {
        const list = []; while (tokens[pos] !== ')') { assert(pos < tokens.length); list.push(parse()); } pos++; return list;
      }
      assert(token !== undefined && token !== ')');
      return token.startsWith('"') ? string(token) : token;
    };
    const tree = parse(); assert.equal(pos, tokens.length); assert.equal(tree.shift(), 'bookmarks');
    const entries = [];
    function walk(nodes, parent = null) {
      for (const [title, href, ...children] of nodes) {
        const index = entries.length;
        entries.push({ title, href, parent, subtreeEnd: 0 });
        walk(children, index); entries[index].subtreeEnd = entries.length;
      }
    }
    walk(tree); return { entries };
  }
  for (const name of ['outline-oracle.djvu', 'outline-djvused.djvu']) {
    const result = spawnSync('djvused', ['-u', fixture(name), '-e', 'print-outline'], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(readEditor(result.stdout), expected, name);
  }
}
console.log(`WASM outlines: ${names.length} fixtures, ${cases.length} links passed`);
