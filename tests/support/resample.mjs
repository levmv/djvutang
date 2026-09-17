// Independent floating-point reference: resize a fully composed, rotated raster.
// The decoder instead combines layers at source samples and uses integer weights.
export function fitReference(image, box) {
  const scale = Math.min(box.width / image.width, box.height / image.height);
  const width = Math.max(1, Math.floor(image.width * scale + 1e-10));
  const height = Math.max(1, Math.floor(image.height * scale + 1e-10));
  const input = new Uint8Array(image.rgba);
  const rgba = new Uint8Array(width * height * 4);
  function samples(pixel, source, output) {
    if (output > source) {
      const center = (pixel + .5) * source / output - .5;
      const first = Math.floor(center), fraction = center - first;
      return [[Math.max(0, first), 1 - fraction], [Math.min(source - 1, first + 1), fraction]];
    }
    const left = pixel * source / output, right = (pixel + 1) * source / output;
    const result = [];
    for (let i = Math.floor(left); i < Math.ceil(right); i++)
      result.push([Math.min(source - 1, i), (Math.min(i + 1, right) - Math.max(i, left)) / (right - left)]);
    return result;
  }
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const sum = [0, 0, 0];
    for (const [sy, wy] of samples(y, image.height, height))
      for (const [sx, wx] of samples(x, image.width, width))
        for (let c = 0; c < 3; c++) sum[c] += input[(sy * image.width + sx) * 4 + c] * wx * wy;
    const at = (y * width + x) * 4;
    for (let c = 0; c < 3; c++) rgba[at + c] = Math.round(sum[c] + 1e-9);
    rgba[at + 3] = 255;
  }
  return { width, height, rgba };
}
