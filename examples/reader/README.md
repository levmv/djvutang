# DjVuTang reader

An optional browser demo of the library: local files, page navigation, zoom,
rotation, tiles and text selection. The UI is plain HTML, CSS and JavaScript.
It uses the public browser adapter in `web/` and the built WASM module.

From the repository root, with Zig 0.16.0 and Node 24:

```sh
make reader              # http://127.0.0.1:4173
```

No npm install or bundler is needed to run it. Files selected in the UI stay in
the browser. The demo opens single-page and bundled documents.

For a different port, run `make wasm`, then
`node examples/reader/serve.mjs 8080`. `HOST` sets the listening address;
the default is `127.0.0.1`.

## Tests

```sh
npm ci
npx playwright install --with-deps chromium webkit
make reader-test
```

Browser checks cover Chromium, WebKit and a mobile WebKit profile; screenshots
go to `tests/out/reader` at the repository root.

`generate-sample.mjs` rebuilds the sample using Chromium and DjVuLibre tools:

```sh
node examples/reader/generate-sample.mjs node_modules/playwright/index.mjs
```
