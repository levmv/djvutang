# stb_image (JPEG only)

Upstream: nothings/stb at `2c980bb59875b0d32144a71867fbdebb2f77cd20`,
MIT option of the included LICENSE. Original `stb_image.h` SHA256:
`594c2fe35d49488b4382dbfaec8f98366defca819d916ac95becf3e75f4200b3`.

Local change: `stbi__jpeg.synthetic_bits` tracks zero refill at entropy EOF or
markers. The adapter rejects consumption of those synthetic bits; lookahead
alone remains allowed. This prevents truncated scans from inventing pixels.
The field is cleared by `stbi__jpeg_reset`.

The horizontal 2× chroma filter also corrects reversed weights at the right
edge: the nearest sample receives weight 3.

`src/jpeg_stb.c` uses the private Huffman, IDCT, marker and resampling routines.
It owns scheduling, allocation and output. The public whole-image loader is
unused. Keep this revision pinned; review the adapter when updating it.
