// Sequential reading through the production ABI. Node is only a profiling host.
import assert from 'node:assert/strict';
import { openSync, closeSync, fstatSync, readSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const [wasm, path, ...args] = process.argv.slice(2);
if (!wasm || !path) {
  throw new Error('usage: node tools/memory.mjs WASM INPUT '
    + '[--eager] [--pages=N] [--drop-every=N] [--limit-mib=N] [--cache-mib=N] [--passes=N]');
}
const options = { eager: false, pages: Infinity, dropEvery: 0, limitMiB: 64, passes: 1 };
const optionNames = {
  pages: 'pages', 'drop-every': 'dropEvery', 'limit-mib': 'limitMiB', 'cache-mib': 'cacheMiB', passes: 'passes',
};
for (const arg of args) {
  if (arg === '--eager') { options.eager = true; continue; }
  const match = /^--(pages|drop-every|limit-mib|cache-mib|passes)=(\d+)$/.exec(arg);
  assert(match, `Unknown option: ${arg}`);
  const value = Number(match[2]);
  assert(Number.isSafeInteger(value) && value >= (match[1] === 'cache-mib' ? 0 : 1), `Invalid option: ${arg}`);
  options[optionNames[match[1]]] = value;
}
assert(options.limitMiB <= 256, 'WASM supports at most 256 MiB');
options.cacheMiB ??= options.limitMiB / 4;
assert(options.cacheMiB <= options.limitMiB, 'Cache target must fit the live allocation budget');
const codes = [
  '', '', 'InvalidData', 'Unsupported', 'LimitExceeded', 'Cancelled',
  'OutOfMemory', 'InvalidArgument', 'Busy', 'MissingComponent',
];
const core = (await WebAssembly.instantiate(await WebAssembly.compile(readFileSync(wasm)), {})).exports;
const fd = openSync(path, 'r');
let readBytes = 0, reads = 0, completed = 0;
const check = status => { if (status !== 0) throw new Error(codes[status] ?? `status ${status}`); };
const pointer = value => {
  if (!value) check(core.last_status());
  assert(value);
  return value;
};
function read(offset, length) {
  const bytes = Buffer.alloc(length);
  assert.equal(readSync(fd, bytes, 0, length, offset), length, 'Input changed or ended early');
  readBytes += length; reads++;
  return bytes;
}
function copy(ptr, bytes) {
  // Obtain the view after allocation: growth may detach the preceding buffer.
  new Uint8Array(core.memory.buffer, ptr, bytes.length).set(bytes);
}
function report(stage, extra = {}) {
  console.log(JSON.stringify({
    stage, live_bytes: core.live_bytes(), peak_bytes: core.peak_bytes(),
    linear_bytes: core.memory.buffer.byteLength, cache_bytes: core.cache_bytes(), dictionary_decodes: core.dictionary_decodes(),
    read_bytes: readBytes, reads, ...extra,
  }));
}
function prepare(page) {
  for (;;) {
    const missing = core.next_missing(page, 1);
    check(core.last_status());
    if (!missing) return;
    const index = missing - 1;
    const info = new DataView(core.memory.buffer, pointer(core.component_info(index)), 44);
    const offset = info.getUint32(36, true), length = info.getUint32(40, true);
    assert(length, 'This probe reads bundled files; indirect components need a separate host');
    const ptr = pointer(core.component_alloc(index, length));
    copy(ptr, read(offset, length));
    check(core.component_commit(index));
  }
}
try {
  const size = fstatSync(fd).size;
  assert(size > 0 && size <= 0xffffffff, 'Source size must fit u32');
  const limit = options.limitMiB * 1024 * 1024;
  if (options.eager) {
    const ptr = pointer(core.input_alloc(size, limit));
    copy(ptr, read(0, size));
    check(core.open());
  } else {
    check(core.source_start(size, limit));
    for (;;) {
      const ptr = core.source_range();
      check(core.last_status());
      if (!ptr) break;
      const view = new DataView(core.memory.buffer, ptr, 8);
      const offset = view.getUint32(0, true), length = view.getUint32(4, true);
      const target = pointer(core.source_alloc());
      copy(target, read(offset, length));
      check(core.source_commit());
    }
  }
  report('open', { file: path, file_bytes: size, pages: core.page_count(), options });
  for (let pass = 0; pass < options.passes; pass++) {
    for (let page = 0; page < Math.min(options.pages, core.page_count()); page++) {
      // Match the Worker's page replacement: release old layers/output before IO.
      core.render_cancel();
      check(core.trim_cache(options.cacheMiB * 1024 * 1024));
      if (options.dropEvery && page && page % options.dropEvery === 0) {
        check(core.drop_components());
        report('drop-cache', { before_page: page + 1 });
      }
      prepare(page);
      const started = performance.now();
      check(core.render_start(page, 3, 0));
      let status;
      do { status = core.render_step(8192); } while (status === 1);
      check(status);
      const rgba = new Uint8Array(core.memory.buffer, core.result_ptr(), core.result_len());
      completed++;
      report('page', {
        pass: pass + 1, page: page + 1, render_ms: performance.now() - started,
        output: [core.result_width(), core.result_height()], result_bytes: rgba.length,
        rgba_sha256: createHash('sha256').update(rgba).digest('hex'),
      });
    }
  }
  core.render_cancel();
  report('release-job');
  check(core.drop_dictionaries());
  report('release-dictionaries');
  check(core.drop_components());
  report('release-components');
} catch (error) {
  report('failure', { completed, error: error.message, status: core.last_status() });
  process.exitCode = 1;
} finally {
  core.close();
  report('close', { completed });
  closeSync(fd);
  assert.equal(core.live_bytes(), 0, 'Close must release all budgeted allocations');
}
