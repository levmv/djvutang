// The real standalone entry point, local file picker, Worker, canvas and clipboard events.
// Usage: node examples/reader/tests/browser.mjs /path/to/playwright/index.mjs [output-directory]
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createReaderServer } from '../serve.mjs';

const playwright = await import(pathToFileURL(resolve(process.argv[2])));
const root = resolve(import.meta.dirname, '../../..');
const out = resolve(process.argv[3] ?? resolve(root, 'tests/out/reader'));
await mkdir(out, { recursive: true });
const server = createReaderServer();
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const url = `http://127.0.0.1:${server.address().port}`;
const results = [];

async function settled(page) {
  await page.waitForFunction(() => {
    const r = window.testReader;
    return r.geometry && !r.inFlight && r.visible.length > 0 && r.tiles.size === r.visible.length
      && document.querySelector('#viewport').getAttribute('aria-busy') === 'false';
  }, null, { timeout: 60000 });
}

async function openFile(page, name, buffer) {
  await page.locator('#file').setInputFiles(buffer
    ? { name, mimeType: 'image/vnd.djvu', buffer }
    : resolve(root, name));
}

async function metrics(page) {
  return page.evaluate(async () => {
    const { reader: r } = await import('/app.mjs');
    const canvases = [...r.tiles.values()];
    return { page: r.pageIndex, tiles: canvases.length, visible: r.visible.length,
      canvasBytes: canvases.reduce((sum, c) => sum + c.width * c.height * 4, 0),
      maxSide: Math.max(...canvases.flatMap(c => [c.width, c.height])),
      ...await r.decoder.diagnostics(), subsample: r.options.subsample, rotation: r.geometry.rotation,
      pageWidth: r.geometry.width, pageHeight: r.geometry.height };
  });
}

