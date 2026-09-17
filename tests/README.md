# Tests

Run from the repository root with Zig 0.16.0 and Node 24:

```sh
make test
make test WASM_SIMD=true
```

| Suite | Command |
| --- | --- |
| Native decoder | `make native-test` (Zig only) |
| WASM ABI | `make wasm-test` (Zig and Node) |
| Browser Worker and adapter | `make browser-test` |
| Standalone Zig and browser consumers | `make consumer-test` |
| Demo reader | `make reader-test` |
| External decoder comparisons | `make oracle-test` |
| Native/WASM fuzzing | `make fuzz FUZZ_RUNS=100K` |
| JPEG fuzzing with sanitizers | `make fuzz-jpeg FUZZ_RUNS=100K` |

Browser, consumer and reader tests need `npm ci` and Playwright browsers.
External comparisons and fixture generators use the tools in the
[devcontainer](../.devcontainer/Dockerfile). `WASM_SIMD=true` also applies to
browser, consumer and oracle tests.

Native tests cover format details, allocation failures and decoder internals.
WASM tests cover the ABI and compare rendering with saved references. Browser
and consumer tests exercise loading, ownership, cancellation and integration.
The reader tests live with the demo in `examples/reader/tests`.

Fixtures are small synthetic inputs with saved references; normal tests need
no external decoder. `fixtures/cases.json` lists the shared rendering cases.
To regenerate an input, use its script in `generate/`; the script header lists
required tools and arguments. Keep indirect document directories together.

`out/` is disposable. Browser tests save screenshots there. The oracle runner
requests PPM images explicitly from `wasm/render.mjs`; ordinary WASM tests do
not save rendered images.
