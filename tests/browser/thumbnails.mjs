export async function testThumbnails(DjvuDecoder, bytes) {
  const check = (condition, message) => { if (!condition) throw new Error(message); };
  const code = promise => promise.then(() => 'done', error => error.code);
  const deferred = () => {
    let resolve;
    const promise = new Promise(r => { resolve = r; });
    return { promise, resolve };
  };
  const fixture = (name) => bytes(`/components/thumbnails-indirect/${encodeURIComponent(name)}`);
  const inlineFixture = (name) => bytes(`/components/thumbnails-inline-indirect/${encodeURIComponent(name)}`);
  const decoder = await DjvuDecoder.create('/djvutang.wasm');
  const expected = {};
  for (const name of ['color', 'gray']) {
    const ppm = new Uint8Array(await bytes(`/thumbnail-${name}-expected.ppm`));
    const marker = new TextEncoder().encode('\n255\n');
    const end = ppm.findIndex((_, i) => marker.every((v, j) => ppm[i + j] === v)) + marker.length;
    expected[name] = ppm.subarray(end);
  }
  const matches = (image, name) => {
    const rgba = new Uint8Array(image.rgba), rgb = expected[name];
    check(rgba.length === (rgb.length / 3) * 4, 'thumbnail byte length');
    check(rgb.every((v, i) => v === rgba[Math.floor(i / 3) * 4 + i % 3]), 'thumbnail pixels match external reference');
  };
  try {
    const calls = [];
    const opened = await decoder.open(await fixture('index.djvu'), {
      loadComponent: (component) => {
        calls.push(component.name);
        check(['thumbnail', 'page'].includes(component.kind), 'thumbnail lookup never follows INCL');
        return fixture(component.name);
      },
    });
    check(opened.pages.every((page) => !page.loaded) && calls.length === 0, 'index opens before thumbnail IO');
    check((await decoder.storedThumbnail(0)) === null && calls.join(',') === 'p0', 'uncovered page is checked for inline TH44');
    const first = await decoder.storedThumbnail(1);
    check(first.width === 11 && first.height === 7, 'encoded thumbnail dimensions');
    matches(first, 'color');
    matches(await decoder.storedThumbnail(2), 'gray');
    check(calls.join(',') === 'p0,first.thumb', 'two covered pages share one THUM download without page IO');
    check((await decoder.storedThumbnail(3)) === null, 'short group leaves its remaining pages uncovered');
    matches(await decoder.storedThumbnail(4), 'gray');
    check((await decoder.storedThumbnail(5)) === null, 'empty THUM returns null');
    check(calls.join(',') === 'p0,first.thumb,p3,second.thumb,empty.thumb,p5', 'only absent entries need page IO');
    await decoder.dropCache();
    matches(await decoder.storedThumbnail(1), 'color');
    check(calls.length === 7, 'THUM reloads after cache eviction');
    await decoder.close();
    check((await decoder.diagnostics()).liveBytes === 0, 'thumbnail close releases memory');
    matches(first, 'color');

    await decoder.open(await bytes('/thumbnails.djvu'));
    // Both calls use the image job slot. A thumbnail must never become a page's
    // cached render, including when a request returns null.
    const page = await decoder.render(1);
    check(page.width === 47 && page.height === 73, 'page applies its own INFO rotation');
    matches(await decoder.storedThumbnail(1), 'color');
    check((await decoder.render(1)).width === 47, 'page render replaces same-page thumbnail');
    check((await decoder.storedThumbnail(0)) === null, 'absence after page render');
    check((await decoder.render(1)).width === 47, 'render cache is invalidated by absent thumbnail');
    calls.length = 0;
    await decoder.open(await inlineFixture('index.djvu'), {
      loadComponent: (component) => {
        calls.push(component.name);
        return inlineFixture(component.name);
      },
    });
    for (const [page, name] of ['color', 'gray', 'gray', 'color'].entries())
      matches(await decoder.storedThumbnail(page), name);
    check((await decoder.storedThumbnail(4)) === null, 'inline absence returns null');
    check(calls.join(',') === 'p0,group.thumb,p2,empty.thumb,p3,p4', 'DIRM wins; short/empty groups fall back without INCL');

    const collection = await decoder.open(await bytes('/thumbnails.thum'));
    check(collection.pages.length === 2, 'THUM lists its images as pages');
    matches(await decoder.storedThumbnail(0), 'color');
    matches(await decoder.render(1), 'gray');
    check((await decoder.text(1)) === null, 'THUM has no page text');

    await decoder.open(await fixture('index.djvu'));
    check((await code(decoder.storedThumbnail(1))) === 'MissingComponent', 'provider required for external thumbnail');
    let attempt = 0;
    await decoder.open(await fixture('index.djvu'), {
      loadComponent: async (component) => {
        if (attempt++ === 0) throw new Error('offline');
        if (attempt === 2) return bytes('/plain.djvu');
        return fixture(component.name);
      },
    });
    check((await code(decoder.storedThumbnail(1))) === 'ComponentLoadFailed', 'provider failure is explicit');
    check((await code(decoder.storedThumbnail(1))) === 'InvalidData', 'THUM rejects a page FORM');
    matches(await decoder.storedThumbnail(1), 'color');

    for (const target of [1, 3]) for (const action of ['cancelRender', 'dropCache', 'replace']) {
      const started = deferred(), resume = deferred(), aborted = deferred();
      let held = false;
      await decoder.open(await inlineFixture('index.djvu'), {
        loadComponent: async (component, { signal }) => {
          if (!held && (target === 1 || component.kind === 'page')) {
            held = true;
            signal.addEventListener('abort', aborted.resolve, { once: true });
            started.resolve(signal);
            await resume.promise;
          }
          return inlineFixture(component.name); // Deliberately returns even after abort.
        },
      });
      const pending = code(decoder.storedThumbnail(target));
      const signal = await started.promise;
      if (action === 'replace') await decoder.open(await bytes('/plain.djvu'));
      else await decoder[action]();
      check((await pending) === 'Cancelled', `${action} cancels the thumbnail request`);
      await aborted.promise; // The component-cancel message may follow cancel's reply.
      check(signal.aborted, `${action} aborts the unused thumbnail component download`);
      resume.resolve();
      if (action === 'replace')
        check((await decoder.storedThumbnail(0)) === null && (await decoder.render(0)).width === 37,
          'late thumbnail component cannot enter new document');
      else matches(await decoder.storedThumbnail(target), target === 1 ? 'gray' : 'color');
    }
    await decoder.close();
    check((await decoder.diagnostics()).liveBytes === 0, 'final thumbnail close at zero');
  } finally { decoder.destroy(); }
}
