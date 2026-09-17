import { mapPoint, mapRect } from '/web/decoder.mjs';

export async function testAnnotations(DjvuDecoder, bytes) {
  const decoder = await DjvuDecoder.create('/djvutang.wasm');
  const expect = (ok, message) => { if (!ok) throw new Error(`annotations: ${message}`); };
  try {
    {
      await decoder.open(await bytes('/annotations-rot1.djvu'));
      const [data, raster, transform] = await Promise.all([decoder.annotations(0), decoder.render(0), decoder.geometry(0)]);
      expect(data.areas.length === 6, 'all maparea shapes');
      expect(data.areas[0].comment === 'Quote: "; slash: \\; octal: α', 'UTF8 and escaping');
      const bounds = mapRect(transform.matrix, data.areas[0].bounds);
      expect(bounds.x === 5 && bounds.y === raster.height - 18 && bounds.width === 23 && bounds.height === 11, 'rotated source coordinates');
      const line = data.areas[3].points.map(p => mapPoint(transform.matrix, p));
      expect(line[0].x === 4 && line[0].y === raster.height - 6 && line[1].x === 40, 'line endpoint order');
    }
    const calls = [];
    await decoder.open(await bytes('/components/annotations-indirect/index.djvu'), { loadComponent: async component => {
      calls.push(component);
      return bytes(`/components/annotations-indirect/${encodeURIComponent(component.name)}`);
    } });
    const [data] = await Promise.all([decoder.annotations(0), decoder.render(0), decoder.text(0)]);
    expect(data.areas.length === 7 && data.view.zoom === 'd175', 'shared and local annotations');
    expect(calls.length === 2 && calls.some(c => c.kind === 'shared-annotations'), 'coalesced shared component IO');
    await decoder.annotations(1);
    expect(calls.length === 3, 'shared file reused across pages');
    const saved = JSON.stringify(data);
    await decoder.dropCache();
    expect((await decoder.annotations(0)).areas.length === 7, 'reload after drop');
    await decoder.close();
    expect((await decoder.diagnostics()).liveBytes === 0 && JSON.stringify(data) === saved, 'owned snapshot');
    const original = new Uint8Array(await bytes('/annotations-recovered.raw'));
    await decoder.open(await bytes('/annotations-recovered-split.djvu'));
    const [recovered] = await Promise.all([decoder.annotations(0), decoder.render(0)]);
    expect(recovered.hasReplacements && recovered.bytes instanceof ArrayBuffer, 'owned original bytes');
    expect(JSON.stringify([...new Uint8Array(recovered.bytes)]) === JSON.stringify([...original]), 'raw annotation source');
    expect(recovered.metadata.find(e => e.key === 'Title').value === 'A�B', 'recovered title');
    expect(recovered.metadata.find(e => e.key === 'Escaped').value === '�X�', 'recovered octal bytes');
    expect(recovered.areas.length === 1 && recovered.areas[0].comment === 'C�D', 'usable annotations around damaged links');
    const span = recovered.expressions[recovered.areas[0].expression];
    expect(new TextDecoder().decode(new Uint8Array(recovered.bytes, span.start, span.length)) === '(maparea "#1" "C�D" (rect 5 7 23 11))', 'original expression offsets');
    await decoder.open(await bytes('/annotations-utf8.djvu'));
    const escaped = await decoder.annotations(0);
    expect(escaped.hasReplacements && escaped.metadata[0].value === '�', 'escape damage with valid source');
    expect(new TextDecoder().decode(escaped.bytes).includes('\\377'), 'original escape preserved');
    await decoder.close();
    expect(new Uint8Array(recovered.bytes)[original.length - 1] === original.at(-1), 'recovered annotation snapshot outlives document');
    await decoder.open(await bytes('/annotations-bad.djvu'));
    const [error, raster] = await Promise.all([decoder.annotations(0).catch(e => e.code), decoder.render(0)]);
    expect(error === 'InvalidData' && raster.width === 101, 'annotation errors independent of rendering');
    let entered, finish;
    const waiting = new Promise(resolve => { entered = resolve; });
    const pending = new Promise(resolve => { finish = resolve; });
    let signal;
    await decoder.open(await bytes('/components/annotations-indirect/index.djvu'), { loadComponent: async (component, options) => {
      signal = options.signal; entered(); await pending;
      return bytes(`/components/annotations-indirect/${encodeURIComponent(component.name)}`);
    } });
    const cancelled = decoder.annotations(0).catch(e => e.code);
    await waiting;
    await decoder.close();
    expect(await cancelled === 'Cancelled' && signal.aborted, 'close cancels annotation IO');
    await decoder.open(await bytes('/text-z.djvu'));
    finish();
    expect(await decoder.annotations(0) === null, 'late result cannot replace current document');
    await decoder.close();
    expect((await decoder.diagnostics()).liveBytes === 0, 'close releases memory');
  } finally { decoder.destroy(); }
}
