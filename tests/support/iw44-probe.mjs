// Codec probe helpers and a reference filter for compact IW44 grids.
function assert(condition, message = 'Invalid IW44 input') {
  if (!condition) throw new Error(message);
}

export function packChunks(chunks) {
  const bytes = new Uint8Array(4 + chunks.reduce((n, chunk) => n + 4 + chunk.length, 0));
  const view = new DataView(bytes.buffer);
  view.setUint32(0, chunks.length, true);
  let position = 4;
  for (const chunk of chunks) {
    view.setUint32(position, chunk.length, true);
    position += 4;
    bytes.set(chunk, position);
    position += chunk.length;
  }
  return bytes;
}

// Extract IW44 chunks from a self-contained maskless page or layer.
export function wavelets(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tagAt = offset => String.fromCharCode(...bytes.subarray(offset, offset + 4));
  const base = tagAt(0) === 'AT&T' ? 4 : 0;
  assert(bytes.length >= base + 12 && tagAt(base) === 'FORM');
  const end = base + 8 + view.getUint32(base + 4);
  assert(end <= bytes.length && end >= base + 12);
  const kind = tagAt(base + 8);
  assert(['DJVU', 'PM44', 'BM44'].includes(kind), 'Expected a standalone IW44 layer or page');
  const chunks = [];
  let info;
  for (let position = base + 12; position < end;) {
    assert(position + 8 <= end);
    const tag = tagAt(position);
    const length = view.getUint32(position + 4);
    assert(position + 8 + length <= end);
    const data = bytes.subarray(position + 8, position + 8 + length);
    const part = new DataView(data.buffer, data.byteOffset, data.byteLength);
    if (tag === 'INFO') {
      assert(data.length >= 5);
      info = { width: part.getUint16(0), height: part.getUint16(2),
        gamma: data.length >= 9 ? Math.max(3, Math.min(50, data[8])) : 22,
        rotation: ({ 6: 1, 2: 2, 5: 3 })[data.length >= 10 ? data[9] & 7 : 0] ?? 0 };
    } else if (tag === 'BG44' || tag === kind && kind !== 'DJVU') chunks.push(data);
    else if (['Sjbz', 'Smmr', 'BGjp', 'INCL'].includes(tag) || tag.startsWith('FG')) {
      throw new Error(`The codec probe cannot resolve ${tag} chunks; it requires a standalone maskless IW44 page.`);
    }
    position += 8 + length + (length & 1);
  }
  assert(chunks.length > 0, 'This page has no IW44 image to compare.');
  assert(chunks[0].length >= 8);
  const first = new DataView(chunks[0].buffer, chunks[0].byteOffset, chunks[0].byteLength);
  const width = first.getUint16(4), height = first.getUint16(6);
  info ??= { width, height, gamma: 22, rotation: 0 };
  const layerReduction = Array.from({ length: 12 }, (_, i) => i + 1)
    .find(r => Math.ceil(info.width / r) === width && Math.ceil(info.height / r) === height);
  assert(layerReduction, 'Invalid layer geometry');
  return { chunks, width, height, info, layerReduction };
}

export async function openProbe(module, bytes, limitMiB = 64) {
  const core = (await WebAssembly.instantiate(module, {})).exports;
  const ptr = core.input_alloc(bytes.length, limitMiB * 1024 * 1024);
  assert(ptr, 'Input allocation failed');
  new Uint8Array(core.memory.buffer, ptr, bytes.length).set(bytes);
  assert(core.open() === 0, 'Could not open the IW44 stream');
  return core;
}

export function finish(core, work = 16384) {
  for (let calls = 0; calls < 2_000_000; calls++) {
    const status = core.step(work);
    if (status === 0) return;
    if (status !== 1) throw Object.assign(new Error(`IW44 probe status ${status}`), { status });
  }
  throw new Error('IW44 probe work limit');
}

export function result(core) {
  return { width: core.result_width(), height: core.result_height(),
    rgb: new Uint8Array(core.memory.buffer, core.result_ptr(), core.result_len()).slice() };
}

// Apply gamma, then average cells on the bottom-left layer grid. Clip edge cells
// to INFO bounds; rounded raster dimensions must not change the page extent.
export function preview(image, input, reduction, box, extraRotation = 0) {
  const { info, layerReduction } = input;
  const step = reduction * layerReduction;
  const rotation = (info.rotation + extraRotation) % 4;
  const w = rotation % 2 ? info.height : info.width;
  const h = rotation % 2 ? info.width : info.height;
  const width = box.width * h <= box.height * w ? box.width : Math.max(1, Math.floor(w * box.height / h));
  const height = box.width * h <= box.height * w ? Math.max(1, Math.floor(h * box.width / w)) : box.height;
  const bw = rotation % 2 ? height : width, bh = rotation % 2 ? width : height;
  assert(bw * step <= info.width && bh * step <= info.height, 'The reference filter supports shrinking only');
  const gamma = Array.from({ length: 256 }, (_, i) => info.gamma === 22 ? i
    : Math.floor(255 * (i / 255) ** (info.gamma / 22) + 0.5));
  function axes(source, output) {
    const span = step * output;
    return Array.from({ length: output }, (_, i) => {
      const left = i * source, right = (i + 1) * source;
      const first = Math.floor(left / span), end = Math.ceil(right / span);
      return { first, weights: Array.from({ length: end - first }, (_, j) =>
        Math.min(right, (first + j + 1) * span) - Math.max(left, (first + j) * span)) };
    });
  }
  const xs = axes(info.width, bw), ys = axes(info.height, bh);
  const rgba = new Uint8Array(width * height * 4);
  const total = info.width * info.height;
  for (let y = 0; y < bh; y++) for (let x = 0; x < bw; x++) {
    const sum = [0, 0, 0], ax = xs[x], ay = ys[y];
    for (let j = 0; j < ay.weights.length; j++) for (let i = 0; i < ax.weights.length; i++) {
      const index = ((image.height - 1 - ay.first - j) * image.width + ax.first + i) * 3;
      const weight = ax.weights[i] * ay.weights[j];
      for (let c = 0; c < 3; c++) sum[c] += gamma[image.rgb[index + c]] * weight;
    }
    const top = bh - 1 - y;
    const [dx, dy] = rotation === 0 ? [x, top] : rotation === 1 ? [top, bw - 1 - x]
      : rotation === 2 ? [bw - 1 - x, bh - 1 - top] : [bh - 1 - top, x];
    const dest = (dy * width + dx) * 4;
    for (let c = 0; c < 3; c++) rgba[dest + c] = Math.floor((sum[c] + total / 2) / total);
    rgba[dest + 3] = 255;
  }
  return { width, height, rgba };
}
