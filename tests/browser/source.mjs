import { DjvuDecoder, mapRect } from '/web/decoder.mjs';
import { fitReference } from '/tests/support/resample.mjs';
export async function testSource(bytes) {
  const check = (value, message) => { if (!value) throw new Error(message); };
  const code = promise => promise.then(() => 'done', error => error.code);
  const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  const samePixels = (a, b) => a.width === b.width && a.height === b.height
    && new Uint8Array(a.rgba).every((v, i) => v === new Uint8Array(b.rgba)[i]);
  const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
  const decoder = await DjvuDecoder.create('/djvutang.wasm');
  const reference = await DjvuDecoder.create('/djvutang.wasm');
  try {
    for (const name of ['shared', 'shared-layers', 'outline-late', 'annotations-shared', 'thumbnails']) {
      const data = await bytes(`/${name}.djvu`), blob = new Blob([data]), reads = [];
      const ranged = await decoder.open({ size: blob.size, read(offset, length) {
        reads.push({ offset, length }); return blob.slice(offset, offset + length).arrayBuffer();
      } });
      const whole = await reference.open(data);
      check(!ranged.indirect && ranged.pages.length === whole.pages.length && ranged.pages.every(p => !p.loaded), 'Bundled pages remain unloaded at open');
      const indexReads = reads.length;
      check(equal(await decoder.outline(), await reference.outline()), 'Outline retained in range index');
      check(reads.length === indexReads, 'Outline needs no page reads');
      const options = { size: { width: 47, height: 59 }, rotation: 1 };
      const geometry = await decoder.geometry(0, options);
      const sourceGeometry = await decoder.geometry(0);
      const mapped = mapRect(geometry.matrix, { x: 0, y: 0,
        width: sourceGeometry.rotation % 2 ? sourceGeometry.height : sourceGeometry.width,
        height: sourceGeometry.rotation % 2 ? sourceGeometry.width : sourceGeometry.height });
      check(Math.abs(mapped.width - geometry.width) < 1e-8 && Math.abs(mapped.height - geometry.height) < 1e-8, 'Sized text matrix covers the page');
      check(equal(await decoder.text(0), await reference.text(0)), 'Range text');
      check(equal(await decoder.annotations(0), await reference.annotations(0)), 'Range annotations');
      const image = await decoder.render(0, options);
      check(samePixels(image, await reference.render(0, options)), 'Range sized pixels');
      const original = await reference.render(0, { rotation: 1 });
      const expected = fitReference(original, options.size);
      check(new Uint8Array(image.rgba).every((v, i) => Math.abs(v - expected.rgba[i]) <= 1), 'Browser matches independent area filter');
      const region = { x: 1, y: 2, width: image.width - 1, height: image.height - 2 };
      const tile = await decoder.render(0, { ...options, region });
      check(new Uint8Array(tile.rgba).every((v, i) => v === new Uint8Array(image.rgba)[
        ((region.y + Math.floor(i / (region.width * 4))) * image.width + region.x) * 4 + i % (region.width * 4)]), 'Sized tile matches full page');
      const thumb = await decoder.storedThumbnail(0), fullThumb = await reference.storedThumbnail(0);
      check(thumb ? fullThumb && samePixels(thumb, fullThumb) : fullThumb === null, 'Range thumbnail');
      const loadedReads = reads.length;
      await decoder.dropCache();
      check(samePixels(image, await decoder.render(0, options)) && reads.length > loadedReads, 'Cache eviction reloads ranges');
      await decoder.close(); check((await decoder.diagnostics()).liveBytes === 0, 'Range close releases allocations');
    }
    // Enlargement, INFO orientation and the same transform at a nonzero region origin.
    await decoder.open(await bytes('/rotated-color.djvu'));
    for (const rotation of [0, 1, 2, 3]) {
      const original = await decoder.render(0, { rotation });
      const size = { width: 197, height: 181 }, actual = await decoder.render(0, { size, rotation });
      const expected = fitReference(original, size);
      check(actual.width === expected.width && actual.height === expected.height
        && new Uint8Array(actual.rgba).every((v, i) => Math.abs(v - expected.rgba[i]) <= 1), 'Browser bilinear enlargement');
    }
    for (const options of [{ size: { width: 0, height: 2 } }, { size: { width: 4, height: 5 }, subsample: 2 }])
      check(await code(decoder.render(0, options)) === 'InvalidArgument', 'Invalid size options');

    const data = await bytes('/shared.djvu');
    // Readers preserve their receiver, and render/text share an outstanding page read.
    const started = deferred(), resume = deferred(); let hold = false;
    await decoder.open({ size: data.byteLength, data, async read(offset, length, { signal }) {
      if (hold) { hold = false; started.resolve(signal); await resume.promise; }
      return this.data.slice(offset, offset + length);
    } });
    hold = true;
    const render = code(decoder.render(0)), text = decoder.text(0);
    const signal = await started.promise;
    await decoder.cancelRender();
    check(await render === 'Cancelled' && !signal.aborted, 'Text retains the shared range when rendering is cancelled');
    resume.resolve(); await text;
    await decoder.render(0);

    let failure = 0;
    await decoder.open({ size: data.byteLength, read(offset, length) {
      if (failure === 1) { failure = 0; throw new Error('temporarily unavailable'); }
      if (failure === 2) { failure = 0; return new ArrayBuffer(length - 1); }
      if (failure === 3) { failure = 0; return new ArrayBuffer(length); }
      return data.slice(offset, offset + length);
    } });
    for (const [attempt, expected] of [[1, 'SourceReadFailed'], [2, 'InvalidArgument'], [3, 'InvalidData']]) {
      failure = attempt;
      check(await code(decoder.geometry(0)) === expected, 'A failed component range stays retryable');
    }
    check((await decoder.geometry(0)).width === 160, 'Range retry succeeds');

    for (const action of ['close', 'dropCache', 'replace']) {
      const started = deferred(), resume = deferred();
      const opening = code(decoder.open({ size: data.byteLength, async read(offset, length, { signal }) {
        started.resolve(signal); await resume.promise; return data.slice(offset, offset + length);
      } }));
      const signal = await started.promise;
      if (action === 'replace') await decoder.open(await bytes('/plain.djvu')); else await decoder[action]();
      check(await opening === 'Cancelled' && signal.aborted, 'Cancel an index range in flight');
      resume.resolve(); // Deliberately late response must not reach a replacement document.
      if (action !== 'replace') {
        check((await decoder.diagnostics()).liveBytes === 0, 'Cancelled index releases allocations');
        await decoder.open(await bytes('/plain.djvu'));
      }
      check((await decoder.render(0)).width === 37, 'Late index bytes leave replacement intact');
    }
    check(await code(decoder.open({ size: 16, read() { throw new Error('offline'); } })) === 'SourceReadFailed', 'Index read errors are explicit');
    check((await decoder.diagnostics()).liveBytes === 0, 'Failed index read releases allocations');

    // An indirect index can itself come from a range source; its files still use the host loader.
    const index = await bytes('/components/indirect/index.djvu');
    const indirect = await decoder.open({ size: index.byteLength, read: (offset, length) => index.slice(offset, offset + length) }, {
      loadComponent: component => bytes(`/components/indirect/${encodeURIComponent(component.name)}`),
    });
    check(indirect.indirect && (await decoder.render(0)).width === 160, 'Range source with external component resolution');
    await decoder.close(); check((await decoder.diagnostics()).liveBytes === 0, 'Final close');
  } finally { decoder.destroy(); reference.destroy(); }
}
