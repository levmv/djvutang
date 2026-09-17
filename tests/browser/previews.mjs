// Exercise automatic rendering through the public Worker, including owned
// results and cache reuse across scale changes. The Node/native suites supply
// independent compact-cell and exact full-resolution reference checks.
export async function testPreviews(DjvuDecoder, bytes, digest) {
  const decoder = await DjvuDecoder.create('/djvutang.wasm');
  const check = (condition, message) => { if (!condition) throw new Error(message); };
  try {
    await decoder.open(await bytes('/iw44-regions.djvu'), { memoryLimit: 24 * 1024 * 1024 });
    const options = { size: { width: 137, height: 181 } };
    const first = await decoder.render(0, options), hash = await digest(first.rgba);
    const tileOptions = { region: { x: 973, y: 1007, width: 512, height: 512 } };
    const tile = await decoder.render(0, tileOptions), tileHash = await digest(tile.rgba);
    const restored = await decoder.render(0, options);
    check(await digest(restored.rgba) === hash, 'preview survives exact view');
    await decoder.dropCache();
    check(await digest((await decoder.render(0, tileOptions)).rgba) === tileHash, 'fresh exact view matches cached exact view');
    check(await digest((await decoder.render(0, options)).rgba) === hash, 'fresh preview matches cached preview');
    const live = (await decoder.diagnostics()).liveBytes;
    await decoder.render(0, tileOptions);
    check(await digest((await decoder.render(0, options)).rgba) === hash, 'repeat preview matches');
    check((await decoder.diagnostics()).liveBytes === live, 'repeated zoom does not accumulate buffers');
    check(await digest(first.rgba) === hash, 'owned preview survives rerenders');
    const pending = decoder.render(0, { region: { x: 0, y: 0, width: 1024, height: 1024 } }).then(() => 'done', e => e.code);
    await decoder.cancelRender();
    check(await pending === 'Cancelled', 'cancel during transition to exact view');
    check(await digest((await decoder.render(0, options)).rgba) === hash, 'recover after cancellation');
    const figure = document.createElement('figure'), caption = document.createElement('figcaption'), canvas = document.createElement('canvas');
    caption.textContent = 'Automatic IW44 preview after zoom and cancellation';
    canvas.width = first.width; canvas.height = first.height;
    canvas.getContext('2d').putImageData(new ImageData(new Uint8ClampedArray(first.rgba), first.width, first.height), 0, 0);
    figure.append(caption, canvas); document.body.append(figure);
    await decoder.close();
    check((await decoder.diagnostics()).liveBytes === 0, 'close releases automatic job');
    await decoder.open(await bytes('/iw44-reduced-half.djvu'), { memoryLimit: 4 * 1024 * 1024 });
    const exact = await decoder.render(0), exactHash = await digest(exact.rgba);
    const smallOptions = { size: { width: 32, height: 32 } };
    const smallHash = await digest((await decoder.render(0, smallOptions)).rgba);
    check(await digest((await decoder.render(0)).rgba) === exactHash, 'small exact view survives cache promotion');
    check(await digest((await decoder.render(0, smallOptions)).rgba) === smallHash, 'small preview survives exact view');
    const smallLive = (await decoder.diagnostics()).liveBytes;
    await decoder.render(0);
    check(await digest((await decoder.render(0, smallOptions)).rgba) === smallHash, 'repeat small preview');
    check((await decoder.diagnostics()).liveBytes === smallLive, 'small zoom does not accumulate buffers');
    await decoder.dropCache();
    check(await digest((await decoder.render(0, smallOptions)).rgba) === smallHash, 'fresh small preview equals promoted cache');
    check(await digest((await decoder.render(0)).rgba) === exactHash, 'preview-first small job returns to exact');
    await decoder.close();
    check((await decoder.diagnostics()).liveBytes === 0, 'close releases small automatic job');
    // Core suites cover the codec/scale matrix. Here keep the Worker-specific
    // transitions: independent BG/FG promotion, shared ranges and mixed JPEG.
    for (const [name, edges] of [['foreground', [5, 2, 1]], ['preview-shared', [32]], ['jpeg-background', [1]]]) {
      const data = await bytes(`/${name}.djvu`), blob = new Blob([data]);
      await decoder.open({ size: blob.size, read: (offset, length) => blob.slice(offset, offset + length).arrayBuffer() }, { memoryLimit: 4 * 1024 * 1024 });
      const exact = await decoder.render(0), exactHash = await digest(exact.rgba);
      for (const edge of edges) {
        const options = { size: { width: edge, height: edge }, rotation: 1 };
        const promoted = await decoder.render(0, options), promotedHash = await digest(promoted.rgba);
        const x = Math.floor(promoted.width / 2), y = Math.floor(promoted.height / 2);
        const region = { x, y, width: promoted.width - x, height: promoted.height - y };
        const crop = await decoder.render(0, { ...options, region });
        const pixels = new Uint8Array(promoted.rgba);
        check(new Uint8Array(crop.rgba).every((v, i) => v === pixels[
          ((y + Math.floor(i / (region.width * 4))) * promoted.width + x) * 4 + i % (region.width * 4)]), `${name} rotated preview crop`);
        check(await digest((await decoder.render(0)).rgba) === exactHash, `${name} returns to exact`);
        await decoder.dropCache();
        check(await digest((await decoder.render(0, options)).rgba) === promotedHash, `${name} fresh and promoted previews agree`);
        check(await digest(exact.rgba) === exactHash && await digest(promoted.rgba) === promotedHash, `${name} owned images survive restarts`);
      }
      await decoder.close();
      check((await decoder.diagnostics()).liveBytes === 0, `${name} close releases masks and layers`);
    }
  } finally { decoder.destroy(); }
}