try {
  assert.equal((await fetch(url + '/web/../README.md')).status, 404);
  assert.equal((await fetch(url + '/', { method: 'POST', body: 'not a document upload' })).status, 405);
  for (const profile of [
    { name: 'chromium', engine: 'chromium', viewport: { width: 1280, height: 900 } },
    { name: 'webkit', engine: 'webkit', viewport: { width: 1280, height: 900 } },
    { name: 'mobile-webkit', engine: 'webkit', viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true },
  ]) {
    const browser = await playwright[profile.engine].launch({ headless: true });
    try {
      const { name, engine, ...options } = profile;
      const page = await browser.newPage(options);
      page.setDefaultTimeout(20000);
      if (engine === 'chromium') await page.context().grantPermissions(['clipboard-read', 'clipboard-write'], { origin: url });
      const pageErrors = [], requests = [];
      page.on('pageerror', error => pageErrors.push(String(error)));
      page.on('request', request => requests.push({ method: request.method(), url: request.url() }));
      await page.goto(url);
      await page.evaluate(async () => { window.testReader = (await import('/app.mjs')).reader; });
      await page.screenshot({ path: resolve(out, `${name}-welcome.png`) });
      await page.locator('#sample').click();
      await settled(page);
      const sample = await metrics(page);
      assert.equal(sample.page, 0);
      assert.equal(await page.locator('#page-count').textContent(), '/ 2');
      await page.waitForFunction(() => !document.querySelector('#text-toggle').disabled);
      await page.screenshot({ path: resolve(out, `${name}-page.png`) });
      await page.locator('#text-toggle').click();
      assert.match(await page.locator('#page-text').inputValue(), /Заметить привычное/);
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      await settled(page);
      assert.equal(await page.locator('#page-text').evaluate(el => el.scrollTop), 0);
      await page.screenshot({ path: resolve(out, `${name}-text.png`) });
      await page.locator('#text-close').click();
      await settled(page);
      await page.locator('#next').click();
      await settled(page);
      assert.equal((await metrics(page)).page, 1);
      await page.locator('#page-number').fill('1');
      await page.locator('#page-number').press('Enter');
      await settled(page);
      assert.equal((await metrics(page)).page, 0);
      await page.locator('#zoom').selectOption('1');
      await settled(page);

      const exact = await page.evaluate(async () => {
        const { reader: r } = await import('/app.mjs');
        const { DjvuDecoder } = await import('/web/decoder.mjs');
        const reference = await DjvuDecoder.create('/djvutang.wasm');
        try {
          await reference.open(await (await fetch('/sample.djvu')).arrayBuffer());
          const full = await reference.render(0, r.options), rgba = new Uint8Array(full.rgba);
          for (const [key, canvas] of r.tiles) {
            const [left, top] = key.split(':').map(Number);
            const data = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data;
            for (let y = 0; y < canvas.height; y++) for (let x = 0; x < canvas.width; x++) for (let c = 0; c < 4; c++)
              if (data[(y * canvas.width + x) * 4 + c] !== rgba[((top + y) * full.width + left + x) * 4 + c]) return false;
          }
          return true;
        } finally { reference.destroy(); }
      });
      assert.ok(exact);

      // A full RGBA of this page is 192 MiB. Inspect repeated distant viewports
      // at 1:1, including explicit disposal of detached canvas backing stores.
      await openFile(page, 'tests/fixtures/large-page.djvu');
      await settled(page);
      await page.locator('#zoom').selectOption('1');
      await settled(page);
      const large = [];
      for (const [x, y] of [[0, 0], [1000, 740], [3900, 2900], [9000, 9000], [0, 0]]) {
        await page.evaluate(async ({ x, y }) => {
          const { reader: r } = await import('/app.mjs');
          window.oldCanvases = [...r.tiles.values()];
          r.viewport.scrollTo(x, y);
          await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        }, { x, y });
        await settled(page);
        const m = await metrics(page); large.push(m);
        assert.ok(m.tiles <= 24 && m.canvasBytes <= 24 * 1024 * 1024 && m.maxSide <= 512);
        assert.ok(m.peakBytes < 64 * 1024 * 1024);
        assert.equal(m.pageWidth, 8192);
        assert.ok(await page.evaluate(() => window.oldCanvases.every(c => c.isConnected || c.width === 0 && c.height === 0)));
      }
      assert.equal(large[0].liveBytes, large.at(-1).liveBytes);

      await page.evaluate(async () => {
        const r = window.testReader;
        const { sourcePoint } = await import('/reader-model.mjs');
        window.centerSource = () => {
          const rect = r.viewport.getBoundingClientRect();
          return sourcePoint(r.geometry, r.scale, r.el.page.getBoundingClientRect(),
            rect.left + r.viewport.clientWidth / 2, rect.top + r.viewport.clientHeight / 2);
        };
        window.beforeZoom = window.centerSource();
        r.setZoom(1.5); r.setZoom(2);
      });
      await settled(page);
      assert.ok(await page.evaluate(() => {
        const after = window.centerSource();
        return Math.hypot(after.x - window.beforeZoom.x, after.y - window.beforeZoom.y) < 1;
      }));
      await page.locator('#zoom').selectOption('1'); await settled(page);

      if (!profile.hasTouch) {
        // Hold one real render result until after a disjoint scroll. Scrolling
        // must keep the decode/cache alive and discard the now invisible tile.
        await page.evaluate(async () => {
          const r = window.testReader, original = r.decoder.render.bind(r.decoder);
          const cancel = r.decoder.cancelRender.bind(r.decoder);
          window.scrollCancels = 0;
          r.decoder.render = async (...args) => {
            r.decoder.render = original;
            const result = await original(...args);
            await new Promise(resolve => { window.releaseTile = resolve; });
            return result;
          };
          r.decoder.cancelRender = (...args) => { window.scrollCancels++; return cancel(...args); };
          r.viewport.scrollTo(2200, 2200);
        });
        await page.waitForFunction(() => window.releaseTile);
        await page.evaluate(async () => {
          window.testReader.viewport.scrollTo(6000, 4800);
          await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
          window.releaseTile();
        });
        await settled(page);
        assert.equal(await page.evaluate(() => window.scrollCancels), 0);
        assert.ok(await page.evaluate(() => window.testReader.visible.every(t => t.x >= 5632 && t.y >= 4608)));
      }

      // Fault injection at the adapter boundary verifies a bounded retry and a
      // usable Retry action; real allocator failures are covered by core tests.
      for (const [method, code] of [['render', 'OutOfMemory'], ['render', 'LimitExceeded'], ['geometry', 'LimitExceeded']]) {
        await page.evaluate(({ method, code }) => {
          const r = window.testReader;
          window.restoreMemoryOperation = r.decoder[method].bind(r.decoder);
          window.memoryAttempts = 0;
          r.decoder[method] = () => { window.memoryAttempts++; return Promise.reject(Object.assign(new Error(code), { code })); };
          void r.layout();
        }, { method, code });
        await page.locator('#problem').waitFor({ state: 'visible' });
        assert.equal(await page.evaluate(() => window.memoryAttempts), 2);
        assert.match(await page.locator('#problem-text').textContent(), /memory/);
        await page.evaluate(method => { window.testReader.decoder[method] = window.restoreMemoryOperation; }, method);
        await page.locator('#retry').click(); await settled(page);
      }

      await openFile(page, 'tests/fixtures/text-a.djvu');
      await settled(page);
      await page.locator('#zoom').selectOption('4');
      await settled(page);
      const copies = [];
      if (!profile.hasTouch) {
        await page.evaluate(() => document.addEventListener('copy', event => { window.copied = event.clipboardData.getData('text/plain'); }));
        for (let rotation = 0; rotation < 4; rotation++) {
          const points = await page.evaluate(async () => {
            const { reader: r } = await import('/app.mjs');
            const { mapPoint } = await import('/web/decoder.mjs');
            const rect = r.el.page.getBoundingClientRect();
            return r.units.slice(0, 2).map(z => {
              const p = mapPoint(r.geometry.matrix, { x: z.x + z.width / 2, y: z.y + z.height / 2 });
              return { x: rect.left + p.x * r.scale, y: rect.top + p.y * r.scale };
            });
          });
          const [a, b] = rotation % 2 ? points.toReversed() : points;
          await page.mouse.move(a.x, a.y); await page.mouse.down();
          await page.mouse.move(b.x, b.y, { steps: 4 }); await page.mouse.up();
          await page.keyboard.press('Control+c');
          await page.waitForFunction(() => window.copied !== undefined);
          const copied = await page.evaluate(() => { const value = window.copied; delete window.copied; return value; });
          assert.equal(copied, 'AЖB é🙂 '); copies.push(copied);
          if (rotation === 0) {
            await page.screenshot({ path: resolve(out, `${name}-selection.png`) });
            await page.locator('#copy-selection').click();
            await page.waitForFunction(() => document.querySelector('#status').textContent === 'Text copied');
          }
          await page.locator('#rotate').click(); await settled(page);
        }
        await page.locator('#viewport').focus();
        await page.keyboard.press('Control+a'); await page.keyboard.press('Control+c');
        const fullText = JSON.parse(await readFile(resolve(root, 'tests/fixtures/text-expected.json'), 'utf8')).text;
        assert.equal(await page.evaluate(() => window.copied), fullText);
      }

      // Text survives a page image error, and an OCR error leaves image reading usable.
      const unsupported = Buffer.from(await readFile(resolve(root, 'tests/fixtures/text-z.djvu')));
      unsupported.write('BGzz', unsupported.indexOf('Sjbz'));
      await openFile(page, 'unsupported-image.djvu', unsupported);
      await page.locator('#problem').waitFor({ state: 'visible' });
      assert.match(await page.locator('#problem-text').textContent(), /not supported/);
      await page.waitForFunction(() => !document.querySelector('#text-toggle').disabled);
      await page.locator('#text-toggle').click();
      assert.match(await page.locator('#page-text').inputValue(), /AЖB/);
      await page.locator('#text-close').click();
      await openFile(page, 'tests/fixtures/bad-text.djvu');
      await settled(page);
      await page.waitForFunction(() => document.querySelector('#text-status').textContent === 'Text unavailable');

      await openFile(page, 'tests/fixtures/text-only.djvu'); await settled(page);
      await page.waitForFunction(() => document.querySelector('#text-status').textContent === 'Text without positions');
      await page.locator('#text-toggle').click();
      assert.equal(await page.locator('#page-text').inputValue(), '\ufeffA\x00Ж\nB\x0bC\x1dD\x1eE\x1f🙂');
      await page.locator('#text-close').click();

      const damaged = Buffer.from(await readFile(resolve(root, 'tests/fixtures/shared.djvu')));
      const info = damaged.indexOf('INFO'); damaged[info + 8] = damaged[info + 9] = 0;
      await openFile(page, 'damaged-first.djvu', damaged);
      await page.locator('#problem').waitFor({ state: 'visible' });
      await page.locator('#next').click(); await settled(page);
      assert.equal((await metrics(page)).page, 1);
      await openFile(page, 'bad-file.djvu', Buffer.from('not a DjVu document'));
      await page.locator('#open-error').waitFor({ state: 'visible' });
      await page.evaluate(() => window.testReader.openFile({ name: 'too-big.djvu', size: 0x100000000,
        slice() { throw new Error('Oversized file must be rejected before reading'); } }));
      assert.match(await page.locator('#open-error').textContent(), /exceeds the memory, size or complexity limit/);
      await page.locator('#sample').click(); await settled(page);

      // Latest document and view win, even when an old local read completes late.
      await page.evaluate(async () => {
        const { reader: r } = await import('/app.mjs');
        void r.openSource('delayed.djvu', () => new Promise(resolve => { window.finishRead = resolve; }));
      });
      await page.waitForFunction(() => window.finishRead);
      await openFile(page, 'tests/fixtures/shared.djvu'); await settled(page);
      await page.evaluate(async () => {
        window.finishRead(await (await fetch('/sample.djvu')).arrayBuffer());
        const { reader: r } = await import('/app.mjs');
        void r.goTo(1); void r.goTo(0); r.setZoom(2); r.rotation = 3; void r.layout();
      });
      await settled(page);
      assert.equal(await page.locator('#filename').textContent(), 'shared.djvu');
      const latest = await metrics(page);
      assert.equal(latest.page, 0); assert.equal(latest.rotation, 3); assert.equal(latest.pageWidth, 100);
      await page.locator('#close').click();
      assert.ok(await page.evaluate(async () => {
        const { reader: r } = await import('/app.mjs');
        return !r.decoder && r.tiles.size === 0 && !r.layer && !r.selection;
      }));
      assert.deepEqual(pageErrors, []);
      assert.ok(requests.every(r => r.method === 'GET' && r.url.startsWith(url + '/')));
      results.push({ browser: name, version: browser.version(), sample, sampleTilesExact: exact, large, unicodeCopies: copies.length,
        errorsRecover: true, boundedMemoryRetry: true, lateTileDiscarded: !profile.hasTouch, unzonedText: true,
        latestViewWins: true, closed: true, requestCount: requests.length, pageErrors });
      console.log(`${name}: reader, tiles, text, errors, replacement and close passed`);
    } finally { await browser.close(); }
  }
  await writeFile(resolve(out, 'results.json'), JSON.stringify(results, null, 2) + '\n');
} finally {
  await new Promise(resolve => server.close(resolve));
}
