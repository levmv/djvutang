// A local, read-only server for the standalone reader. Files selected in the UI
// never enter this server. The allowlist also keeps the surrounding workspace private.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = resolve(import.meta.dirname, '../..');
const routes = new Map([
  ['/', ['examples/reader/index.html', 'text/html; charset=utf-8']],
  ['/djvutang.wasm', ['zig-out/bin/djvutang.wasm', 'application/wasm']],
  ['/sample.djvu', ['tests/fixtures/reader-sample.djvu', 'image/vnd.djvu']],
]);
for (const name of ['app.mjs', 'reader.mjs', 'reader-model.mjs', 'reader.css']) {
  routes.set(`/${name}`, [`examples/reader/${name}`, name.endsWith('.css') ? 'text/css' : 'text/javascript']);
}
for (const name of ['decoder.mjs', 'worker.mjs']) {
  routes.set(`/web/${name}`, [`web/${name}`, 'text/javascript']);
}

export function createReaderServer() {
  return createServer(async (request, response) => {
    if (!['GET', 'HEAD'].includes(request.method)) { response.writeHead(405, { Allow: 'GET, HEAD' }); response.end(); return; }
    const route = routes.get(request.url);
    if (!route) { response.writeHead(404); response.end(); return; }
    try {
      const bytes = await readFile(resolve(root, route[0]));
      response.writeHead(200, { 'Content-Type': route[1], 'Content-Length': bytes.length,
        'Cache-Control': 'no-cache', 'X-Content-Type-Options': 'nosniff' });
      response.end(request.method === 'HEAD' ? undefined : bytes);
    } catch {
      response.writeHead(404); response.end('Asset not found. Run make wasm first.');
    }
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const port = Number(process.argv[2] ?? 4173);
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('Expected a port from 0 to 65535');
  const server = createReaderServer();
  server.listen(port, process.env.HOST ?? '127.0.0.1', () => console.log(`DjVuTang reader: http://127.0.0.1:${server.address().port}`));
}
