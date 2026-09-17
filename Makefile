ZIG ?= zig
CLANG ?= clang
PLAYWRIGHT ?= node_modules/playwright/index.mjs
NODE_MODULES ?= node_modules
FUZZ_RUNS ?= 100K
WASM_SIMD ?= false
ZIG_SOURCES = build.zig build.zig.zon root.zig tests.zig tests/native tests/wasm tests/support tests/fuzz/native.zig src tools/*.zig wasm examples/zig

.PHONY: all wasm dist test native-test wasm-test fuzz fuzz-jpeg oracle-test browser-test consumer-test reader reader-test
all:
	$(ZIG) build
	$(ZIG) build wasm -Dwasm-simd=$(WASM_SIMD)

wasm:
	$(ZIG) build wasm -Dwasm-simd=$(WASM_SIMD)

dist: wasm
	rm -rf zig-out/dist
	mkdir -p zig-out/dist
	cp zig-out/bin/djvutang.wasm web/decoder.mjs web/decoder.d.mts web/worker.mjs web/README.md LICENSE THIRD_PARTY_NOTICES.txt zig-out/dist/

test: native-test
	$(MAKE) wasm-test

native-test:
	$(ZIG) fmt --check --ast-check $(ZIG_SOURCES)
	$(ZIG) build test

wasm-test: wasm
	$(ZIG) build iw44-probe-wasm preview-probe-wasm heap-test-wasm -Dwasm-simd=$(WASM_SIMD)
	node tests/wasm/heap.mjs
	node tests/wasm/render.mjs
	node tests/wasm/regions.mjs
	node tests/wasm/sizing.mjs
	node tests/wasm/iw44-regions.mjs
	node tests/wasm/iw44-storage.mjs
	node tests/wasm/iw44-reduced.mjs
	node tests/wasm/preview.mjs
	node tests/wasm/source.mjs
	node tests/wasm/text.mjs
	node tests/wasm/components.mjs
	node tests/wasm/annotations.mjs
	node tests/wasm/outline.mjs
	node tests/wasm/thumbnails.mjs

fuzz:
	$(ZIG) fmt --check --ast-check $(ZIG_SOURCES)
	$(MAKE) wasm
	node tests/fuzz/native.mjs "$(ZIG)" $(FUZZ_RUNS)
	node tests/fuzz/wasm.mjs $(FUZZ_RUNS)

fuzz-jpeg:
	node tests/fuzz/jpeg.mjs "$(CLANG)" $(FUZZ_RUNS)

oracle-test: all
	$(ZIG) build iw44-probe-wasm -Dwasm-simd=$(WASM_SIMD)
	python3 tests/oracle/render.py
	node tests/wasm/regions.mjs tests/out --native
	node tests/wasm/sizing.mjs --native
	node tests/wasm/text.mjs --native --oracle
	node tests/wasm/components.mjs --native
	node tests/wasm/annotations.mjs --native --oracle
	node tests/wasm/outline.mjs --native --oracle
	node tests/wasm/thumbnails.mjs --native --oracle

browser-test: wasm
	node tests/browser/run.mjs "$(PLAYWRIGHT)"

consumer-test: dist
	node tests/consumers/run.mjs "$(ZIG)" "$(NODE_MODULES)"

reader: wasm
	node examples/reader/serve.mjs

reader-test: wasm
	node --test examples/reader/tests/model.mjs
	node examples/reader/tests/browser.mjs "$(PLAYWRIGHT)"
