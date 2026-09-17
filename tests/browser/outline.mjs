export async function testOutline(DjvuDecoder, bytes) {
  const decoder = await DjvuDecoder.create('/djvutang.wasm');
  const expect = (ok, message) => { if (!ok) throw new Error(`outline: ${message}`); };
  const expected = await fetch('/outline-expected.json').then(r => r.json());
  const calls = [];
  try {
    const opened = await decoder.open(await bytes('/components/outline-indirect/index.djvu'), { loadComponent: async component => {
      calls.push(component.name);
      return bytes(`/components/outline-indirect/${encodeURIComponent(component.name)}`);
    } });
    expect(opened.pages.length === 7 && opened.pages.every(p => !p.loaded), 'index metadata');
    const data = await decoder.outline();
    expect(JSON.stringify(data) === JSON.stringify(expected), 'tree and UTF8');
    const targets = await Promise.all([decoder.resolveLink('#2'), decoder.resolveLink('#3'), decoder.resolveLink('#Repeat', 3), decoder.resolveLink('#+2'), decoder.resolveLink('#+2', 4), decoder.resolveLink('#file%20e.djvu')]);
    expect(targets[0].page === 2 && targets[1].page === 1 && targets[2].page === 5 && targets[3].kind === 'unresolved' && targets[4].page === 6 && targets[5].kind === 'unresolved', 'link precedence');
    expect(calls.length === 0, 'outline and resolver perform no component IO');
    for (const [href, origin] of [[{}, null], [null, null], ['\ud800', null], ['#1', -1], ['#1', 7], ['#1', 0.5]]) {
      const error = await decoder.resolveLink(href, origin).catch(e => e.code);
      expect(error === 'InvalidArgument', 'transport validation');
    }
    expect(calls.length === 0, 'invalid input performs no IO');
    const [render, annotations, again] = await Promise.all([decoder.render(0), decoder.annotations(0), decoder.outline()]);
    expect(render.width === 101 && annotations.areas.length === 1 && JSON.stringify(again) === JSON.stringify(data), 'independent concurrent reads');
    expect(calls.length === 1, 'shared loading across render and annotation');
    expect((await decoder.resolveLink(annotations.areas[0].href, 0)).page === 2, 'annotation uses same resolver');

    const link = await decoder.resolveLink(data.entries[3].href, 0);
    expect(link.page === 2, 'numeric component ID');
    await decoder.render(link.page);
    expect(calls.length === 2, 'navigation loads the target page');
    const before = calls.length;
    const saved = JSON.stringify(data);
    await decoder.dropCache();
    expect(JSON.stringify(await decoder.outline()) === saved && calls.length === before, 'drop keeps index available');
    await decoder.close();
    expect((await decoder.diagnostics()).liveBytes === 0 && JSON.stringify(data) === saved, 'owned snapshot after close');
    await decoder.open(await bytes('/outline-bad.djvu'));
    const [error, raster] = await Promise.all([decoder.outline().catch(e => e.code), decoder.render(0)]);
    expect(error === 'InvalidData' && raster.width === 101, 'corrupt outline does not block page');
    await decoder.open(await bytes('/text-z.djvu'));
    expect(await decoder.outline() === null, 'absent outline');
    expect((await decoder.resolveLink('#2')).kind === 'unresolved', 'replacement uses new directory');
    await decoder.close();
    expect((await decoder.diagnostics()).liveBytes === 0, 'close frees memory');
    expect(await decoder.outline().catch(e => e.code) === 'InvalidArgument', 'read after close');
  } finally { decoder.destroy(); }
}
