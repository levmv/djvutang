import { DjvuDecoder, DjvuError } from '/web/decoder.mjs';

export async function testApi(bytes) {
  const check = (value, message) => { if (!value) throw new Error(message); };
  async function rejected(promise, code) {
    try { await promise; }
    catch (error) {
      check(error instanceof DjvuError && error.code === code, `Expected DjvuError(${code}), got ${error}`);
      return error;
    }
    throw new Error(`Expected ${code}`);
  }

  for (const source of ['/missing.wasm', new Uint8Array([1, 2, 3])]) {
    const error = await rejected(DjvuDecoder.create(source), 'WasmLoadFailed');
    check(error.cause instanceof Error, 'WASM loading preserves the host error');
  }
  await rejected(DjvuDecoder.create('/djvutang.wasm', { workerUrl: '/missing-worker.mjs' }), 'WorkerFailed');

  const decoder = await DjvuDecoder.create('/djvutang.wasm');
  try {
    // Main-thread validation and Worker failures share one error contract.
    await rejected(decoder.open(new Uint8Array([1])), 'InvalidArgument');
    await rejected(decoder.open(new Uint8Array([1, 2, 3]).buffer), 'InvalidData');
    for (const cacheLimit of [-1, 0.5, NaN, 65 * 1024 * 1024])
      await rejected(decoder.open(await bytes('/plain.djvu'), { cacheLimit }), 'InvalidArgument');
    const input = await bytes('/shared.djvu');
    await decoder.open(input);
    await rejected(decoder.open(input), 'InvalidArgument'); // Already transferred.
    for (const options of [{ subsample: 0 }, { rotation: 90 }])
      await rejected(decoder.render(0, options), 'InvalidArgument');

    const pending = rejected(decoder.render(0), 'Cancelled');
    await decoder.cancelRender();
    await pending;
    const image = await decoder.render(0);
    const stats = await decoder.diagnostics();
    check(stats.steps > 0 && stats.maxStepMs >= 0 && stats.liveBytes > 0 && stats.peakBytes >= stats.liveBytes,
      'Diagnostics describe the completed render');
    check(stats.cacheBytes > 0 && stats.cacheBytes < stats.liveBytes && stats.linearBytes >= stats.liveBytes,
      'Diagnostics distinguish reclaimable cache from live allocations and WASM capacity');
    const saved = new Uint8Array(image.rgba).slice();
    await decoder.close();
    const closed = await decoder.diagnostics();
    check(closed.liveBytes === 0 && closed.cacheBytes === 0 && closed.linearBytes === stats.linearBytes
      && closed.steps === 0 && closed.maxStepMs === 0, 'Close frees allocations while retaining WASM capacity');
    check(new Uint8Array(image.rgba).every((v, i) => v === saved[i]), 'Image remains owned after close');

    // Queue diagnostics and cancellation together. The Worker must yield after
    // an incomplete step; a wall-clock delay could let a fast render finish.
    const large = await bytes('/blank-page.djvu');
    const info = new DataView(large);
    info.setUint16(24, 8192); info.setUint16(26, 8192);
    await decoder.open(large);
    const slow = { size: { width: 2048, height: 2048 } };
    const running = rejected(decoder.render(0, slow), 'Cancelled');
    const progress = decoder.diagnostics();
    const cancelled = decoder.cancelRender();
    check((await progress).steps > 0, 'Worker handles diagnostics after rendering starts');
    await cancelled;
    await running;

    const replaced = rejected(decoder.render(0, slow), 'Cancelled');
    const max = 0xffffffff;
    const cornerOptions = { size: { width: max, height: max }, region: { x: max - 1, y: max - 1, width: 1, height: 1 } };
    const corner = await decoder.render(0, cornerOptions);
    await replaced;
    check(corner.x === max - 1 && corner.y === max - 1 && corner.pageWidth === max && corner.pageHeight === max,
      'Large output coordinates retain unsigned WASM values');
    check(new Uint8Array(corner.rgba).every(v => v === 255), 'Extreme enlargement remains exact after cancellation');
    await decoder.close();
    check((await decoder.diagnostics()).liveBytes === 0, 'Cancelled batches release the document');

    await decoder.open(await bytes('/plain.djvu'));
    check(await decoder.storedThumbnail(0) === null, 'No synthesized thumbnail');
    check((await decoder.render(0)).width === 37, 'Worker is reusable after close');
    const destroyed = rejected(decoder.render(0), 'Cancelled');
    decoder.destroy();
    await destroyed;
    decoder.destroy();
    await rejected(decoder.render(0), 'Destroyed');
    await rejected(decoder.diagnostics(), 'Destroyed');
    const next = await bytes('/plain.djvu');
    await rejected(decoder.open(next), 'Destroyed');
    check(next.byteLength > 0, 'Destroyed decoder leaves a new input with its caller');
  } finally { decoder.destroy(); }
}
