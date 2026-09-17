// Build and run real consumers from a temporary directory outside the project.
// Optional: Zig and an npm directory containing esbuild, TypeScript, Playwright.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = resolve(import.meta.dirname, '../..');
const zig = process.argv[2] ?? 'zig';
const modules = resolve(process.argv[3] ?? 'node_modules');
const esbuild = await import(pathToFileURL(join(modules, 'esbuild/lib/main.js')));
const playwright = await import(pathToFileURL(join(modules, 'playwright/index.mjs')));
const out = join(root, 'tests/out/consumers');
const temp = await mkdtemp(join(tmpdir(), 'djvu-consumers-'));
await mkdir(out, { recursive: true });
const fixtures = join(root, 'tests/fixtures');
function run(command, args, cwd = temp, env = {}) {
  const result = spawnSync(command, args, { cwd, env: { ...process.env, ...env }, encoding: 'utf8', timeout: 180000 });
  if (result.status !== 0 || result.error) throw new Error(`${command} ${args.join(' ')}\n${result.stdout}\n${result.stderr}\n${result.error ?? ''}`);
  return result.stdout.trim();
}
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const rgb = ppm => ppm.subarray(ppm.indexOf('\n255\n') + 5);
let server;
try {
  await cp(join(root, 'zig-out/dist'), join(temp, 'djvu'), { recursive: true });
  await cp(join(root, 'examples/browser/preview.ts'), join(temp, 'preview.ts'));
  run(process.execPath, [join(modules, 'typescript/bin/tsc'), '--strict', '--noEmit', '--target', 'es2018', '--module', 'esnext', '--moduleResolution', 'bundler', '--lib', 'es2018,dom', 'preview.ts']);
  for (const bundle of [false, true]) await esbuild.build({
    absWorkingDir: temp, entryPoints: ['preview.ts'], bundle, format: 'esm', target: 'es2020',
    outfile: join(temp, bundle ? 'bundled.mjs' : 'plain.mjs'), logLevel: 'silent',
  });
  // Explicit asset paths also work in classic script bundles, where
  // import.meta cannot supply default URLs.
  await esbuild.build({ absWorkingDir: temp, entryPoints: ['preview.ts'], bundle: true,
    format: 'iife', globalName: 'DjvuPreview', target: 'es2018', outfile: join(temp, 'iife.js'), logLevel: 'silent' });
  await mkdir(join(temp, 'assets'));
  await cp(join(temp, 'djvu/worker.mjs'), join(temp, 'assets/decoder-worker.mjs'));

  await cp(join(root, 'examples/zig'), join(temp, 'native'), {
    recursive: true, filter: source => !source.split('/').some(part => ['.zig-cache', 'zig-out', 'zig-pkg'].includes(part)),
  });
  // Fetch uses the package manifest's inclusion list. A local directory import
  // alone would hide a missing source file in the published package.
  const archive = join(temp, 'source.tar.gz');
  run('tar', ['-czf', archive, '-C', root,
    'build.zig', 'build.zig.zon', 'root.zig', 'src', 'vendor', 'wasm',
    'tools/cli.zig', 'tools/bench.zig',
    'tests.zig', 'tests/native', 'tests/fixtures', 'tests/support', 'tests/wasm', 'tests/fuzz',
    'README.md', 'LICENSE', 'THIRD_PARTY_NOTICES.txt']);
  const manifest = await readFile(join(temp, 'native/build.zig.zon'), 'utf8');
  const cache = join(temp, 'cache');
  const packageHash = run(zig, ['fetch', '--global-cache-dir', cache, archive], join(temp, 'native'));
  await mkdir(join(temp, 'package'));
  run('tar', ['-xzf', join(cache, 'p', `${packageHash}.tar.gz`), '--strip-components=1', '-C', join(temp, 'package')]);
  await writeFile(join(temp, 'native/build.zig.zon'), manifest.replace('.path = "../.."', '.path = "../package"'));
  run(zig, ['build', '-Doptimize=ReleaseSafe'], join(temp, 'native'));
  const native = join(temp, 'native/zig-out/bin/preview');
  const cases = [
    { name: 'color', reference: 'color-expected', pages: 1, text: null },
    { name: 'jpeg-progressive', reference: 'jpeg-progressive-reference', pages: 1, text: null },
    { name: 'text-z', pages: 1, text: JSON.parse(await readFile(join(fixtures, 'text-expected.json'))).text },
    { name: 'shared', pages: 2, text: null },
  ];
  const routes = new Map([
    ['/djvu/decoder.mjs', ['djvu/decoder.mjs', 'text/javascript']],
    ['/djvu/worker.mjs', ['djvu/worker.mjs', 'text/javascript']],
    ['/djvu/djvutang.wasm', ['djvu/djvutang.wasm', 'application/wasm']],
    ['/assets/decoder-worker.mjs', ['assets/decoder-worker.mjs', 'text/javascript']],
    ['/plain.mjs', ['plain.mjs', 'text/javascript']], ['/bundled.mjs', ['bundled.mjs', 'text/javascript']],
    ['/iife.js', ['iife.js', 'text/javascript']],
  ]);
  const results = [];
  for (const item of cases) {
    const input = join(fixtures, `${item.name}.djvu`);
    run(native, [input, join(temp, `${item.name}.ppm`)]);
    const nativePPM = await readFile(join(temp, `${item.name}.ppm`));
    if (item.reference) assert.deepEqual(rgb(nativePPM), rgb(await readFile(join(fixtures, `${item.reference}.ppm`))));
    run(native, [input, join(temp, `${item.name}-fit.ppm`), '37', '51']);
    routes.set(`/${item.name}-fit.ppm`, [`${item.name}-fit.ppm`, 'application/octet-stream']);
    await cp(input, join(temp, `${item.name}.djvu`));
    for (const ext of ['djvu', 'ppm'])
      routes.set(`/${item.name}.${ext}`, [`${item.name}.${ext}`, 'application/octet-stream']);
    results.push({ fixture: item.name, rgbSHA256: hash(rgb(nativePPM)) });
  }
  server = createServer(async (request, response) => {
    if (request.url === '/') {
      response.setHeader('Content-Type', 'text/html');
      response.end('<!doctype html><meta charset="utf-8"><title>DjVu consumers</title><style>body{font:16px sans-serif;background:#eee}canvas{background:white;margin:12px;image-rendering:pixelated;min-width:180px}</style><h1>Standalone DjVu consumers</h1>');
      return;
    }
    const route = routes.get(request.url);
    if (!route) { response.writeHead(404).end(); return; }
    try { response.setHeader('Content-Type', route[1]); response.end(await readFile(join(temp, route[0]))); }
    catch { response.writeHead(500).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}`;
  for (const engine of ['chromium', 'webkit']) {
    const browser = await playwright[engine].launch({ headless: true });
    try {
      const page = await browser.newPage();
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      await page.goto(url);
      await page.addScriptTag({ url: `${url}/iife.js` });
      const checked = await page.evaluate(async cases => {
        const { DjvuDecoder } = await import('/djvu/decoder.mjs');
        const bytes = async path => (await fetch(path)).arrayBuffer();
        const module = await WebAssembly.compile(await bytes('/djvu/djvutang.wasm'));
        const results = [];
        for (const entry of ['plain', 'bundled', 'iife']) {
          const { preview } = entry === 'iife' ? window.DjvuPreview : await import(`/${entry}.mjs`);
          for (const { name, pages, text } of cases) {
            const canvas = document.createElement('canvas'); document.body.append(canvas);
            for (const fitted of [false, true]) {
              const data = await bytes(`/${name}.djvu`);
              const input = fitted ? { size: data.byteLength, read: (offset, length) => data.slice(offset, offset + length) } : data;
              const suffix = fitted ? '-fit' : '';
              const result = await preview(module, input, canvas, '/assets/decoder-worker.mjs', fitted ? { width: 37, height: 51 } : undefined);
              const rgba = new Uint8Array(result.image.rgba);
              const ppm = new Uint8Array(await bytes(`/${name}${suffix}.ppm`));
              const marker = new TextEncoder().encode('\n255\n');
              const offset = ppm.findIndex((_, i) => marker.every((v, j) => ppm[i+j] === v)) + marker.length;
              const rgb = ppm.subarray(offset);
              const exact = rgb.length * 4 === rgba.length * 3 && rgb.every((v, i) => v === rgba[Math.floor(i/3)*4+i%3]);
              const metadataExact = result.info.pages.length === pages && (result.text?.text ?? null) === text;
              results.push({ name, entry, fitted, exact, metadataExact, inputLifetime: fitted ? data.byteLength > 0 : data.byteLength === 0 });
            }
          }
        }
        // Defaults use resources beside the relocated module. Compiled modules
        // and views into larger buffers also work, without another download.
        const all = await bytes('/djvu/djvutang.wasm');
        const padded = new Uint8Array(all.byteLength + 14); padded.set(new Uint8Array(all), 7);
        for (const source of [undefined, '/djvu/djvutang.wasm', padded.subarray(7, -7), module]) {
          const decoder = await DjvuDecoder.create(source);
          try { await decoder.open(await bytes('/color.djvu')); await decoder.render(0); }
          finally { decoder.destroy(); }
        }
        return results;
      }, cases);
      for (const item of checked) assert(item.exact && item.metadataExact && item.inputLifetime, JSON.stringify(item));
      assert.deepEqual(errors, []);
      await page.screenshot({ path: join(out, `${engine}.png`), fullPage: true });
      results.push({ engine, checked });
    } finally { await browser.close(); }
  }
  await writeFile(join(out, 'results.json'), JSON.stringify(results, null, 2) + '\n');
  console.log('External consumers: native Zig package, TypeScript, plain ESM, esbuild ESM/IIFE, Chromium and WebKit.');
} finally {
  if (server) await new Promise(resolve => server.close(resolve));
  await rm(temp, { recursive: true, force: true });
}
