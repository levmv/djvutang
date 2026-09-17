// Match tools/bench.zig through the import-free WASM ABI. No npm dependencies.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const [wasm, ...args] = process.argv.slice(2);
let width = null, full = false;
while (args[0]?.startsWith('--')) {
  const arg = args.shift();
  if (/^--width=\d+$/.test(arg)) {
    width = Number(arg.slice(8));
    assert(Number.isSafeInteger(width) && width >= 1 && width <= 65535);
  } else if (arg === '--full') full = true;
  else throw new Error(`Unknown option: ${arg}`);
}
const paths = args;
if (!wasm || !paths.length || (full && width !== null)) {
  throw new Error('usage: node tools/bench.mjs WASM [--width=N | --full] INPUT...');
}
const module = await WebAssembly.compile(readFileSync(wasm));
for (const path of paths) {
  // Fresh memory for each input; the second render reuses decoded layers.
  const core = (await WebAssembly.instantiate(module, {})).exports;
  const bytes = readFileSync(path);
  const ptr = core.input_alloc(bytes.length, 192 << 20);
  assert(ptr, `input: ${core.last_status()}`);
  new Uint8Array(core.memory.buffer, ptr, bytes.length).set(bytes);
  assert.equal(core.open(), 0);
  const rotation = core.page_rotation(0);
  const sourceWidth = rotation & 1 ? core.page_height(0) : core.page_width(0);
  const sourceHeight = rotation & 1 ? core.page_width(0) : core.page_height(0);
  const boxWidth = width ?? 400;
  const boxHeight = width === null ? 600 : Math.max(1, Math.ceil(sourceHeight * width / sourceWidth));
  for (const warm of [false, true]) {
    const before = performance.now();
    assert.equal(full ? (warm ? core.render_restart(1, 0) : core.render_start(0, 1, 0))
      : warm ? core.render_restart_sized(boxWidth, boxHeight, 0, 0, 0, 0, 0)
        : core.render_start_sized(0, boxWidth, boxHeight, 0, 0, 0, 0, 0), 0);
    let steps = 0, maxStepMs = 0;
    for (;;) {
      const start = performance.now();
      const status = core.render_step(4096);
      maxStepMs = Math.max(maxStepMs, performance.now() - start);
      steps++;
      if (status === 0) break;
      assert.equal(status, 1);
    }
    const renderMs = performance.now() - before;
    const rgba = new Uint8Array(core.memory.buffer, core.result_ptr(), core.result_len());
    console.log(JSON.stringify({ file: path, warm,
      source: [core.page_width(0), core.page_height(0)],
      output: [core.result_width(), core.result_height()], render_ms: renderMs,
      max_step_ms: maxStepMs, steps, live_bytes: core.live_bytes(), peak_bytes: core.peak_bytes(),
      rgba_sha256: createHash('sha256').update(rgba).digest('hex'),
    }));
  }
  core.close();
  assert.equal(core.live_bytes(), 0);
}
