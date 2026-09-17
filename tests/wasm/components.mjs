import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, mkdirSync, cpSync, symlinkSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { componentInfo, prepare, supply } from '../support/component-host.mjs';

const root = resolve(import.meta.dirname, '../..');
const module = await WebAssembly.compile(readFileSync(resolve(root, 'zig-out/bin/djvutang.wasm')));
const core = (await WebAssembly.instantiate(module, {})).exports;
const path = resolve(root, 'tests/fixtures/indirect-layers/index.djvu');
function open(path) {
  const bytes = readFileSync(path), ptr = core.input_alloc(bytes.length, 64*1024*1024);
  assert(ptr > 0);
  new Uint8Array(core.memory.buffer, ptr, bytes.length).set(bytes);
  assert.equal(core.open(), 0);
}
open(path);
const baseline = core.live_bytes();
assert.equal(core.document_indirect(), 1);
assert.equal(core.page_count(), 2);
assert.equal(core.page_width(0), 0);
assert.equal(core.last_status(), 9);
const index = core.next_missing(0, 0) - 1;
assert.deepEqual(componentInfo(core, index), { id: 'page-a', name: 'sheet a.djvu', title: 'Opening',
  kind: 1, size: readFileSync(resolve(root, 'tests/fixtures/indirect-layers/sheet a.djvu')).length - 4, loaded: false, range: null });
const wrong = readFileSync(resolve(root, 'tests/fixtures/indirect-layers/mask.iff'));
assert.equal(supply(core, index, wrong), 2);
assert.equal(core.live_bytes(), baseline);
assert.equal(core.component_alloc(index, 128*1024*1024), 0);
assert.equal(core.last_status(), 4);
assert.equal(core.live_bytes(), baseline);
assert(core.component_alloc(index, 100) > 0);
assert.equal(core.trim_cache(0), 8, 'a pending input transfer prevents eviction');
core.component_abort();
assert.equal(core.live_bytes(), baseline);
assert.equal(core.cache_bytes(), 0);
assert.equal(prepare(core, path, 0, false), 1);
assert.equal(core.render_start(0, 1, 0), 9);
assert.equal(core.result_len(), 0);
assert.equal(prepare(core, path, 0), 5);
assert.equal(core.text_load(0), 0);
const text = () => new TextDecoder().decode(new Uint8Array(core.memory.buffer, core.text_ptr(), core.text_len()));
assert.equal(text(), 'Shared α text\n');
assert.equal(core.render_start(0, 1, 0), 0);
assert.equal(core.trim_cache(0), 8, 'an unfinished job pins its components');
let status = 1;
for (let i = 0; status === 1 && i < 100000; i++) status = core.render_step(2048);
assert.equal(status, 0);
assert.equal(prepare(core, path, 1, false), 1, 'supply another page while the Job remains alive');
assert(core.cache_bytes() > 0);
assert.equal(core.trim_cache(0), 8, 'a completed job also pins its components');
core.render_cancel();
assert.equal(core.trim_cache(0), 0);
assert.equal(core.cache_bytes(), 0);
assert.equal(text(), 'Shared α text\n', 'text snapshot owns its bytes');
core.text_release();
assert.equal(core.live_bytes(), baseline);
assert.equal(core.next_missing(0, 0), index + 1);
core.close();
assert.equal(core.live_bytes(), 0);
assert.equal(core.trim_cache(0), 7, 'trimming requires an open document');

const standalonePath = resolve(root, 'tests/fixtures/standalone-layers/page.djvu');
open(standalonePath);
assert.equal(core.document_indirect(), 0, 'external INCL does not imply an indirect DIRM');
assert.equal(core.component_count(), 5);
assert.equal(core.page_width(0), 65);
assert.equal(prepare(core, standalonePath, 0, false), 0);
assert.equal(core.render_start(0, 1, 0), 9);
let retained;
for (let round = 0; round < 2; round++) {
  assert.equal(prepare(core, standalonePath, 0), 5);
  assert.equal(core.component_count(), 6, 'nested ID appears after its parent is supplied');
  assert.deepEqual(componentInfo(core, 5), { id: 'tail', name: 'tail', title: 'tail', kind: 0, size: 0, loaded: true, range: null });
  assert.equal(core.text_load(0), 0);
  assert.equal(text(), 'Shared α text\n');
  core.text_release();
  assert.equal(core.render_start(0, 1, 0), 0);
  let status = 1;
  for (let i = 0; status === 1 && i < 100000; i++) status = core.render_step(2048);
  assert.equal(status, 0);
  const rgba = new Uint8Array(core.memory.buffer, core.result_ptr(), core.result_len());
  const ppm = readFileSync(resolve(root, 'tests/fixtures/jpeg-foreground-reference.ppm'));
  const rgb = ppm.subarray(ppm.indexOf('\n255\n') + 5);
  assert.equal(rgba.length, rgb.length / 3 * 4);
  assert(rgb.every((v, i) => v === rgba[Math.floor(i/3)*4 + i%3]));
  assert.equal(core.drop_components(), 0);
  assert.equal(core.page_width(0), 65, 'standalone root remains loaded');
  assert.equal(componentInfo(core, 5).name, 'tail', 'nested ID survives its parent buffer');
  assert.equal(componentInfo(core, 5).loaded, false);
  if (round === 0) retained = core.live_bytes(); else assert.equal(core.live_bytes(), retained);
}
core.close();
assert.equal(core.live_bytes(), 0);

