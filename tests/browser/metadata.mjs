export async function testMetadata(DjvuDecoder, bytes) {
  const decoder = await DjvuDecoder.create('/djvutang.wasm');
  const expect = (ok, message) => { if (!ok) throw new Error(`metadata: ${message}`); };
  try {
    const book = await bytes('/metadata-book.djvu');
    const ranges = [];
    await decoder.open({ size: book.byteLength, read: async (offset, length) => {
      ranges.push({ offset, length });
      return book.slice(offset, offset + length);
    } });
    const result = await decoder.metadata();
    expect(result.metadata.length === 9 && result.xmp.length === 2, 'shared, late, duplicate and orphan records');
    expect(result.metadata[0].page === null && result.metadata[4].page === 2, 'shared and page scope');
    expect((await decoder.diagnostics()).dictionaryDecodes === 0, 'no dictionary decoding');
    expect(ranges.every(range => range.length < book.byteLength / 2), 'no whole-book metadata read');
    const saved = JSON.stringify(result);
    await decoder.close();
    expect((await decoder.diagnostics()).liveBytes === 0, 'scan and document allocations released');
    expect(JSON.stringify(result) === saved, 'snapshot outlives document');

    for (const ranged of [false, true]) {
      let loads = 0, reads = 0;
      await decoder.open(await bytes('/components/metadata-indirect/index.djvu'), {
        loadComponent: async component => {
          loads++;
          const input = await bytes(`/components/metadata-indirect/${encodeURIComponent(component.name)}`);
          if (!ranged) return input;
          return { size: input.byteLength, read: (offset, length) => {
            reads++;
            return input.slice(offset, offset + length);
          } };
        },
      });
      const actual = await decoder.metadata();
      expect(JSON.stringify(actual) === JSON.stringify(result), 'external buffers and range sources agree');
      expect(loads === 5 && (!ranged || reads > loads), 'one external source per component');
      await decoder.close();
    }

    for (const name of ['metadata-none.djvu', 'metadata-links.djvu']) {
      const file = await bytes(`/${name}`);
      await decoder.open({ size: file.byteLength, read: (offset, length) => file.slice(offset, offset + length) });
      const data = await decoder.metadata();
      expect(data.metadata.length === 0 && data.xmp.length === 0, 'confirmed empty result');
    }

    for (const readingRange of [false, true]) {
      await decoder.open(await bytes('/components/metadata-indirect/index.djvu'), {
        loadComponent: () => {
          const unavailable = () => { throw new Error('Unavailable input'); };
          return readingRange ? { size: 100, read: unavailable } : unavailable();
        },
      });
      const code = await decoder.metadata().catch(error => error.code);
      expect(code === (readingRange ? 'SourceReadFailed' : 'ComponentLoadFailed'), 'external provider and reader failures remain distinct');
    }

    for (const ranged of [false, true]) {
      await decoder.open(await bytes('/components/annotations-indirect/index.djvu'), {
        loadComponent: async component => {
          const input = await bytes(`/components/annotations-indirect/${encodeURIComponent(component.name)}`);
          if (!ranged) return input;
          return { size: input.byteLength, read: async (offset, length) => {
            if (length === 16) await new Promise(resolve => setTimeout(resolve, 1));
            return input.slice(offset, offset + length);
          } };
        },
      });
      const parallel = await Promise.all([decoder.metadata(), decoder.render(0)]);
      expect(parallel[0].metadata.length > 0 && parallel[1].rgba.byteLength > 0, 'external components can load while the scan reads ranges');
    }

    const shared = await bytes('/annotations-shared.djvu');
    let blocked = false, sourceError = false, entered, resume;
    let pending;
    let signal;
    await decoder.open({ size: shared.byteLength, read: async (offset, length, options) => {
      if (blocked) { signal = options.signal; entered(); await pending; }
      if (sourceError) throw new Error('Unavailable input');
      return shared.slice(offset, offset + length);
    } });
    const [data, cover] = await Promise.all([decoder.metadata(), decoder.render(0, { size: { width: 90, height: 120 } })]);
    expect(data.metadata.length > 0 && cover.rgba.byteLength > 0, 'metadata and cover on the same document');
    await decoder.dropCache();
    blocked = true;
    const waiting = new Promise(resolve => { entered = resolve; });
    pending = new Promise(resolve => { resume = resolve; });
    const cancelled = decoder.metadata().catch(error => error.code);
    await waiting;
    await decoder.cancelMetadata();
    expect(await cancelled === 'Cancelled' && signal.aborted, 'explicit scan cancellation aborts IO');
    blocked = false;
    resume();
    sourceError = true;
    expect(await decoder.metadata().catch(error => error.code) === 'SourceReadFailed', 'source failure remains distinct from absence');
    sourceError = false;
    expect((await decoder.metadata()).metadata.length > 0, 'retry after source failure');
    expect((await decoder.render(0, { size: { width: 90, height: 120 } })).rgba.byteLength === cover.rgba.byteLength, 'cover after scan cancellation and failure');
    await decoder.close();
    expect((await decoder.diagnostics()).liveBytes === 0, 'cleanup after reuse');
  } finally { decoder.destroy(); }
}
