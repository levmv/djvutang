import { DjvuDecoder, type RandomAccessSource } from './djvu/decoder.mjs';

export async function preview(
  wasm: WebAssembly.Module,
  document: ArrayBuffer | RandomAccessSource,
  canvas: HTMLCanvasElement,
  workerUrl: string | URL,
  size?: { width: number; height: number },
) {
  const decoder = await DjvuDecoder.create(wasm, { workerUrl });
  try {
    const info = await decoder.open(document);
    const [image, text] = await Promise.all([decoder.render(0, { size }), decoder.text(0)]);
    canvas.width = image.width;
    canvas.height = image.height;
    const context = canvas.getContext('2d');
    if (!context) throw new Error('Canvas 2D is unavailable');
    context.putImageData(new ImageData(new Uint8ClampedArray(image.rgba), image.width, image.height), 0, 0);
    return { info, image, text };
  } finally {
    // Returned snapshots remain usable after the Worker is destroyed.
    decoder.destroy();
  }
}
