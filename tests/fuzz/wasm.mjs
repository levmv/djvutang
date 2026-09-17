// Optional ABI state/mutation probe. One instance is reused across documents.
// node tests/fuzz/wasm.mjs [cases=10000] [seed=0x646a7675]
// node tests/fuzz/wasm.mjs --replay tests/out/fuzz-wasm/failure.json
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, mkdirSync, writeFileSync } from 'node:fs';
import { resolve, dirname, relative } from 'node:path';
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';
import { createHash } from 'node:crypto';

const root = resolve(import.meta.dirname, '../..');
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
const out = resolve(root, 'tests/out/fuzz-wasm');
const runner = hash(readFileSync(import.meta.filename));

if (isMainThread) {
  const replay = process.argv[2] === '--replay' ? JSON.parse(readFileSync(process.argv[3])) : null;
  if (replay) assert.equal(replay.runner, runner, 'Replay needs the same harness; saved input bytes remain available in the report');
  const amount = /^(\d+)([KMG]?)$/i.exec(process.argv[2] ?? '10000');
  const units = { '': 1, K: 1000, M: 1000000, G: 1000000000 };
  const count = replay ? 1 : amount ? Number(amount[1]) * units[amount[2].toUpperCase()] : NaN;
  const firstSeed = replay?.seed ?? Number(process.argv[3] ?? 0x646a7675);
  assert(Number.isSafeInteger(count) && count > 0);
  assert(Number.isSafeInteger(firstSeed) && firstSeed >= 0 && firstSeed <= 0xffffffff);
  mkdirSync(out, { recursive: true });
  const wasm = await WebAssembly.compile(readFileSync(resolve(root, 'zig-out/bin/djvutang.wasm')));
  const worker = new Worker(new URL(import.meta.url), { workerData: { wasm, replay } });
  let completed = 0, seed = firstSeed, timer, lastCall, counts, fixtureDigest, settled = false;
  const started = Date.now();
  try {
    await new Promise((done, reject) => {
      const failed = (error, details = {}) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        const report = { seed, runner, fixtureDigest, completed, error: String(error), lastCall, ...details };
        writeFileSync(resolve(out, 'failure.json'), JSON.stringify(report, null, 2) + '\n');
        reject(new Error(`${error}; replay tests/out/fuzz-wasm/failure.json`));
      };
      const next = () => {
        seed = (firstSeed + completed) >>> 0;
        lastCall = null;
        timer = setTimeout(() => failed('Case exceeded 10 seconds'), 10000);
        worker.postMessage({ seed });
      };
      worker.on('error', failed);
      worker.on('exit', (code) => { if (completed !== count) failed(`Worker exited: ${code}`); });
      worker.on('message', (message) => {
        if (message.type === 'ready') {
          fixtureDigest = message.fixtureDigest;
          if (replay && replay.fixtureDigest !== fixtureDigest) failed('Replay fixture set changed');
          else next();
        }
        else if (message.type === 'call') lastCall = message.call;
        else if (message.type === 'failure') failed(message.error, message.details);
        else if (message.type === 'done') {
          clearTimeout(timer);
          counts = message.counts;
          completed++;
          if (completed % 10000 === 0) console.log(JSON.stringify({ completed, seed, seconds: (Date.now() - started) / 1000 }));
          if (completed === count) { settled = true; done(); } else next();
        }
      });
    });
    const result = { cases: count, seed: firstSeed, runner, fixtureDigest, seconds: (Date.now() - started) / 1000, counts, reusedInstance: true, snapshots: true, recovery: true, closeAtZero: true };
    writeFileSync(resolve(out, 'results.json'), JSON.stringify(result, null, 2) + '\n');
    console.log(JSON.stringify(result));
  } finally {
    clearTimeout(timer);
    await worker.terminate();
  }
} else {
  const c = (await WebAssembly.instantiate(workerData.wasm, {})).exports;
  const fixtures = resolve(root, 'tests/fixtures');
  const files = new Map();
  function collect(folder) {
    for (const entry of readdirSync(folder, { withFileTypes: true })) {
      const path = resolve(folder, entry.name);
      if (entry.isDirectory()) collect(path);
      else if (/\.(djvu|iw4|thum|thumb|iff)$/.test(entry.name) || !entry.name.includes('.')) {
        const bytes = readFileSync(path);
        if (bytes.length <= 32768) files.set(path, bytes);
      }
    }
  }
  collect(fixtures);
  const fixtureDigest = hash([...files].map(([path, bytes]) => `${relative(fixtures, path)}\0${hash(bytes)}`).sort().join('\n'));
  for (const input of workerData.replay?.inputs ?? []) {
    const bytes = files.get(resolve(fixtures, input.path));
    assert(bytes && hash(bytes) === input.sha256, `Replay fixture changed: ${input.path}`);
  }
  const seeds = [...files.keys()].filter((path) => dirname(path) === fixtures || /\/(index|page)\.djvu$/.test(path)).sort();
  const plain = resolve(fixtures, 'plain.djvu');
  let random, trace, inputs, current, snapshots, recording = false, recovering = true;
  const counts = { opened: 0, renders: 0, thumbnails: 0, doneSteps: 0, metadata: 0, supplied: 0 };
  const next = (n) => {
    random ^= random << 13; random ^= random >>> 17; random ^= random << 5;
    return (random >>> 0) % n;
  };
  function call(name, ...args) {
    if (recording) {
      const entry = { name, args };
      trace.push(entry);
      parentPort.postMessage({ type: 'call', call: entry });
    }
    const result = c[name](...args);
    if (!recovering && result === 0) {
      if (name === 'open') counts.opened++;
      if (name === 'render_start' || name === 'render_start_region') counts.renders++;
      if (name === 'thumbnail_start' && c.thumbnail_present()) counts.thumbnails++;
      if (name === 'render_step') counts.doneSteps++;
      if (name === 'component_commit') counts.supplied++;
      if (['text_load', 'annotations_load', 'outline_load'].includes(name)) counts.metadata++;
    }
    return result;
  }
  function memory(ptr, length) {
    return Buffer.from(new Uint8Array(c.memory.buffer, ptr, length));
  }
  function mutate(source) {
    const bytes = Buffer.from(source), mode = next(8);
    if (mode === 0) return bytes.subarray(0, next(bytes.length + 1));
    if (mode >= 4) {
      const start = mode === 4 ? 0 : Math.min(24, bytes.length - 1);
      for (let n = 1 + next(4); n; n--) bytes[start + next(bytes.length - start)] ^= 1 + next(255);
    }
    return bytes;
  }
  function load(path, bytes, limit) {
    current = path;
    snapshots.clear();
    if (recording) inputs.push({ path: relative(fixtures, path), sha256: hash(files.get(path)), bytes: bytes.toString('base64') });
    const ptr = call('input_alloc', bytes.length, limit);
    if (!ptr) return;
    new Uint8Array(c.memory.buffer, ptr, bytes.length).set(bytes);
    call('open');
  }
  function snapshot(kind) {
    return kind === 'text'
      ? Buffer.concat([memory(c.text_ptr(), c.text_len()), memory(c.text_zones_ptr(), c.text_zones_count() * 36)])
      : memory(c[`${kind}_ptr`](), c[`${kind}_len`]());
  }
  function inspect() {
    assert(c.cache_bytes() <= c.live_bytes(), 'cache bytes are part of live allocations');
    for (const [kind, bytes] of snapshots) assert.deepEqual(snapshot(kind), bytes, `${kind} snapshot changed`);
    const length = c.result_len();
    if (length) {
      assert.equal(length, c.result_width() * c.result_height() * 4);
      assert(c.result_x() + c.result_width() <= c.result_page_width());
      assert(c.result_y() + c.result_height() <= c.result_page_height());
      const pixels = memory(c.result_ptr(), length);
      for (let i = 3; i < pixels.length; i += 4) assert.equal(pixels[i], 255);
    }
  }
  function component(page) {
    const missing = call('next_missing', page, next(4));
    if (!missing) return;
    const index = missing - 1, ptr = call('component_info', index);
    if (!ptr) return;
    const info = new DataView(c.memory.buffer, ptr, 36);
    const name = new TextDecoder().decode(memory(info.getUint32(8, true), info.getUint32(12, true)));
    // The lookup is confined to files preloaded from our public fixtures.
    const path = resolve(dirname(current), name), source = files.get(path);
    if (!source) return;
    const bytes = mutate(source), target = call('component_alloc', index, bytes.length);
    if (!target) return;
    new Uint8Array(c.memory.buffer, target, bytes.length).set(bytes);
    inputs.push({ component: index, path: relative(fixtures, path), sha256: hash(source), bytes: bytes.toString('base64') });
    if (next(4) !== 0) call('component_commit', index); // Otherwise leave a pending supply.
  }
  function finishPlain() {
    load(plain, files.get(plain), 8 * 1024 * 1024);
    assert.equal(call('render_start', 0, 1, 0), 0);
    let status = 1;
    for (let i = 0; status === 1 && i < 256; i++) status = call('render_step', 4096);
    assert.equal(status, 0);
    const result = hash(memory(c.result_ptr(), c.result_len()));
    call('close');
    assert.equal(c.live_bytes(), 0);
    return result;
  }
  snapshots = new Map();
  const baseline = finishPlain();
  parentPort.on('message', ({ seed }) => {
    random = seed || 1;
    trace = []; inputs = []; snapshots = new Map(); recording = true; recovering = false;
    try {
      const source = seeds[next(seeds.length)];
      load(source, mutate(files.get(source)), next(4) ? 8 * 1024 * 1024 : 128 * 1024);
      for (let step = 0; step < 32; step++) {
        const page = next(Math.min(c.page_count(), 4) + 1);
        switch (next(21)) {
          case 0: call('render_start', page, next(6), next(5)); break;
          case 1: call('thumbnail_start', page); break;
          case 2: for (let i = 0; i < 8; i++) if (call('render_step', next(2) ? 4096 : 1) !== 1) break; break;
          case 3: call('render_cancel'); break;
          case 4: call('render_restart', next(6), next(5)); break;
          case 5: call('render_start_region', page, 1 + next(4), next(4), next(16), next(16), next(32), next(32)); break;
          case 6: case 7: case 8: {
            const kind = ['text', 'annotations', 'outline'][next(3)];
            snapshots.delete(kind);
            const status = kind === 'outline' ? call('outline_load') : call(`${kind}_load`, page);
            if (status === 0) {
              const bytes = snapshot(kind);
              if (kind !== 'text' && bytes.length) JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
              snapshots.set(kind, bytes);
            }
            break;
          }
          case 9: {
            const kind = ['text', 'annotations', 'outline'][next(3)];
            call(`${kind}_release`); snapshots.delete(kind); break;
          }
          case 10: component(page); break;
          case 11: call('component_commit', next(c.component_count() + 1)); break;
          case 12: call('component_abort'); break;
          case 13: call('drop_components'); break;
          case 14: call('drop_dictionaries'); break;
          case 15: {
            const bytes = Buffer.from(['#1', '#+1', '#missing', 'https://example.invalid/'][next(4)]);
            const ptr = call('link_alloc', bytes.length);
            if (ptr) new Uint8Array(c.memory.buffer, ptr, bytes.length).set(bytes);
            call('link_resolve', next(2) ? page : 0xffffffff); break;
          }
          case 16: call('link_release'); break;
          case 17: call('page_transform', page, next(6), next(5)); break;
          case 18: call('open'); break;
          case 19: {
            if (next(2)) {
              const path = seeds[next(seeds.length)];
              load(path, mutate(files.get(path)), 8 * 1024 * 1024);
            } else { call('close'); snapshots.clear(); }
            break;
          }
          case 20: {
            const target = next(2) ? 0 : next(65536), before = c.cache_bytes();
            if (call('trim_cache', target) === 0) assert(c.cache_bytes() <= target);
            else assert.equal(c.cache_bytes(), before, 'failed trim preserves the cache');
            break;
          }
        }
        inspect();
      }
      call('close'); assert.equal(c.live_bytes(), 0);
      recovering = true;
      assert.equal(finishPlain(), baseline, 'valid document changed after an error/replacement');
      parentPort.postMessage({ type: 'done', counts });
    } catch (error) {
      parentPort.postMessage({ type: 'failure', error: error.stack, details: { trace, inputs } });
    }
  });
  parentPort.postMessage({ type: 'ready', fixtureDigest });
}