if (process.argv.includes('--native')) {
  const cli = resolve(root, 'zig-out/bin/djvutang');
  const run = (path, command = 'info', args = []) => spawnSync(cli, [command, path, ...args], { encoding: 'utf8', timeout: 10000 });
  const result = run(path, 'text', ['2']);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).text, 'Shared α text\n');
  const standalone = run(standalonePath, 'text', ['1']);
  assert.equal(standalone.status, 0, standalone.stderr);
  assert.equal(JSON.parse(standalone.stdout).text, 'Shared α text\n');
  const temp = mkdtempSync(join(tmpdir(), 'djvu-component-paths-'));
  try {
    cpSync(resolve(root, 'tests/fixtures/indirect-layers'), temp, { recursive: true });
    const file = join(temp, 'sheet a.djvu');
    rmSync(file);
    const missing = run(join(temp, 'index.djvu'));
    assert.notEqual(missing.status, 0);
    assert.match(missing.stderr, /FileNotFound/);
    symlinkSync(resolve(root, 'tests/fixtures/indirect-layers/sheet a.djvu'), file);
    const linked = run(join(temp, 'index.djvu'));
    assert.notEqual(linked.status, 0);
    assert.match(linked.stderr, /InvalidComponentFile|SymLinkLoop/);
    rmSync(file);
    const fifo = spawnSync('mkfifo', [file]);
    if (fifo.status === 0) {
      const special = run(join(temp, 'index.djvu'));
      assert.notEqual(special.status, 0);
      assert.match(special.stderr, /InvalidComponentFile/);
    }
    rmSync(file, { force: true });
    writeFileSync(file, readFileSync(resolve(root, 'tests/fixtures/indirect-layers/sheet a.djvu')));
    const good = run(join(temp, 'index.djvu'));
    assert.equal(good.status, 0, good.stderr);

    // A malicious directory must not turn component resolution into arbitrary IO.
    const index = readFileSync(path);
    const metadata = spawnSync('bzz', ['-d', '-', '-'], { input: index.subarray(27, 24 + index.readUInt32BE(20)) });
    assert.equal(metadata.status, 0);
    const at = metadata.stdout.indexOf(Buffer.from('sheet a.djvu\0'));
    assert(at >= 0);
    const changed = Buffer.concat([metadata.stdout.subarray(0, at), Buffer.from('../sheet a.djvu\0'), metadata.stdout.subarray(at + 13)]);
    const compressed = spawnSync('bzz', ['-e50', '-', '-'], { input: changed });
    assert.equal(compressed.status, 0);
    const chunk = (tag, data) => {
      const head = Buffer.alloc(8); head.write(tag); head.writeUInt32BE(data.length, 4);
      return Buffer.concat([head, data, Buffer.alloc(data.length % 2)]);
    };
    mkdirSync(join(temp, 'nested'));
    const escaped = join(temp, 'nested/index.djvu');
    writeFileSync(escaped, Buffer.concat([Buffer.from('AT&T'), chunk('FORM', Buffer.concat([
      Buffer.from('DJVM'), chunk('DIRM', Buffer.concat([index.subarray(24, 27), compressed.stdout])),
    ]))]));
    const rejected = run(escaped);
    assert.notEqual(rejected.status, 0);
    assert.match(rejected.stderr, /InvalidComponentName/);

    // The same IO boundary applies to names discovered without a directory.
    const single = join(temp, 'nested/page.djvu');
    writeFileSync(single, readFileSync(standalonePath));
    assert.equal(run(single).status, 0, 'INFO does not need external files');
    const unavailable = run(single, 'text', ['1']);
    assert.notEqual(unavailable.status, 0);
    assert.match(unavailable.stderr, /FileNotFound/);
    const rootBytes = readFileSync(standalonePath);
    const include = rootBytes.indexOf('INCL', 16);
    writeFileSync(single, Buffer.concat([Buffer.from('AT&T'), chunk('FORM', Buffer.concat([
      Buffer.from('DJVU'), rootBytes.subarray(16, include), chunk('INCL', Buffer.from('../sheet a.djvu')),
    ]))]));
    const escapedInclude = run(single, 'text', ['1']);
    assert.notEqual(escapedInclude.status, 0);
    assert.match(escapedInclude.stderr, /InvalidComponentName/);
  } finally { rmSync(temp, { recursive: true, force: true }); }
}
console.log('components: lazy loading, ownership, rejected supply, cache and text lifetime passed' + (process.argv.includes('--native') ? '; native file boundary passed' : ''));
