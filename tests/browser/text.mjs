import { zoneText, mapRect, mapPoint } from '../../web/decoder.mjs';

export async function runTextChecks(decoder, bytes, digest) {
  const check = (value, message) => { if (!value) throw new Error(message); };
  const expected = await fetch('/text-expected.json').then(r => r.json());
  const errors = [];
  let retained;
  let recoveredSnapshot;
  for (const name of ['text-z', 'text-rotated']) {
    await decoder.open(await bytes(`/${name}.djvu`));
    const pending = decoder.render(0);
    const text = await decoder.text(0);
    const rendered = await pending;
    check(text.text === expected.text, 'Exact full text');
    check(text.zones.length === 24, 'Whole zone tree');
    check(zoneText(text, text.zones[9]) === '🙂', 'Four-byte character span');
    check(zoneText(text, text.zones[8]) === '\u0301', 'Combining character span');
    const utf8Hash = await digest(text.bytes);
    for (const [subsample, rotation, crop] of [[1, 0, false], [3, 1, true]]) {
      const options = { subsample, rotation };
      const full = await decoder.geometry(0, options);
      if (crop) {
        const x = Math.floor(full.width / 4), y = Math.floor(full.height / 4);
        options.region = { x, y, width: full.width - x, height: full.height - y };
      }
      const geometry = await decoder.geometry(0, options);
      const tile = await decoder.render(0, options);
      check(tile.width === geometry.width && tile.height === geometry.height, 'Text/image output geometry');
      let visibleWords = 0;
      for (const zone of text.zones.filter(z => z.type === 'word')) {
        const mapped = mapRect(geometry.matrix, zone);
        const center = mapPoint(geometry.matrix, { x: zone.x + zone.width / 2, y: zone.y + zone.height / 2 });
        const source = mapPoint(geometry.inverse, center);
        check(Math.abs(source.x - zone.x - zone.width / 2) < 1e-9 && Math.abs(source.y - zone.y - zone.height / 2) < 1e-9, 'Pointer inverse');
        const whole = mapRect(full.matrix, zone);
        check(Math.abs(whole.x - geometry.x - mapped.x) < 1e-9 && Math.abs(whole.y - geometry.y - mapped.y) < 1e-9, 'Region offset');
        if (center.x >= 0 && center.y >= 0 && center.x < tile.width && center.y < tile.height) visibleWords++;
      }
      check(visibleWords > 0, 'Meaningful visible words');
      if (name === 'text-z' && crop) {
        const figure = document.createElement('figure');
        const caption = document.createElement('figcaption');
        caption.textContent = `Text zones · ÷${subsample} · turn ${rotation}${crop ? ' · tile' : ''}`;
        const canvas = document.createElement('canvas');
        canvas.width = tile.width; canvas.height = tile.height;
        const scale = subsample === 1 ? 3 : 6;
        canvas.style.width = `${tile.width * scale}px`; canvas.style.height = `${tile.height * scale}px`;
        const context = canvas.getContext('2d');
        context.putImageData(new ImageData(new Uint8ClampedArray(tile.rgba), tile.width, tile.height), 0, 0);
        context.strokeStyle = '#e14885'; context.lineWidth = 0.6;
        for (const zone of text.zones.filter(z => z.type === 'word')) {
          const r = mapRect(geometry.matrix, zone);
          context.strokeRect(r.x, r.y, r.width, r.height);
        }
        const label = document.createElement('div');
        label.textContent = 'AЖB · é🙂 · 漢字 · строка · אבג';
        label.style.marginTop = '8px';
        figure.append(caption, canvas, label); document.body.append(figure);
      }
      check(await digest(text.bytes) === utf8Hash, 'Text snapshot survives zoom');
    }
    check(await digest((await decoder.render(0)).rgba) === await digest(rendered.rgba), 'Text calls preserve image pixels');
    retained = text;
  }
  await decoder.open(await bytes('/unicode-text.djvu'));
  const unicode = await decoder.text(0);
  check(zoneText(unicode, unicode.zones[1]) === 'Ж', 'UTF-8 and UTF-16 regression');
  const recovered = await fetch('/text-recovered.json').then(r => r.json());
  {
    await decoder.open(await bytes('/text-recovered-z.djvu'));
    const pending = decoder.render(0);
    const text = await decoder.text(0);
    await pending;
    check(text.hasReplacements && text.text === recovered.text, 'Replacement text');
    check(JSON.stringify([...new Uint8Array(text.bytes)]) === JSON.stringify(recovered.bytes), 'Original text bytes');
    check(JSON.stringify(text.zones) === JSON.stringify(retained.zones), 'Original geometry and byte ranges');
    check(zoneText(text, text.zones[5]) === '�Ж� ' && zoneText(text, text.zones[11]) === '漢字 ', 'Copy after damaged bytes');
    recoveredSnapshot = text;
  }
  for (const name of ['text-only', 'text-empty', 'plain']) {
    await decoder.open(await bytes(`/${name}.djvu`));
    const text = await decoder.text(0);
    if (name === 'plain') check(text === null, 'Absent text');
    else {
      check(text.zones.length === 0, 'Unzoned text');
      check(text.text === (name === 'text-empty' ? '' : '\ufeffA\0Ж\r\nB\x0bC\x1dD\x1eE\x1f🙂'), 'Empty text/BOM/separators');
    }
  }
  await decoder.open(await bytes('/bad-text.djvu'));
  const pending = decoder.render(0);
  errors.push(await decoder.text(0).then(() => 'unexpected completion', e => e.code));
  await pending;
  const damaged = new Uint8Array(await bytes('/text-z.djvu'));
  const marker = new TextEncoder().encode('Sjbz');
  const offset = damaged.findIndex((_, i) => marker.every((b, j) => damaged[i + j] === b));
  damaged.set(new TextEncoder().encode('BGzz'), offset);
  await decoder.open(damaged.buffer);
  errors.push(await decoder.render(0).then(() => 'unexpected completion', e => e.code));
  check((await decoder.text(0)).text === expected.text, 'Text independent of unsupported image');
  await decoder.open(await bytes('/text-z.djvu'), { memoryLimit: 2048 });
  errors.push(await decoder.text(0).then(() => 'unexpected completion', e => e.code));
  await decoder.open(await bytes('/text-z.djvu'));
  check((await decoder.text(0)).text === expected.text, 'Recovery after text memory failure');
  check(errors.join(',') === 'InvalidData,Unsupported,LimitExceeded', 'Independent error categories');
  await decoder.close();
  const closed = await decoder.diagnostics();
  check(closed.liveBytes === 0, 'Text/image ownership release');
  check(retained.text === expected.text && zoneText(retained, retained.zones[9]) === '🙂', 'Text outlives document');
  check(recoveredSnapshot.hasReplacements && zoneText(recoveredSnapshot, recoveredSnapshot.zones[11]) === '漢字 ', 'Recovered snapshot outlives document');
}
