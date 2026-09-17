import assert from 'node:assert/strict';
import { test } from 'node:test';
import { MAX_TILES, TILE_SIZE, subsampleFor, visibleTiles, selectableZones, hitZone, selectionBetween, selectedText, sourcePoint } from '../reader-model.mjs';

test('viewport tiles cover exactly the intersecting grid, including partial edges', () => {
  const tiles = visibleTiles(1025, 777, { x: 500, y: 500, width: 700, height: 400 });
  assert.deepEqual(new Set(tiles.map(t => t.key)), new Set(['0:0', '512:0', '1024:0', '0:512', '512:512', '1024:512']));
  assert.deepEqual(tiles.find(t => t.key === '1024:512'), { key: '1024:512', x: 1024, y: 512, width: 1, height: 265 });
  assert.equal(visibleTiles(1024, 1024, { x: 0, y: 0, width: 512, height: 512 }).length, 1);
  assert.equal(visibleTiles(100, 100, { x: -200, y: 0, width: 199, height: 100 }).length, 0);
  assert.equal(visibleTiles(100, 100, { x: 100, y: 0, width: 100, height: 100 }).length, 0);
});

test('resolution bounds the canvas set across zoom, DPR, scrolling and viewport sizes', () => {
  for (const [width, height] of [[1200, 1600], [8192, 6144], [65535, 65535], [1, 65535]]) {
    for (const viewport of [{ width: 390, height: 700 }, { width: 1280, height: 800 }, { width: 7680, height: 4320 }]) {
      for (const zoom of [.001, .02, .1, .333, .5, 1, 4]) for (const dpr of [1, 2, 3]) {
        const ss = subsampleFor(width, height, zoom, viewport, dpr);
        assert.ok(Number.isInteger(ss) && ss >= 1 && ss <= 256);
        const w = Math.ceil(width / ss), h = Math.ceil(height / ss), scale = zoom * ss;
        for (const offset of [0, 1, 511, 1021]) {
          const tiles = visibleTiles(w, h, { x: offset, y: offset, width: viewport.width / scale, height: viewport.height / scale });
          assert.ok(tiles.length <= MAX_TILES, JSON.stringify({ width, height, viewport, zoom, dpr, ss, count: tiles.length }));
          assert.ok(tiles.every(t => t.width <= TILE_SIZE && t.height <= TILE_SIZE && t.x + t.width <= w && t.y + t.height <= h));
        }
      }
    }
  }
});

test('selection uses reading order and UTF-8 spans; nested characters do not duplicate words', () => {
  const text = 'AЖB é🙂 \nאבג\u000b', bytes = new TextEncoder().encode(text).buffer;
  const zones = [
    { type: 'page', subtreeEnd: 5 },
    { type: 'word', start: 0, length: 5, x: 20, y: 0, width: 20, height: 12, subtreeEnd: 2 },
    { type: 'word', start: 5, length: 8, x: 0, y: 0, width: 18, height: 12, subtreeEnd: 4 },
    { type: 'character', start: 5, length: 1, x: 0, y: 0, width: 3, height: 12, subtreeEnd: 4 },
    { type: 'line', start: 14, length: 7, x: -2, y: 30, width: 10, height: 12, subtreeEnd: 5 },
  ];
  const layer = { text, bytes, zones }, units = selectableZones(layer);
  assert.deepEqual(units, [zones[1], zones[2], zones[4]]);
  assert.equal(hitZone(units, { x: 5, y: 5 }), zones[2]);
  assert.equal(hitZone(units, { x: 50, y: 50 }), null);
  assert.equal(hitZone(units, { x: 0, y: 100 }, true), zones[4]);
  assert.equal(selectedText(layer, selectionBetween(units[1], units[0])), 'AЖB é🙂 ');
  assert.equal(selectedText(layer, { start: 0, length: bytes.byteLength }), text);
  assert.deepEqual(selectableZones({ zones: [] }), []);
});

test('pointer hit testing inverts page rotation, reduction padding, CSS scale and viewport scroll', () => {
  // 101×79 at reduction 3, rotated counterclockwise: x'=(y+2)/3, y'=34-x/3.
  const geometry = { inverse: [0, 3, -3, 0, 102, -2] };
  const point = sourcePoint(geometry, 1.2, { left: -80, top: 60 }, -80 + 10 * 1.2, 60 + 27 * 1.2);
  assert.ok(Math.abs(point.x - 21) < 1e-9);
  assert.ok(Math.abs(point.y - 28) < 1e-9);
});

test('copy uses original byte ranges when replacement text grows', () => {
  const bytes = new Uint8Array([0x41, 0x95, 0x20, 0xd0, 0x96, 0x42]).buffer;
  const layer = { text: 'A� ЖB', bytes, hasReplacements: true };
  assert.equal(selectedText(layer, { start: 3, length: 3 }), 'ЖB');
  assert.equal(selectedText(layer, { start: 0, length: 6 }), layer.text);
});
