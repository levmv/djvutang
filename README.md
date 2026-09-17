# DjVuTang

DjVuTang is a small DjVu decoding library in Zig for rendering pages and covers
and extracting text. It provides a native API, an import-free WebAssembly module
and a browser Worker adapter.

Supports DjVu except for legacy DIR0/NDIR containers, WMRM and
arithmetic/lossless/12-bit JPEG.

## Build

Requires **Zig 0.16.0**.

```sh
make             # CLI and WASM in zig-out/bin
make dist        # WASM, browser modules and types in zig-out/dist
```

Use `make dist WASM_SIMD=true` to enable WebAssembly SIMD.

To render the first page as a PPM image:

```sh
zig-out/bin/djvutang fit book.djvu cover.ppm 1 800 1000
```

CLI page numbers start at 1; library and WASM page indexes start at 0.

## Use the library

Copy `zig-out/dist` into your web application. Given a document as an `ArrayBuffer`:

```js
import { DjvuDecoder } from './djvu/decoder.mjs';

const decoder = await DjvuDecoder.create();
try {
  await decoder.open(documentBytes); // Transfers this ArrayBuffer to the Worker.
  const image = await decoder.render(0, { size: { width: 800, height: 1000 } });
  // image contains width, height and rgba (an RGBA ArrayBuffer).
} finally {
  decoder.destroy();
}
```

- [Browser API](web/README.md) and [TypeScript example](examples/browser/preview.ts).
- [Native Zig example](examples/zig); public API in [root.zig](root.zig).
- Other WASM hosts: instantiate `djvutang.wasm` without imports;
  exports are in [wasm/main.zig](wasm/main.zig).
- [Demo reader](examples/reader/README.md): run `make reader`.

## Tests

`make test` requires Node 24. See [tests/README.md](tests/README.md) for other suites.

## License

[MIT](LICENSE). Third-party code and attributions are listed in
[THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt).
