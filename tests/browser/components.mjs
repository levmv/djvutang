export async function testComponents(DjvuDecoder, bytes) {
  const check = (condition, message) => { if (!condition) throw new Error(message); };
  const code = promise => promise.then(() => 'done', error => error.code);
  const deferred = () => {
    let resolve;
    const promise = new Promise(r => { resolve = r; });
    return { promise, resolve };
  };
  const fixture = (directory, name = 'index.djvu') => bytes(`/components/${directory}/${encodeURIComponent(name)}`);
  const decoder = await DjvuDecoder.create('/djvutang.wasm');
  try {
    for (const standalone of [false, true]) {
      const folder = standalone ? 'standalone-layers' : 'indirect-layers';
      const calls = [];
      const started = deferred(), resume = deferred();
      const opened = await decoder.open(await fixture(folder, standalone ? 'page.djvu' : 'index.djvu'), {
        loadComponent: async (component, { signal }) => {
          calls.push(component.name);
          if (component.name === (standalone ? 'paint' : 'paint.iff')) {
            started.resolve(signal);
            await resume.promise;
          }
          return fixture(folder, component.name);
        },
      });
      if (standalone) {
        check(!opened.indirect && opened.pages.length === 1 && opened.pages[0].loaded, 'standalone page opens before dependencies load');
      } else {
        check(opened.indirect && opened.pages.length === 2 && !opened.pages[0].loaded, 'index opens without page bytes');
        check(opened.pages[0].id === 'page-a' && opened.pages[0].name === 'sheet a.djvu' && opened.pages[0].title === 'Opening', 'separate ID/name/title');
      }
      check(calls.length === 0, 'open performs no component IO');
      check(await code(decoder.geometry(0, { subsample: 0 })) === 'InvalidArgument' && calls.length === 0, 'invalid options fail before requesting files');
      const geometry = await decoder.geometry(0);
      check(geometry.width === 65 && calls.join(',') === (standalone ? '' : 'sheet a.djvu'), 'geometry loads only its page');
      const cancelled = code(decoder.render(0));
      const reading = decoder.text(0);
      const signal = await started.promise;
      await decoder.cancelRender();
      check(await cancelled === 'Cancelled', 'cancel during component IO');
      check(!signal.aborted, 'a concurrent text request still needs the shared download');
      resume.resolve();
      const text = await reading;
      check(text.text === 'Shared α text\n', 'included text');
      const first = await decoder.render(0);
      const second = await decoder.render(standalone ? 0 : 1);
      check(calls.length === (standalone ? 5 : 7) && new Set(calls).size === calls.length, 'components load once across pages and duplicate inclusions');
      check(new Uint8Array(first.rgba).every((v, i) => v === new Uint8Array(second.rgba)[i]), 'shared color and mask pixels');
      if (standalone) check((await decoder.annotations(0)).source === '(background #123456)', 'included annotations without DIRM');
      const reference = new Uint8Array(await bytes('/jpeg-foreground-reference.ppm'));
      const separator = new TextEncoder().encode('\n255\n');
      const offset = reference.findIndex((_, i) => separator.every((b, j) => reference[i+j] === b)) + separator.length;
      check(reference.subarray(offset).every((v, i) => v === new Uint8Array(first.rgba)[Math.floor(i/3)*4 + i%3]), 'independent compositor reference');
      const region = { x: 3, y: 5, width: 17, height: 13 };
      const tile = new Uint8Array((await decoder.render(0, { region })).rgba);
      const full = new Uint8Array(first.rgba);
      check(tile.every((v, i) => v === full[((region.y + Math.floor(i / (region.width*4)))*65 + region.x)*4 + i%(region.width*4)]), 'indirect region crop');
      await decoder.dropCache();
      await decoder.render(0);
      check(calls.length === (standalone ? 10 : 13), 'dropCache releases encoded components for reloading');
      await decoder.close();
      check((await decoder.diagnostics()).liveBytes === 0, 'close releases component allocations');
      check(text.text === 'Shared α text\n', 'owned text survives close');
    }

    await decoder.open(await fixture('standalone-layers', 'page.djvu'));
    check(await code(decoder.render(0)) === 'MissingComponent', 'standalone dependencies need a provider');
    await decoder.open(await fixture('indirect'));
    check(await code(decoder.render(0)) === 'MissingComponent', 'missing provider is explicit');
    let attempt = 0;
    await decoder.open(await fixture('indirect'), {
      loadComponent: async component => {
        if (attempt++ === 0) throw new Error('offline');
        if (attempt === 2) return fixture('indirect', 'page0.iff'); // wrong FORM for a page
        return fixture('indirect', component.name);
      },
    });
    check(await code(decoder.render(0)) === 'ComponentLoadFailed', 'provider errors stay retryable');
    check(await code(decoder.render(0)) === 'InvalidData', 'mismatched component type');
    check((await decoder.render(0)).width === 160, 'retry after provider and data failure');

    for (const replace of [false, true]) {
      const oldStarted = deferred(), oldResume = deferred();
      let held = false;
      await decoder.open(await fixture('standalone-layers', 'page.djvu'), {
        loadComponent: async (component, { signal }) => {
          if (component.name === 'tail' && !held) {
            held = true;
            oldStarted.resolve(signal);
            await oldResume.promise; // Deliberately ignores abort.
          }
          return fixture('standalone-layers', component.name);
        },
      });
      const pending = code(decoder.render(0));
      const oldSignal = await oldStarted.promise;
      if (replace) await decoder.open(await bytes('/plain.djvu'));
      else await decoder.dropCache();
      check(await pending === 'Cancelled' && oldSignal.aborted, 'replacement or cache drop cancels nested loading');
      oldResume.resolve();
      check((await decoder.render(0)).width === (replace ? 37 : 65), 'late response cannot enter a new load');
    }
    check(await code(decoder.open(new Uint8Array([1, 2, 3]).buffer)) === 'InvalidData', 'failed replacement reports its input error');
    check(await code(decoder.render(0)) === 'InvalidArgument', 'failed replacement leaves no old document behind');

    const closeStarted = deferred(), closeResume = deferred();
    await decoder.open(await fixture('indirect'), {
      loadComponent: async (component, { signal }) => {
        closeStarted.resolve(signal); await closeResume.promise;
        return fixture('indirect', component.name);
      },
    });
    const geometryPending = code(decoder.geometry(0));
    const textPending = code(decoder.text(0));
    const closeSignal = await closeStarted.promise;
    await decoder.close();
    check((await decoder.diagnostics()).liveBytes === 0, 'close during read preparation releases memory');
    check(await geometryPending === 'Cancelled' && await textPending === 'Cancelled' && closeSignal.aborted, 'close cancels reads as well as render');
    closeResume.resolve();

    await decoder.open(await fixture('indirect'), { memoryLimit: 8192, loadComponent: () => new ArrayBuffer(16384) });
    check(await code(decoder.render(0)) === 'LimitExceeded', 'component input shares the WASM memory budget');
    await decoder.close();
    check((await decoder.diagnostics()).liveBytes === 0, 'failed component allocation releases memory');

    // Both pages fit separately. The previous completed job must be released
    // before fetching the next page, whose compressed bytes also use the budget.
    const blank = new Uint8Array(await bytes('/blank-page.djvu'));
    await decoder.open(await fixture('indirect-zero-sizes'), {
      memoryLimit: 1024 * 1024 + 32 * 1024,
      loadComponent: async component => {
        const first = component.id === 'page-a';
        const data = new Uint8Array(blank.length + (first ? 0 : 64 * 1024));
        data.set(blank);
        const view = new DataView(data.buffer);
        view.setUint32(8, data.length - 12);
        view.setUint16(24, first ? 512 : 64);
        view.setUint16(26, first ? 512 : 64);
        if (!first) {
          data.set(new TextEncoder().encode('JUNK'), blank.length);
          view.setUint32(blank.length + 4, data.length - blank.length - 8);
        }
        return data.buffer;
      },
    });
    const previous = await decoder.render(0);
    check(previous.rgba.byteLength === 1024 * 1024, 'first page fills most of the budget');
    check((await decoder.render(1)).width === 64, 'next page loads after the old job is released');
    check(new Uint8Array(previous.rgba).every(v => v === 255), 'released jobs preserve owned results');
    await decoder.close();
    check((await decoder.diagnostics()).liveBytes === 0, 'page replacement releases all allocations');

    const calls = [];
    const started = deferred(), resume = deferred();
    await decoder.open(await fixture('indirect-layers'), {
      cacheLimit: 0,
      loadComponent: async (component, { signal }) => {
        calls.push(component.name);
        if (component.name === 'paint.iff') { started.resolve(signal); await resume.promise; }
        return fixture('indirect-layers', component.name);
      },
    });
    const rendering = code(decoder.render(0));
    const signal = await started.promise;
    const reading = decoder.text(0);
    await decoder.cancelRender();
    check(await rendering === 'Cancelled' && !signal.aborted, 'zero cache target preserves a concurrent load');
    resume.resolve();
    const text = await reading;
    check(text.text === 'Shared α text\n' && calls.length === 6, 'preparation is not interrupted by eviction');
    const saved = new Uint8Array((await decoder.render(0)).rgba);
    check(calls.length === 12, 'idle boundary reloads evicted components');
    await decoder.render(0);
    check(calls.length === 12, 'same-page restart retains its decoded layers');
    for (const page of [1, 0]) {
      const result = new Uint8Array((await decoder.render(page)).rgba);
      check(result.every((v, i) => v === saved[i]), 'eviction and revisit preserve pixels');
    }
    check(calls.length === 24 && text.text === 'Shared α text\n', 'owned metadata survives automatic eviction');

    let supplied = 0;
    await decoder.open(await fixture('indirect-zero-sizes'), {
      memoryLimit: 600 * 1024,
      loadComponent: async () => {
        supplied++;
        const data = new Uint8Array(blank.length + 320 * 1024);
        data.set(blank);
        const view = new DataView(data.buffer);
        view.setUint32(8, data.length - 12);
        view.setUint16(24, 64); view.setUint16(26, 64);
        data.set(new TextEncoder().encode('JUNK'), blank.length);
        view.setUint32(blank.length + 4, data.length - blank.length - 8);
        return data.buffer;
      },
    });
    for (const page of [0, 1, 0]) check((await decoder.render(page)).width === 64, 'default cache target makes room for the next page');
    check(supplied === 3, 'default eviction requests the revisited page again');
    await decoder.close();
    check((await decoder.diagnostics()).liveBytes === 0, 'bounded cache closes without retained allocations');
  } finally { decoder.destroy(); }
}
