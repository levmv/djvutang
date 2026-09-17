// Synchronous fixture host for the freestanding ABI. Production IO stays outside WASM.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

export function componentInfo(core, index) {
  const ptr = core.component_info(index);
  assert(ptr > 0);
  const view = new DataView(core.memory.buffer, ptr, 44);
  const string = offset => new TextDecoder('utf-8', { fatal: true }).decode(
    new Uint8Array(core.memory.buffer, view.getUint32(offset, true), view.getUint32(offset + 4, true)));
  return { id: string(0), name: string(8), title: string(16), kind: view.getUint32(24, true),
    size: view.getUint32(28, true), loaded: !!view.getUint32(32, true),
    range: view.getUint32(40, true) ? { offset: view.getUint32(36, true), length: view.getUint32(40, true) } : null };
}

export function supply(core, index, bytes) {
  const ptr = core.component_alloc(index, bytes.length);
  assert(ptr > 0, `component allocation: ${core.last_status()}`);
  new Uint8Array(core.memory.buffer, ptr, bytes.length).set(bytes);
  return core.component_commit(index);
}

export function prepare(core, path, page, includes = true) {
  let count = 0;
  while (true) {
    const missing = core.next_missing(page, Number(includes));
    assert.equal(core.last_status(), 0);
    if (!missing) return count;
    const index = missing - 1;
    const file = resolve(dirname(path), componentInfo(core, index).name);
    assert.equal(supply(core, index, readFileSync(file)), 0);
    count++;
    assert(count <= core.component_count());
  }
}
