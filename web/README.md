# DjVuTang: WASM and browser modules

Use `decoder.mjs`, `decoder.d.mts`, `worker.mjs` and `djvutang.wasm` from the same
build and keep them together.
Serve `.mjs` as JavaScript and `.wasm` as `application/wasm`.
The WASM file also runs in non-browser hosts without WASI or host imports.

The default build is scalar. `make dist WASM_SIMD=true` produces a module that
requires WebAssembly 128-bit SIMD support, with the same file name and ABI.
The adapter loads the supplied module; hosts that need both variants can select
the appropriate URL, bytes or compiled module before creating the decoder.

Given a document `ArrayBuffer` and a canvas:

```js
import { DjvuDecoder } from './decoder.mjs';

const decoder = await DjvuDecoder.create();
try {
  await decoder.open(documentBytes);
  const image = await decoder.render(0);
  canvas.width = image.width;
  canvas.height = image.height;
  canvas.getContext('2d').putImageData(
    new ImageData(new Uint8ClampedArray(image.rgba), image.width, image.height), 0, 0);
} finally {
  decoder.destroy();
}
```

`open` transfers the input buffer to the Worker. Results own their buffers and
remain usable after another operation or `destroy`. Page indexes start at zero.
One decoder holds one document and one render job. `render` and `storedThumbnail`
share that job: a new request cancels the previous unfinished one with `Cancelled`.
Render tiles sequentially. Text and other metadata reads can run during rendering.

- `cancelRender()` stops the render/thumbnail; metadata reads continue.
- `dropCache()` cancels pending operations and releases cached components and layers.
- `close()` cancels pending operations and releases the document, keeping the Worker for another `open`.
- `destroy()` synchronously cancels pending operations and terminates the Worker;
  it is safe to repeat. The other methods are asynchronous.

For a bundled app with separate asset paths, supply both explicitly:

```js
const decoder = await DjvuDecoder.create('/assets/djvutang.wasm', {
  workerUrl: '/assets/djvu-worker.mjs',
});
```

The first argument also accepts WASM bytes or a compiled `WebAssembly.Module`.
This lets the application own fetching and share compilation across decoders.
Each decoder still gets its own Worker and WASM instance. When bundling, retain
ESM `import.meta` support for default relative URLs, or pass explicit asset URLs.

`render(page, { size, subsample, rotation, region })` uses:

- `size: { width, height }`: fit inside this pixel box, preserving aspect ratio.
  Dimensions round down, to at least one pixel. Can enlarge; excludes `subsample != 1`.
  Shrinking uses area averages; enlargement uses bilinear filtering.
  IW44 layers reconstruct at a reduced resolution when shrinking, so pixels can
  differ from resizing a full-resolution image. Tiles at the same size agree.
- `subsample`: integer reduction, 1..256; 2 halves each dimension.
  Uses full IW44 reconstruction; rounding can differ from `size` rendering.
- `rotation`: 0..3 counterclockwise quarter turns, added to the stored page orientation.
- `region`: a rectangle in output pixels after reduction and rotation, with a top-left origin.

`geometry()` supplies dimensions and coordinate transforms without decoding layers.
`text()`, `annotations()` and `outline()` return owned snapshots or `null` when absent.
`storedThumbnail()` decodes a stored thumbnail at its original size/orientation,
or returns `null`; a cover can use `render(0, { size: { width: 800, height: 1000 } })`.
Indirect documents use the `open` option `loadComponent`; the application resolves
component IDs to its own files or URLs. `open` returns a snapshot of page information;
use `geometry` for dimensions of pages loaded later.

## Reading a file in parts

`open` also accepts an immutable `{ size, read(offset, length, { signal }) }` source.
For a browser `File` or `Blob`:

```js
await decoder.open({
  size: file.size,
  read: (offset, length) => file.slice(offset, offset + length).arrayBuffer(),
});
const cover = await decoder.render(0, { size: { width: 800, height: 1000 } });
```

Return exactly the requested bytes in a fresh ArrayBuffer; it is transferred to
the Worker. The input must remain unchanged until close. Reads may overlap or
run concurrently, and `signal` allows the host to cancel IO. An HTTP host can
implement this with `Range: bytes=offset-end`, checking the 206 response and
`Content-Range`; authentication, version consistency and caching belong to the host.

Bundled documents open from DIRM and optional NAVM, using directory sizes to skip
components.
Component headers are checked when loaded; zero directory sizes require header
reads during opening. Gaps are scanned for metadata, including late NAVM.
Pages load on demand; evicted components are read again when needed.
Single-page DjVu, IW44 and THUM inputs are read whole. An indirect index
can use a range source too; its external files still use `loadComponent`.
The source may be up to `0xffffffff` bytes; the memory budget counts retained
bytes, not the file's size.

## Errors and measurements

Operational failures reject with `DjvuError`. Import it from `decoder.mjs` and
branch on `error instanceof DjvuError` and `error.code`, rather than message text.
`Cancelled` identifies superseded or cancelled operations; calls after `destroy`
reject with `Destroyed`. `WasmLoadFailed` covers loading/compilation, `WorkerFailed`
covers Worker setup/execution, `ComponentLoadFailed` covers the component loader,
and `SourceReadFailed` covers the range reader. A short or non-ArrayBuffer response
is `InvalidArgument`. Failed page reads can be retried; failed opening needs a new `open`.
The declarations list all codes, including format errors and memory limits.

For measurements, `await decoder.diagnostics()` returns allocation counters and
timing of the most recently started render/thumbnail, including cancelled work.
`open` and `close` reset that timing. `liveBytes` and `peakBytes` measure budgeted
allocations; `cacheBytes` is the reclaimable portion in components/dictionaries.
`linearBytes` measures allocated WASM capacity, including unused allocator blocks.
All exclude JS buffers and Canvas.

`open(source, { memoryLimit })` limits requested live core allocations in bytes
(64 MiB by default, at most 256 MiB). Budget exhaustion reports `LimitExceeded`;
failure of the underlying allocator reports `OutOfMemory`. Format/complexity
limits also use `LimitExceeded`. A larger budget does not guarantee that a page
fits within the module's 256 MiB linear memory maximum: allocation rounding and
previous allocation sizes also matter.

For core `LimitExceeded` errors, `message` names the operation (opening, render
start/step/restart, or metadata). Memory budget refusals include the requested
allocation size, the allocation it would replace (zero for a new allocation),
live bytes and the budget at the moment of refusal, before cleanup. Other
format/complexity limits may only identify the operation. Message text can change;
use `code` for program logic.

`open(source, { cacheLimit })` sets the idle cache target, from zero to
`memoryLimit`. It defaults to one quarter of `memoryLimit` (16 MiB).
Older components and dictionaries are evicted between independent operations;
the source and component provider must support repeat reads of unchanged content.
Active work and same-page restarts retain their dependencies. Input/index bytes,
decoded layers and results are outside this cache target. Setting it to
`memoryLimit` retains caches until explicitly dropped or closed.

Retained compressed input has a separate 128 MiB limit. Tiles reduce output
memory, but coefficients, masks and JPEG rasters can still dominate the working
set. `dropCache()` releases cached components and layers before a retry.

Freed large WASM buffers can be reused across different allocation sizes.
`close()` releases objects but does not shrink the instance's linear memory.
Use `destroy()` when disposing of the instance; a new decoder may reuse the
compiled module. Owned results remain with the caller until the caller releases
them, independently of either method.
