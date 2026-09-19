import type { DjvuDecoder, RandomAccessSource } from './djvu/decoder.mjs';

/** Reuse one decoder for sequential imports; destroy it after the batch. */
export async function inspectDocument(
  decoder: DjvuDecoder,
  input: ArrayBuffer | RandomAccessSource,
  coverSize?: { width: number; height: number },
) {
  try {
    await decoder.open(input);
    const metadata = await decoder.metadata();
    const cover = coverSize ? await decoder.render(0, { size: coverSize }) : null;
    return { metadata, cover };
  } finally {
    // Results own their data; release this document while keeping the Worker.
    await decoder.close();
  }
}
