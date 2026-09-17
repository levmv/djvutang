import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const module = await WebAssembly.compile(readFileSync(process.argv[2] ?? 'zig-out/bin/heap-test.wasm'));
assert.deepEqual(WebAssembly.Module.imports(module), []);
const open = async () => (await WebAssembly.instantiate(module, {})).exports;
const page = 65536, MiB = 16 * page;

// Page-granular allocation, splitting, coalescing and in-place resize. An
// intervening standard allocation must never become part of a free page run.
{
  const c = await open(), initial = c.memory.buffer.byteLength;
  const a = c.alloc(MiB, 0);
  assert(a); assert.equal(c.memory.buffer.byteLength, initial + MiB);
  new Uint8Array(c.memory.buffer, a, MiB).fill(0xa7);
  const b = c.alloc(MiB, 0), small = c.alloc(37, 0), d = c.alloc(MiB, 0);
  assert(b && small && d);
  new Uint8Array(c.memory.buffer, small, 37).fill(0x39);
  new Uint8Array(c.memory.buffer, d, MiB).fill(0xd1);
  c.free(b, MiB, 0);
  const capacity = c.memory.buffer.byteLength;
  assert.equal(c.resize(a, MiB, 0, 2 * MiB), 1);
  assert(new Uint8Array(c.memory.buffer, a, MiB).every(v => v === 0xa7));
  assert.equal(c.resize(a, 2 * MiB, 0, 2 * MiB + page), 0, 'cannot consume standard allocator pages');
  assert.equal(c.resize(a, 2 * MiB, 0, MiB), 1);
  const split = c.alloc(page, 0);
  assert.equal(split, a + MiB);
  c.free(split, page, 0);
  c.free(a, MiB, 0);
  const joined = c.alloc(2 * MiB, 0);
  assert.equal(joined, a);
  assert.equal(c.memory.buffer.byteLength, capacity);
  new Uint8Array(c.memory.buffer, joined, 2 * MiB).fill(0x55);
  assert(new Uint8Array(c.memory.buffer, small, 37).every(v => v === 0x39));
  assert(new Uint8Array(c.memory.buffer, d, MiB).every(v => v === 0xd1));
  c.free(joined, 2 * MiB, 0); c.free(small, 37, 0); c.free(d, MiB, 0);
}

// A failed memory.grow/realloc keeps both the old bytes and free runs intact.
{
  const c = await open(), p = c.alloc(MiB, 0), q = c.alloc(2 * MiB, 0);
  assert(p && q);
  new Uint8Array(c.memory.buffer, p, MiB).fill(0x81);
  c.free(q, 2 * MiB, 0);
  const capacity = c.memory.buffer.byteLength;
  assert.equal(c.resize(p, MiB, 0, 8 * MiB), 0);
  assert.equal(c.realloc(p, MiB, 0, 8 * MiB), 0);
  assert.equal(c.alloc(0xffffffff, 0), 0);
  assert.equal(c.memory.buffer.byteLength, capacity);
  assert(new Uint8Array(c.memory.buffer, p, MiB).every(v => v === 0x81));
  const reused = c.alloc(2 * MiB, 0);
  assert.equal(reused, q);
  assert.equal(c.memory.buffer.byteLength, capacity);
  c.free(reused, 2 * MiB, 0); c.free(p, MiB, 0);
}

// Mixed lifetimes exercise threshold crossings and alignments. Check all live
// allocations for overlap and retained bytes independently of the free map.
{
  const c = await open(), live = new Map();
  let seed = 0x97cfb123;
  const random = n => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return (seed >>> 8) % n; };
  const sizes = [1, 37, 4096, page - 1, page, page + 1, 3 * page + 17, MiB];
  for (let step = 0; step < 600; step++) {
    const slot = random(24), previous = live.get(slot), len = sizes[random(sizes.length)];
    const alignment = previous?.alignment ?? [0, 4, 16, 17][random(4)];
    if (previous && random(3) === 0) {
      c.free(previous.ptr, previous.len, alignment); live.delete(slot);
    } else {
      const ptr = previous ? c.realloc(previous.ptr, previous.len, alignment, len) : c.alloc(len, alignment);
      if (ptr) {
        if (previous) assert(new Uint8Array(c.memory.buffer, ptr, Math.min(len, previous.len)).every(v => v === previous.value));
        const value = (step % 251) + 1;
        new Uint8Array(c.memory.buffer, ptr, len).fill(value);
        live.set(slot, { ptr, len, alignment, value });
      }
    }
    const sorted = [...live.values()].sort((a, b) => a.ptr - b.ptr);
    for (let i = 0; i < sorted.length; i++) {
      const item = sorted[i], bytes = new Uint8Array(c.memory.buffer, item.ptr, item.len);
      assert.equal(item.ptr % 2 ** item.alignment, 0);
      if (i) assert(sorted[i - 1].ptr + sorted[i - 1].len <= item.ptr, 'live allocations overlap');
      for (let j = 0; j < bytes.length; j += 4096) assert.equal(bytes[j], item.value);
      assert.equal(bytes[bytes.length - 1], item.value);
    }
  }
  for (const { ptr, len, alignment } of live.values()) c.free(ptr, len, alignment);
}
console.log('WASM heap: page reuse, splitting/coalescing, mixed alignment/lifetimes and failure preserving live bytes.');
