// Usage: node tests/browser/run.mjs /path/to/playwright/index.mjs [output-directory]
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, readdir } from 'node:fs/promises';
import { createServer } from 'node:http';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const playwright = await import(pathToFileURL(resolve(process.argv[2])));
const root = resolve(import.meta.dirname, '../..');
const out = resolve(process.argv[3] ?? resolve(root, 'tests/out/browser'));
await mkdir(out, { recursive: true });
const routes = new Map([
  ['/djvutang.wasm', ['zig-out/bin/djvutang.wasm', 'application/wasm']],
  ['/web/decoder.mjs', ['web/decoder.mjs', 'text/javascript']],
  ['/web/worker.mjs', ['web/worker.mjs', 'text/javascript']],
  ['/tests/support/resample.mjs', ['tests/support/resample.mjs', 'text/javascript']],
]);
for (const name of ['api', 'source', 'text', 'components', 'annotations', 'outline', 'thumbnails', 'previews']) {
  const path = `tests/browser/${name}.mjs`;
  routes.set(`/${path}`, [path, 'text/javascript']);
}
for (const entry of await readdir(resolve(root, 'tests/fixtures'), { withFileTypes: true })) {
  const path = `tests/fixtures/${entry.name}`;
  if (entry.isDirectory()) {
    for (const file of await readdir(resolve(root, path)))
      routes.set(`/components/${entry.name}/${encodeURIComponent(file)}`, [`${path}/${file}`, 'application/octet-stream']);
  } else routes.set(`/${entry.name}`, [path, 'application/octet-stream']);
}
const server = createServer(async (request, response) => {
  try {
    if (request.url === '/') {
      response.setHeader('Content-Type', 'text/html');
      response.end('<!doctype html><meta charset="utf-8"><title>DjVuTang test</title><style>body{background:#ddd;padding:16px;font:14px sans-serif;display:flex;flex-wrap:wrap;gap:20px}figure{margin:0}figcaption{margin-bottom:6px}canvas{display:block;background:white;image-rendering:pixelated}#page{width:320px;height:200px}</style><figure><figcaption>JB2 shared dictionary</figcaption><canvas id="page"></canvas></figure>');
      return;
    }
    const route = routes.get(request.url);
    if (!route) { response.writeHead(404); response.end(); return; }
    response.setHeader('Content-Type', route[1]);
    response.end(await readFile(resolve(root, route[0])));
  } catch (error) { response.writeHead(500); response.end(String(error)); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const results = [];
try {
  for (const name of ['chromium', 'webkit']) {
    const browser = await playwright[name].launch({ headless: true });
    try {
      const page = await browser.newPage({ viewport: { width: 1120, height: 760 } });
      await page.goto(`http://127.0.0.1:${server.address().port}/`);
      const result = await page.evaluate(async () => {
        const { DjvuDecoder } = await import('/web/decoder.mjs');
        const decoder = await DjvuDecoder.create('/djvutang.wasm');
        const bytes = url => fetch(url).then(r => r.arrayBuffer());
        const digest = async buffer => [...new Uint8Array(await crypto.subtle.digest('SHA-256', buffer))].map(b => b.toString(16).padStart(2, '0')).join('');
        try {
          const opened = await decoder.open(await bytes('/shared.djvu'));
          const old = decoder.render(0).then(() => 'unexpected completion', e => e.code);
          await decoder.cancelRender();
          const cancelled = await old;
          const first = await decoder.render(0);
          const firstStats = await decoder.diagnostics();
          const small = await decoder.render(0, { subsample: 3 });
          const again = await decoder.render(0);
          const sameAfterZoom = await digest(first.rgba) === await digest(again.rgba);
          const second = await decoder.render(1);
          const secondStats = await decoder.diagnostics();
          const originalHash = await digest(second.rgba);
          await decoder.dropCache();
          const afterDrop = await decoder.render(1);
          const afterDropStats = await decoder.diagnostics();
          const sameAfterDrop = await digest(afterDrop.rgba) === originalHash;
          const superseded = decoder.render(0).then(() => 'unexpected completion', e => e.code);
          const latest = await decoder.render(1);
          const supersededStatus = await superseded;
          const canvas = document.querySelector('canvas');
          canvas.width = latest.width; canvas.height = latest.height;
          const ctx = canvas.getContext('2d');
          ctx.putImageData(new ImageData(new Uint8ClampedArray(latest.rgba), latest.width, latest.height), 0, 0);
          let exact = true;
          const rgba = ctx.getImageData(0, 0, 160, 100).data;
          for (let y = 0; y < 100; y++) for (let x = 0; x < 160; x++) {
            const lx = x % 20, ly = y % 18;
            const black = x > 20 && y > 10 && ((lx === 3 && ly >= 3 && ly <= 12)
              || ([3, 7, 12].includes(ly) && lx >= 3 && lx <= 10)
              || (Math.floor(x / 20) % 2 === 1 && lx === 10 && ly >= 3 && ly <= 7));
            const p = (y * 160 + x) * 4;
            if (rgba[p] !== (black ? 0 : 255) || rgba[p + 3] !== 255) exact = false;
          }
          const replacement = await bytes('/rotated.djvu');
          const closing = decoder.render(0).then(() => 'unexpected completion', e => e.code);
          await decoder.open(replacement);
          const replaced = await closing;
          const rotated = await decoder.render(0);
          const damaged = new Uint8Array(await bytes('/shared.djvu'));
          const marker = new TextEncoder().encode('INFO');
          const offset = damaged.findIndex((_, i) => marker.every((b, j) => damaged[i + j] === b));
          damaged[offset + 8] = damaged[offset + 9] = 0;
          const damagedInfo = await decoder.open(damaged.buffer);
          const beforePageError = await decoder.render(1);
          const damagedPage = await decoder.render(0).then(() => 'unexpected completion', e => e.code);
          const goodPage = await decoder.render(1);
          const sameAfterPageError = new Uint8Array(goodPage.rgba)
            .every((b, i) => b === new Uint8Array(beforePageError.rgba)[i]);
          const memoryError = await decoder.open(await bytes('/shared.djvu'), { memoryLimit: 128 })
            .then(() => 'unexpected completion', e => e.code);
          await decoder.open(await bytes('/plain.djvu'));
          const afterMemoryError = await decoder.render(0);
          const colorChecks = [];
          const tileChecks = [];
          for (const [name, reference] of [
            ['color', 'color-expected'], ['compound', 'compound-reference'],
            ['jpeg-progressive', 'jpeg-progressive-reference'],
          ]) {
            await decoder.open(await bytes(`/${name}.djvu`));
            const image = await decoder.render(0);
            const original = await digest(image.rgba);
            await decoder.render(0, { subsample: 3 });
            const again = await decoder.render(0);
            const warmExact = await digest(again.rgba) === original;
            const ppm = new Uint8Array(await bytes(`/${reference}.ppm`));
            const marker = new TextEncoder().encode('\n255\n');
            const header = ppm.findIndex((_, i) => marker.every((b, j) => ppm[i + j] === b)) + marker.length;
            const rgb = ppm.subarray(header);
            const rgba = new Uint8Array(image.rgba);
            const exact = rgb.length * 4 === rgba.length * 3 && rgb.every((b, i) => b === rgba[Math.floor(i / 3) * 4 + i % 3]);
            const figure = document.createElement('figure');
            const caption = document.createElement('figcaption');
            caption.textContent = name;
            const canvas = document.createElement('canvas');
            canvas.width = image.width; canvas.height = image.height;
            canvas.style.width = `${image.width * 4}px`; canvas.style.height = `${image.height * 4}px`;
            canvas.getContext('2d').putImageData(new ImageData(new Uint8ClampedArray(image.rgba), image.width, image.height), 0, 0);
            figure.append(caption, canvas); document.body.append(figure);
            colorChecks.push({ name, exact, warmExact, maxStepMs: (await decoder.diagnostics()).maxStepMs });
            const ss = 3, rotation = 1;
            const options = { subsample: ss, rotation };
            const pending = decoder.render(0, options);
            const geometry = await decoder.geometry(0, options);
            const full = await pending;
            const assembled = new Uint8ClampedArray(full.rgba.byteLength);
            let dimensionsExact = geometry.width === full.width && geometry.height === full.height;
            const regions = [];
            for (let y = 0; y < full.height; y += 13) for (let x = 0; x < full.width; x += 17) {
              regions.push({ x, y, width: Math.min(17, full.width - x), height: Math.min(13, full.height - y) });
            }
            for (const region of regions.reverse()) {
              const tile = await decoder.render(0, { ...options, region });
              dimensionsExact &&= tile.x === region.x && tile.y === region.y && tile.width === region.width
                && tile.height === region.height && tile.stride === region.width * 4
                && tile.pageWidth === full.width && tile.pageHeight === full.height;
              const rgba = new Uint8Array(tile.rgba);
              for (let y = 0; y < tile.height; y++) assembled.set(rgba.subarray(y * tile.stride, (y + 1) * tile.stride),
                ((tile.y + y) * full.width + tile.x) * 4);
            }
            const assembledExact = await digest(assembled) === await digest(full.rgba);
            tileChecks.push({ name, subsample: ss, rotation, tiles: regions.length, dimensionsExact, assembledExact });
            if (name === 'compound') {
              const figure = document.createElement('figure');
              const caption = document.createElement('figcaption');
              caption.textContent = 'compound · rotated · assembled tiles';
              const canvas = document.createElement('canvas');
              canvas.width = full.width; canvas.height = full.height;
              canvas.style.width = `${full.width * 4}px`; canvas.style.height = `${full.height * 4}px`;
              canvas.getContext('2d').putImageData(new ImageData(assembled, full.width, full.height), 0, 0);
              figure.append(caption, canvas); document.body.append(figure);
            }
          }
          await decoder.open(await bytes('/large-page.djvu'));
          const largeGeometry = await decoder.geometry(0);
          const tileOptions = { region: { x: 0, y: 0, width: 256, height: 256 } };
          const firstTile = await decoder.render(0, tileOptions);
          const firstTileStats = await decoder.diagnostics();
          const firstHash = await digest(firstTile.rgba);
          const fullPageMemoryError = await decoder.render(0).then(() => 'unexpected completion', e => e.code);
          const recoveredTile = await decoder.render(0, tileOptions);
          const tileErrors = [];
          for (const region of [
            {}, { x: -1, y: 0, width: 1, height: 1 }, { x: 0.5, y: 0, width: 1, height: 1 },
            { x: NaN, y: 0, width: 1, height: 1 }, { x: 0, y: 0, width: 0, height: 1 },
            { x: 0, y: 6144, width: 1, height: 1 }, { x: 8191, y: 0, width: 2, height: 1 },
            { x: 1, y: 1, width: 0xffffffff, height: 0xffffffff },
            { x: 2 ** 32, y: 0, width: 1, height: 1 },
          ]) tileErrors.push(await decoder.render(0, { region }).then(() => 'unexpected completion', e => e.code));
          const obsoleteTile = decoder.render(0, tileOptions).then(() => 'unexpected completion', e => e.code);
          const finalTile = await decoder.render(0, { region: { x: 7936, y: 5888, width: 256, height: 256 } });
          const tileSuperseded = await obsoleteTile;
          // A small cached tile can finish in one core step. Use a larger tile
          // so cancellation exercises pending work across Worker yields.
          const duringTile = decoder.render(0, { region: { x: 0, y: 0, width: 1024, height: 1024 } })
            .then(() => 'unexpected completion', e => e.code);
          await decoder.cancelRender();
          const tileCancelled = await duringTile;
          const afterTileCancellation = await decoder.render(0, tileOptions);
          const tileRecoveryExact = firstHash === await digest(recoveredTile.rgba)
            && firstHash === await digest(afterTileCancellation.rgba) && firstHash === await digest(firstTile.rgba);
          const largeTile = { geometry: largeGeometry, fullPageMemoryError, rgbaBytes: firstTile.rgba.byteLength,
            liveBytes: firstTileStats.liveBytes, peakBytes: firstTileStats.peakBytes,
            tileErrors, tileSuperseded, tileCancelled, tileRecoveryExact,
            cornerPixel: [...new Uint8Array(finalTile.rgba).slice(-4)] };
          const { runTextChecks } = await import('/tests/browser/text.mjs');
          await runTextChecks(decoder, bytes, digest);
          const { testApi } = await import('/tests/browser/api.mjs');
          await testApi(bytes);
          const { testSource } = await import('/tests/browser/source.mjs');
          await testSource(bytes);
          const { testComponents } = await import('/tests/browser/components.mjs');
          await testComponents(DjvuDecoder, bytes);
          const { testAnnotations } = await import('/tests/browser/annotations.mjs');
          await testAnnotations(DjvuDecoder, bytes);
          const { testOutline } = await import('/tests/browser/outline.mjs');
          await testOutline(DjvuDecoder, bytes);
          const { testThumbnails } = await import('/tests/browser/thumbnails.mjs');
          await testThumbnails(DjvuDecoder, bytes);
          const { testPreviews } = await import('/tests/browser/previews.mjs');
          await testPreviews(DjvuDecoder, bytes, digest);
          await decoder.close();
          const closed = await decoder.diagnostics();
          return { isolated: crossOriginIsolated, pages: opened.pages.length, cancelled,
            sameAfterZoom, sameAfterDrop, supersededStatus, replaced,
            pixelsExact: exact, rotated: [rotated.width, rotated.height],
            dictionaryDecodesBeforeDrop: secondStats.dictionaryDecodes,
            dictionaryDecodesAfterDrop: afterDropStats.dictionaryDecodes,
            liveAfterClose: closed.liveBytes,
            damagedInfo: damagedInfo.pages[0].error, damagedPage,
            goodPageAfterError: [goodPage.width, goodPage.height], sameAfterPageError, memoryError,
            afterMemoryError: [afterMemoryError.width, afterMemoryError.height],
            colorChecks, tileChecks, largeTile,
            small: [small.width, small.height],
            maxStepMs: Math.max(firstStats.maxStepMs, secondStats.maxStepMs, afterDropStats.maxStepMs) };
        } finally { decoder.destroy(); }
      });
      assert.equal(result.pages, 2);
      assert.equal(result.cancelled, 'Cancelled');
      assert.equal(result.supersededStatus, 'Cancelled');
      assert.equal(result.replaced, 'Cancelled');
      assert.equal(result.sameAfterZoom, true);
      assert.equal(result.sameAfterDrop, true);
      assert.equal(result.pixelsExact, true);
      assert.equal(result.dictionaryDecodesBeforeDrop, 1);
      assert.equal(result.dictionaryDecodesAfterDrop, 2);
      assert.deepEqual(result.rotated, [29, 37]);
      assert.equal(result.liveAfterClose, 0);
      assert.equal(result.isolated, false);
      assert.equal(result.damagedInfo, 'InvalidData');
      assert.equal(result.damagedPage, 'InvalidData');
      assert.deepEqual(result.goodPageAfterError, [160, 100]);
      assert.equal(result.sameAfterPageError, true);
      assert.equal(result.memoryError, 'LimitExceeded');
      assert.deepEqual(result.afterMemoryError, [37, 29]);
      for (const color of result.colorChecks) {
        assert.equal(color.exact, true, color.name);
        assert.equal(color.warmExact, true, color.name);
      }
      for (const tile of result.tileChecks) {
        assert.equal(tile.dimensionsExact, true, JSON.stringify(tile));
        assert.equal(tile.assembledExact, true, JSON.stringify(tile));
      }
      assert.deepEqual([result.largeTile.geometry.width, result.largeTile.geometry.height], [8192, 6144]);
      assert.equal(result.largeTile.fullPageMemoryError, 'LimitExceeded');
      assert.equal(result.largeTile.rgbaBytes, 256 * 256 * 4);
      assert(result.largeTile.peakBytes < 8 * 1024 * 1024);
      assert(result.largeTile.tileErrors.every(e => e === 'InvalidArgument'));
      assert.equal(result.largeTile.tileSuperseded, 'Cancelled');
      assert.equal(result.largeTile.tileCancelled, 'Cancelled');
      assert.equal(result.largeTile.tileRecoveryExact, true);
      assert.deepEqual(result.largeTile.cornerPixel, [0, 0, 0, 255]);
      await page.screenshot({ path: resolve(out, `${name}.png`), fullPage: true });
      results.push({ engine: name, version: browser.version(), ...result });
    } finally { await browser.close(); }
  }
} finally { await new Promise(resolve => server.close(resolve)); }
await writeFile(resolve(out, 'results.json'), JSON.stringify(results, null, 2) + '\n');
console.log(`Browser checks passed: ${results.map(r => r.engine).join(', ')}`);
