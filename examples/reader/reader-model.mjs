import { mapPoint, zoneText } from '../../web/decoder.mjs';

export const TILE_SIZE = 512;
export const MAX_TILES = 24;

// Integer reduction supplies enough source pixels for the display. At unusually
// large viewports, reduce resolution further to keep the canvas working set finite.
export function subsampleFor(width, height, zoom, viewport, dpr) {
  let ss = Math.max(1, Math.min(256, Math.floor(1 / (zoom * Math.min(2, dpr)))));
  const count = s => {
    const columns = Math.min(
      Math.ceil(Math.ceil(width / s) / TILE_SIZE),
      Math.ceil(viewport.width / (zoom * s * TILE_SIZE)) + 1,
    );
    const rows = Math.min(
      Math.ceil(Math.ceil(height / s) / TILE_SIZE),
      Math.ceil(viewport.height / (zoom * s * TILE_SIZE)) + 1,
    );
    return columns * rows;
  };
  while (ss < 256 && count(ss) > MAX_TILES) ss++;
  return ss;
}

/** Visible tiles only, ordered from the viewport center. Bounds are output pixels. */
export function visibleTiles(width, height, bounds) {
  const left = Math.max(0, bounds.x), top = Math.max(0, bounds.y);
  const right = Math.min(width, bounds.x + bounds.width), bottom = Math.min(height, bounds.y + bounds.height);
  if (right <= left || bottom <= top) return [];
  const tiles = [], cx = (left + right) / 2, cy = (top + bottom) / 2;
  for (let y = Math.floor(top / TILE_SIZE) * TILE_SIZE; y < bottom; y += TILE_SIZE) {
    for (let x = Math.floor(left / TILE_SIZE) * TILE_SIZE; x < right; x += TILE_SIZE) {
      tiles.push({ key: `${x}:${y}`, x, y, width: Math.min(TILE_SIZE, width - x), height: Math.min(TILE_SIZE, height - y) });
    }
  }
  return tiles.sort((a, b) => Math.hypot(a.x + a.width / 2 - cx, a.y + a.height / 2 - cy)
    - Math.hypot(b.x + b.width / 2 - cx, b.y + b.height / 2 - cy));
}

// A word may contain character zones. Select it once; when there are no words,
// use the finest available zones (a line, paragraph, or even a whole page).
export function selectableZones(layer) {
  const result = [];
  for (let i = 0; i < layer.zones.length;) {
    const z = layer.zones[i];
    if (z.type === 'word' || z.subtreeEnd === i + 1) {
      if (z.length && z.width > 0 && z.height > 0) result.push(z);
      i = z.subtreeEnd;
    } else i++;
  }
  return result;
}

export function hitZone(zones, point, nearest = false) {
  let found = null, distance = Infinity;
  for (const z of zones) {
    const dx = Math.max(z.x - point.x, 0, point.x - z.x - z.width);
    const dy = Math.max(z.y - point.y, 0, point.y - z.y - z.height);
    const d = dx * dx + dy * dy;
    if ((nearest || d === 0) && d < distance) { found = z; distance = d; }
  }
  return found;
}

export function selectionBetween(a, b) {
  const start = Math.min(a.start, b.start);
  return { start, length: Math.max(a.start + a.length, b.start + b.length) - start };
}

export function selectedText(layer, selection) {
  return layer && selection ? zoneText(layer, selection) : '';
}

export function sourcePoint(geometry, scale, pageRect, clientX, clientY) {
  return mapPoint(geometry.inverse, { x: (clientX - pageRect.left) / scale, y: (clientY - pageRect.top) / scale });
}
