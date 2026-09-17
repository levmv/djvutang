# Examples

These examples open single-page or bundled documents. Indirect documents also
need a component loader supplied by the host.

## Browser / TypeScript

Run `make dist` and copy `zig-out/dist` beside your application as `djvu/`.
[browser/preview.ts](browser/preview.ts) renders to a canvas and returns the image
and text. Pass a compiled WASM module, an ArrayBuffer or `{ size, read }` source,
and the Worker URL. The optional `size` fits the page inside a pixel box.
See the [browser API](../web/README.md).

## Native Zig

```sh
zig build --build-file examples/zig/build.zig run -- tests/fixtures/color.djvu /tmp/preview.ppm
```

Adjust the dependency path in `build.zig.zon` when copying the example.
Optional trailing width/height arguments fit the page to a box.
For reading a file in parts, see the [CLI](../tools/cli.zig).

## Demo reader

Run `make reader` for the [browser demo](reader/README.md).
