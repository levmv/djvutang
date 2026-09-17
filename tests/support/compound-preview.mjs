import assert from 'node:assert/strict';
import { packChunks, openProbe, finish, result } from './iw44-probe.mjs';
import { fitReference } from './resample.mjs';

// Independent reference for the tiny foreground/MMR-foreground fixtures. Read
// their original PBM mask, reconstruct each color grid with the codec probe,
// expand and compose at INFO resolution, then rotate and area-filter in JS.
// This deliberately does not use the document compositor or its mask decoder.
export async function openCompoundReference(module, bytes, pbm) {
  const chunks = [[], []];
  let width, height, gamma, orientation;
  for (let pos = 16; pos < bytes.length;) {
    const tag = bytes.toString('ascii', pos, pos + 4), length = bytes.readUInt32BE(pos + 4);
    const data = bytes.subarray(pos + 8, pos + 8 + length);
    if (tag === 'INFO') {
      width = data.readUInt16BE(0); height = data.readUInt16BE(2);
      gamma = data[8]; orientation = ({ 6: 1, 2: 2, 5: 3 })[data[9] & 7] ?? 0;
    } else if (tag === 'BG44') chunks[0].push(data);
    else if (tag === 'FG44') chunks[1].push(data);
    pos += 8 + length + (length & 1);
  }
  const header = /^P4\s+(\d+)\s+(\d+)\n/.exec(pbm.toString('ascii'));
  assert(header && Number(header[1]) === width && Number(header[2]) === height);
  const mask = pbm.subarray(header[0].length), stride = Math.ceil(width / 8);
  const layers = [];
  for (const parts of chunks) {
    const w = parts[0].readUInt16BE(4), h = parts[0].readUInt16BE(6);
    const natural = Array.from({ length: 12 }, (_, i) => i + 1)
      .find(r => Math.ceil(width / r) === w && Math.ceil(height / r) === h);
    assert(natural);
    const core = await openProbe(module, packChunks(parts));
    finish(core); layers.push({ core, natural });
  }
  const corrected = Array.from({ length: 256 }, (_, i) => gamma === 22 ? i : Math.round(255 * (i / 255) ** (gamma / 22)));
  function sample(layer, x, y) {
    const { image, natural, reduction } = layer;
    const pixel = (px, py) => {
      const at = ((image.height - 1 - Math.max(0, Math.min(image.height - 1, py))) * image.width
        + Math.max(0, Math.min(image.width - 1, px))) * 3;
      return Array.from(image.rgb.subarray(at, at + 3), v => corrected[v]);
    };
    if (reduction > 1) return pixel(Math.floor(x / (natural * reduction)), Math.floor((height - 1 - y) / (natural * reduction)));
    const cx = (x + .5) / natural - .5, cy = (height - y - .5) / natural - .5;
    const ix = Math.floor(cx), iy = Math.floor(cy), fx = cx - ix, fy = cy - iy;
    const sum = [0, 0, 0];
    for (const [dx, dy, weight] of [[0, 0, (1 - fx) * (1 - fy)], [1, 0, fx * (1 - fy)], [0, 1, (1 - fx) * fy], [1, 1, fx * fy]]) {
      const rgb = pixel(ix + dx, iy + dy);
      for (let c = 0; c < 3; c++) sum[c] += rgb[c] * weight;
    }
    return sum.map(v => Math.floor(v + .5 + 1e-9));
  }
  return {
    render(box, extraRotation = 0) {
      const rotation = (orientation + extraRotation) % 4;
      const w = rotation % 2 ? height : width, h = rotation % 2 ? width : height;
      const scale = Math.min(box.width / w, box.height / h);
      const ow = Math.max(1, Math.floor(w * scale + 1e-10)), oh = Math.max(1, Math.floor(h * scale + 1e-10));
      const bw = rotation % 2 ? oh : ow, bh = rotation % 2 ? ow : oh;
      for (const layer of layers) {
        layer.reduction = 1;
        for (const r of [2, 4]) if (bw * layer.natural * r <= width && bh * layer.natural * r <= height) layer.reduction = r;
        assert.equal(layer.core.reconstruct(layer.reduction, 0, 0, 0, 0), 0);
        finish(layer.core); layer.image = result(layer.core);
      }
      const rgba = new Uint8Array(width * height * 4);
      for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
        const ink = (mask[y * stride + Math.floor(x / 8)] >> (7 - x % 8)) & 1;
        const [dx, dy] = rotation === 0 ? [x, y] : rotation === 1 ? [y, width - 1 - x]
          : rotation === 2 ? [width - 1 - x, height - 1 - y] : [height - 1 - y, x];
        rgba.set([...sample(layers[ink], x, y), 255], (dy * w + dx) * 4);
      }
      return fitReference({ width: w, height: h, rgba }, box);
    },
    close() { for (const layer of layers) { layer.core.close(); assert.equal(layer.core.live_bytes(), 0); } },
  };
}
