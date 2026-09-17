import { DjvuDecoder, mapPoint, mapRect } from '../../web/decoder.mjs';
import {
  subsampleFor, visibleTiles, selectableZones, hitZone, selectionBetween, selectedText, sourcePoint,
} from './reader-model.mjs';

const MEMORY_LIMIT = 64 * 1024 * 1024;
const errors = {
  InvalidData: 'The data is damaged or does not match the DjVu format.',
  Unsupported: 'This DjVu format is not supported yet.',
  MissingComponent: 'This document needs its separate component files.',
  ComponentLoadFailed: 'A component of this document could not be loaded.',
  SourceReadFailed: 'Part of this document could not be read.',
  LimitExceeded: 'This document exceeds the memory, size or complexity limit.',
  OutOfMemory: 'There is not enough memory for this page. Try another page or document.',
};
const messageFor = error => errors[error.code] ?? 'Could not read the document. Try opening it again.';

export class Reader {
  constructor(root, { wasmUrl = '/djvutang.wasm' } = {}) {
    this.root = root;
    this.wasmUrl = wasmUrl;
    this.el = Object.fromEntries([...root.querySelectorAll('[id]')].map(el => [el.id, el]));
    this.viewport = this.el.viewport;
    this.tiles = new Map();
    this.visible = [];
    this.pages = [];
    this.bookGeneration = this.pageGeneration = this.viewGeneration = 0;
    this.events = new AbortController();
    const on = (target, type, callback) => target.addEventListener(type, callback, { signal: this.events.signal });
    on(this.el.open, 'click', () => this.el.file.click());
    on(this.el.choose, 'click', () => this.el.file.click());
    on(this.el.file, 'change', () => {
      const file = this.el.file.files[0];
      this.el.file.value = '';
      if (file) void this.openFile(file);
    });
    on(this.el.sample, 'click', () => void this.openSource('Field notes.djvu', async signal => {
      const response = await fetch('/sample.djvu', { signal });
      if (!response.ok) throw new Error('Sample download failed');
      return response.arrayBuffer();
    }));
    on(root, 'dragover', event => { if ([...event.dataTransfer.types].includes('Files')) event.preventDefault(); });
    on(root, 'drop', event => {
      if (!event.dataTransfer.files.length) return;
      event.preventDefault();
      void this.openFile(event.dataTransfer.files[0]);
    });
    on(this.el.previous, 'click', () => void this.goTo(this.pageIndex - 1));
    on(this.el.next, 'click', () => void this.goTo(this.pageIndex + 1));
    on(this.el['page-number'], 'change', () => {
      const page = this.el['page-number'].valueAsNumber;
      if (Number.isInteger(page) && page >= 1 && page <= this.pages.length) void this.goTo(page - 1);
      else this.el['page-number'].value = this.pageIndex + 1;
    });
    on(this.el.zoom, 'change', () => this.setZoom(this.el.zoom.value));
    on(this.el['zoom-in'], 'click', () => this.setZoom(Math.min(4, this.actualZoom * 1.25)));
    on(this.el['zoom-out'], 'click', () => this.setZoom(Math.max(.02, this.actualZoom / 1.25)));
    on(this.el.rotate, 'click', () => { this.rotation = (this.rotation + 3) % 4; void this.layout(); });
    on(this.el.close, 'click', () => this.close());
    on(this.el.retry, 'click', () => void this.goTo(this.pageIndex));
    on(this.el['text-toggle'], 'click', () => this.showText(this.el['text-panel'].hidden));
    on(this.el['text-close'], 'click', () => { this.showText(false); this.el['text-toggle'].focus(); });
    on(this.el['clear-selection'], 'click', () => { this.clearSelection(); this.viewport.focus(); });
    on(this.el['copy-selection'], 'click', async () => {
      try {
        await navigator.clipboard.writeText(selectedText(this.layer, this.selection));
        this.el.status.textContent = 'Text copied';
      } catch {
        this.el.status.textContent = 'Copy with Ctrl/Cmd+C, or use the Text panel.';
      }
    });
    on(root, 'copy', event => {
      if (!this.selection || event.target.closest('textarea, input')) return;
      event.clipboardData.setData('text/plain', selectedText(this.layer, this.selection));
      event.preventDefault();
    });
    on(root, 'keydown', event => this.keydown(event));
    on(this.viewport, 'scroll', () => this.scheduleVisible());
    on(this.viewport, 'pointerdown', event => this.pointerDown(event));
    on(this.viewport, 'pointermove', event => {
      if (this.drag?.id !== event.pointerId) return;
      this.drag.x = event.clientX; this.drag.y = event.clientY;
      this.extendSelection(); this.autoScroll();
    });
    on(this.viewport, 'pointerup', () => this.endDrag());
    on(this.viewport, 'pointercancel', () => this.endDrag());
    on(window, 'pagehide', () => this.close());
    this.resize = new ResizeObserver(() => {
      if (this.pages.length && this.viewport.clientWidth && this.viewport.clientHeight) void this.layout();
    });
    this.resize.observe(this.viewport);
    this.close();
  }

  openFile(file) {
    return this.openSource(file.name, () => {
      if (file.size > 0xffffffff) throw Object.assign(new Error('LimitExceeded'), { code: 'LimitExceeded' });
      return { size: file.size, read: (offset, length) => file.slice(offset, offset + length).arrayBuffer() };
    });
  }

  async openSource(name, read) {
    this.close();
    const generation = this.bookGeneration;
    this.opening = true;
    this.sourceAbort = new AbortController();
    this.el.welcome.hidden = true;
    this.el.viewer.hidden = false;
    this.el.filename.textContent = name;
    this.el.filename.title = name;
    this.el.status.textContent = 'Opening document…';
    this.controls();
    let decoder;
    try {
      decoder = await DjvuDecoder.create(this.wasmUrl);
      if (generation !== this.bookGeneration) { decoder.destroy(); return; }
      this.decoder = decoder;
      const source = await read(this.sourceAbort.signal);
      if (generation !== this.bookGeneration) return;
      const { pages } = await decoder.open(source, { memoryLimit: MEMORY_LIMIT });
      if (generation !== this.bookGeneration) return;
      this.pages = pages;
      this.opening = false;
      if (!pages.length) throw Object.assign(new Error('InvalidData'), { code: 'InvalidData' });
      await this.goTo(0);
    } catch (error) {
      decoder?.destroy();
      if (generation !== this.bookGeneration) return;
      this.close();
      this.el['open-error'].textContent = messageFor(error);
      this.el['open-error'].hidden = false;
    }
  }

  close() {
    this.bookGeneration++; this.pageGeneration++; this.viewGeneration++;
    this.sourceAbort?.abort();
    this.decoder?.destroy();
    this.decoder = null;
    this.pages = [];
    this.pageIndex = 0;
    this.geometry = null;
    this.pendingAnchor = null;
    this.visible = [];
    this.layer = null;
    this.units = [];
    this.zoomMode = 'fit';
    this.zoomLevel = this.actualZoom = 1;
    this.rotation = 0;
    this.opening = false;
    this.renderFailure = null;
    this.el.viewport.setAttribute('aria-busy', 'false');
    this.dropTiles();
    this.clearSelection();
    this.el.welcome.hidden = false;
    this.el.viewer.hidden = true;
    this.el.page.hidden = true;
    this.el.problem.hidden = true;
    this.el['open-error'].hidden = true;
    this.el['text-panel'].hidden = true;
    this.el['page-text'].value = '';
    this.el.filename.textContent = 'DjVu'; this.el.filename.title = '';
    this.el.status.textContent = 'Reading locally';
    this.el['text-status'].textContent = '';
    this.controls();
  }

  destroy() {
    this.close();
    this.events.abort();
    this.resize.disconnect();
    cancelAnimationFrame(this.visibleFrame);
  }

  async goTo(index) {
    if (!this.pages[index]) return;
    this.pageIndex = index;
    this.pageGeneration++;
    this.layer = null; this.units = [];
    this.clearSelection();
    this.el['page-text'].value = '';
    this.el['page-text'].placeholder = 'Loading text…';
    this.el['text-status'].textContent = '';
    this.controls();
    void this.loadText(this.decoder, index, this.pageGeneration);
    await this.layout(true);
  }

  async loadText(decoder, page, generation) {
    try {
      const layer = await decoder.text(page);
      if (generation !== this.pageGeneration) return;
      this.layer = layer;
      this.units = layer ? selectableZones(layer) : [];
      this.el['page-text'].value = layer?.text ?? '';
      this.el['page-text'].setSelectionRange(0, 0);
      this.el['page-text'].scrollTop = 0;
      const status = !layer ? 'No embedded text'
        : !layer.text ? 'Empty text layer'
        : !this.units.length ? 'Text without positions'
        : 'Text available';
      this.el['text-status'].textContent = status;
      this.el['page-text'].placeholder = status;
      this.el['text-note'].textContent = this.units.length
        ? (matchMedia('(pointer: coarse)').matches ? 'Select and copy text here. ' : 'Drag across words on the page, or select text here. ')
          + 'The embedded text may contain recognition errors.'
        : 'Text is shown in the order stored in the document.';
      this.controls();
    } catch (error) {
      if (generation !== this.pageGeneration) return;
      this.el['text-status'].textContent = 'Text unavailable';
      this.el['page-text'].placeholder = 'Could not read the text on this page.';
      this.el['text-note'].textContent = messageFor(error);
      this.controls();
    }
  }

  setZoom(value) {
    if (!this.pages.length || value === 'custom') return;
    this.zoomMode = value === 'fit' ? 'fit' : 'manual';
    if (this.zoomMode === 'manual') this.zoomLevel = Math.max(.02, Math.min(4, Number(value)));
    void this.layout();
  }

  async layout(reset = false) {
    if (!this.decoder || !this.pages.length || !this.viewport.clientWidth || !this.viewport.clientHeight) return;
    const decoder = this.decoder;
    const page = this.pageIndex;
    const generation = ++this.viewGeneration;
    const current = () => generation === this.viewGeneration && decoder === this.decoder;
    const rect = this.viewport.getBoundingClientRect();
    let anchor = null;
    if (!reset) {
      anchor = this.geometry ? sourcePoint(
        this.geometry, this.scale, this.el.page.getBoundingClientRect(),
        rect.left + this.viewport.clientWidth / 2, rect.top + this.viewport.clientHeight / 2,
      ) : this.pendingAnchor;
    }
    this.pendingAnchor = anchor;
    this.endDrag();
    this.geometry = null;
    this.visible = [];
    this.dropTiles();
    this.renderFailure = null;
    this.retriedMemory = false;
    this.el.problem.hidden = true;
    this.el.status.textContent = 'Preparing page…';
    this.el.viewport.setAttribute('aria-busy', 'true');
    try {
      await decoder.cancelRender();
      if (generation !== this.viewGeneration) return;
      const base = await this.withMemoryRetry(decoder, current, () => decoder.geometry(page, { rotation: this.rotation }));
      if (generation !== this.viewGeneration) return;
      const viewport = { width: this.viewport.clientWidth, height: this.viewport.clientHeight };
      const zoom = this.zoomMode === 'fit'
        ? Math.min(1, Math.max(1, viewport.width - 48) / base.width, Math.max(1, viewport.height - 48) / base.height) : this.zoomLevel;
      const ss = subsampleFor(base.width, base.height, zoom, viewport, devicePixelRatio);
      const options = { subsample: ss, rotation: this.rotation };
      const geometry = ss === 1 ? base : await decoder.geometry(page, options);
      if (generation !== this.viewGeneration) return;
      this.geometry = geometry; this.options = options;
      this.actualZoom = zoom; this.scale = zoom * ss;
      this.el.page.style.width = `${this.snap(geometry.width * this.scale)}px`;
      this.el.page.style.height = `${this.snap(geometry.height * this.scale)}px`;
      this.el.page.hidden = false;
      this.el.viewport.setAttribute('aria-label',
        `Page ${page + 1} of ${this.pages.length}. Use the left and right arrow keys to change pages.`);
      if (anchor && this.zoomMode !== 'fit') {
        const point = mapPoint(geometry.matrix, anchor);
        this.viewport.scrollTo(this.el.page.offsetLeft + point.x * this.scale - viewport.width / 2,
          this.el.page.offsetTop + point.y * this.scale - viewport.height / 2);
      } else this.viewport.scrollTo(0, 0);
      this.controls();
      this.scheduleVisible();
    } catch (error) {
      if (generation === this.viewGeneration) this.pageError(error);
    }
  }

  snap(value) { return Math.round(value * devicePixelRatio) / devicePixelRatio; }

  async withMemoryRetry(decoder, current, action) {
    try { return await action(); }
    catch (error) {
      // The configured allocation budget reports LimitExceeded; the underlying
      // allocator reports OutOfMemory. Both may be relieved by dropping caches.
      // Other size/complexity limits use the same code, so retry only once per view.
      if (!['LimitExceeded', 'OutOfMemory'].includes(error.code) || !current() || this.retriedMemory) throw error;
      this.retriedMemory = true;
      await decoder.dropCache();
      if (!current()) throw error;
      return action();
    }
  }

  dropTiles() {
    for (const canvas of this.tiles.values()) {
      canvas.remove();
      canvas.width = canvas.height = 0;
    }
    this.tiles.clear();
  }

  scheduleVisible() {
    if (this.visibleFrame) return;
    this.visibleFrame = requestAnimationFrame(() => {
      this.visibleFrame = 0;
      this.refreshVisible();
    });
  }

  refreshVisible() {
    if (!this.geometry || this.renderFailure) {
      this.drawSelection();
      return;
    }
    const viewport = this.viewport.getBoundingClientRect(), page = this.el.page.getBoundingClientRect();
    this.visible = visibleTiles(this.geometry.width, this.geometry.height, {
      x: (viewport.left - page.left) / this.scale, y: (viewport.top - page.top) / this.scale,
      width: this.viewport.clientWidth / this.scale, height: this.viewport.clientHeight / this.scale,
    });
    const keep = new Set(this.visible.map(tile => tile.key));
    for (const [key, canvas] of this.tiles) {
      if (keep.has(key)) continue;
      canvas.remove();
      canvas.width = canvas.height = 0;
      this.tiles.delete(key);
    }
    this.drawSelection();
    void this.pump();
  }

  async pump() {
    if (this.inFlight || !this.geometry || this.renderFailure) return;
    const tile = this.visible.find(tile => !this.tiles.has(tile.key));
    if (!tile) {
      this.el.status.textContent = `Page ${this.pageIndex + 1} of ${this.pages.length}`;
      this.el.viewport.setAttribute('aria-busy', 'false');
      return;
    }
    const token = { decoder: this.decoder, generation: this.viewGeneration };
    const current = () => token.generation === this.viewGeneration && token.decoder === this.decoder;
    this.inFlight = token;
    this.el.status.textContent = 'Rendering page…';
    this.el.viewport.setAttribute('aria-busy', 'true');
    const options = { ...this.options, region: { x: tile.x, y: tile.y, width: tile.width, height: tile.height } };
    const page = this.pageIndex;
    try {
      const result = await this.withMemoryRetry(token.decoder, current, () => token.decoder.render(page, options));
      if (!current() || !this.visible.some(t => t.key === tile.key)) return;
      const canvas = document.createElement('canvas');
      canvas.setAttribute('aria-hidden', 'true');
      canvas.width = result.width; canvas.height = result.height;
      const left = this.snap(tile.x * this.scale), top = this.snap(tile.y * this.scale);
      Object.assign(canvas.style, { left: `${left}px`, top: `${top}px`,
        width: `${this.snap((tile.x + tile.width) * this.scale) - left}px`,
        height: `${this.snap((tile.y + tile.height) * this.scale) - top}px` });
      const image = new ImageData(new Uint8ClampedArray(result.rgba), result.width, result.height);
      canvas.getContext('2d').putImageData(image, 0, 0);
      this.tiles.set(tile.key, canvas);
      this.el.tiles.append(canvas);
    } catch (error) {
      if (current() && error.code !== 'Cancelled') this.pageError(error);
    } finally {
      if (this.inFlight === token) this.inFlight = null;
      this.scheduleVisible();
    }
  }

  pageError(error) {
    this.renderFailure = error;
    this.visible = [];
    this.dropTiles();
    this.el.page.hidden = true;
    this.el.problem.hidden = false;
    this.el['problem-text'].textContent = messageFor(error);
    this.el.status.textContent = `Page ${this.pageIndex + 1} of ${this.pages.length}`;
    this.el.viewport.setAttribute('aria-busy', 'false');
    this.drawSelection();
  }

  showText(show) {
    this.el['text-panel'].hidden = !show;
    this.controls();
    if (show) this.el['page-text'].focus();
  }

  controls() {
    const open = this.pages.length > 0;
    this.el.previous.disabled = !open || this.pageIndex === 0;
    this.el.next.disabled = !open || this.pageIndex + 1 >= this.pages.length;
    this.el['page-number'].disabled = !open;
    this.el['page-number'].value = this.pageIndex + 1;
    this.el['page-number'].max = this.pages.length;
    this.el['page-count'].textContent = `/ ${this.pages.length}`;
    for (const id of ['zoom', 'rotate']) this.el[id].disabled = !open;
    this.el['zoom-in'].disabled = !open || this.actualZoom >= 4;
    this.el['zoom-out'].disabled = !open || this.actualZoom <= .02;
    this.el.close.disabled = !open && !this.opening;
    const panelOpen = !this.el['text-panel'].hidden;
    this.el['text-toggle'].disabled = !this.layer?.text && !panelOpen;
    this.el['text-toggle'].setAttribute('aria-expanded', String(panelOpen));
    if (this.zoomMode === 'fit') this.el.zoom.value = 'fit';
    else {
      const value = String(this.zoomLevel);
      if ([...this.el.zoom.options].some(o => o.value === value)) this.el.zoom.value = value;
      else {
        this.el['custom-zoom'].textContent = `${Math.round(this.zoomLevel * 100)}%`;
        this.el['custom-zoom'].hidden = false;
        this.el.zoom.value = 'custom';
      }
    }
  }

  clearSelection() {
    this.endDrag();
    this.selection = null; this.selectionAnchor = null;
    this.el['selection-bar'].hidden = true;
    this.drawSelection();
  }

  pointerDown(event) {
    // Touch keeps native scrolling. The text panel provides native touch and
    // keyboard selection without stealing a pan that started over a word.
    if (event.button !== 0 || event.pointerType === 'touch' || !this.geometry || this.renderFailure) return;
    const point = sourcePoint(this.geometry, this.scale, this.el.page.getBoundingClientRect(), event.clientX, event.clientY);
    const zone = hitZone(this.units, point);
    if (!zone) { this.clearSelection(); return; }
    event.preventDefault();
    this.viewport.focus({ preventScroll: true });
    this.viewport.setPointerCapture(event.pointerId);
    this.selectionAnchor = event.shiftKey && this.selectionAnchor ? this.selectionAnchor : zone;
    this.drag = { id: event.pointerId, x: event.clientX, y: event.clientY };
    this.extendSelection();
  }

  extendSelection() {
    if (!this.drag || !this.geometry) return;
    const point = sourcePoint(this.geometry, this.scale, this.el.page.getBoundingClientRect(), this.drag.x, this.drag.y);
    const zone = hitZone(this.units, point, true);
    if (!zone) return;
    this.selection = selectionBetween(this.selectionAnchor, zone);
    this.el['selection-bar'].hidden = false;
    this.drawSelection();
  }

  autoScroll() {
    if (!this.drag || this.scrollFrame) return;
    const rect = this.viewport.getBoundingClientRect();
    const edge = (p, low, high) => p < low + 24 ? -12 : p > high - 24 ? 12 : 0;
    const dx = edge(this.drag.x, rect.left, rect.right), dy = edge(this.drag.y, rect.top, rect.bottom);
    if (!dx && !dy) return;
    this.scrollFrame = requestAnimationFrame(() => {
      this.scrollFrame = 0;
      if (!this.drag) return;
      this.viewport.scrollBy(dx, dy);
      this.extendSelection(); this.autoScroll();
    });
  }

  endDrag() {
    if (this.drag && this.viewport.hasPointerCapture(this.drag.id)) this.viewport.releasePointerCapture(this.drag.id);
    this.drag = null;
    cancelAnimationFrame(this.scrollFrame); this.scrollFrame = 0;
  }

  drawSelection() {
    const ink = this.el['selection-ink'];
    if (!this.selection || !this.geometry || this.renderFailure) {
      ink.width = ink.height = 0;
      return;
    }
    const width = this.viewport.clientWidth, height = this.viewport.clientHeight;
    if (!width || !height) return;
    const ratio = Math.min(devicePixelRatio, 2, Math.sqrt(4 * 1024 * 1024 / (width * height)));
    const w = Math.floor(width * ratio), h = Math.floor(height * ratio);
    if (ink.width !== w || ink.height !== h) { ink.width = w; ink.height = h; }
    ink.style.width = `${width}px`; ink.style.height = `${height}px`;
    const ctx = ink.getContext('2d');
    ctx.resetTransform();
    ctx.clearRect(0, 0, w, h);
    ctx.scale(ratio, ratio);
    const page = this.el.page.getBoundingClientRect(), viewport = this.viewport.getBoundingClientRect();
    ctx.translate(page.left - viewport.left, page.top - viewport.top);
    ctx.fillStyle = '#65a97555'; ctx.strokeStyle = '#56885a'; ctx.lineWidth = 1;
    const end = this.selection.start + this.selection.length;
    for (const zone of this.units) {
      if (zone.start >= end || zone.start + zone.length <= this.selection.start) continue;
      const r = mapRect(this.geometry.matrix, zone);
      const x = r.x * this.scale, y = r.y * this.scale, rw = r.width * this.scale, rh = r.height * this.scale;
      if (x + rw < viewport.left - page.left || y + rh < viewport.top - page.top
        || x > viewport.right - page.left || y > viewport.bottom - page.top) continue;
      ctx.fillRect(x, y, rw, rh); ctx.strokeRect(x, y, rw, rh);
    }
  }

  keydown(event) {
    if (event.target.closest('input, textarea, select')) return;
    if (event.key === 'Escape') {
      if (this.selection) this.clearSelection();
      else if (!this.el['text-panel'].hidden) { this.showText(false); this.el['text-toggle'].focus(); }
    } else if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'a' && event.target === this.viewport && this.layer?.text) {
      event.preventDefault();
      this.selection = { start: 0, length: this.layer.bytes.byteLength };
      this.el['selection-bar'].hidden = false; this.drawSelection();
    } else if (!event.ctrlKey && !event.metaKey && !event.altKey && this.pages.length) {
      if (event.key === 'ArrowRight') { event.preventDefault(); void this.goTo(this.pageIndex + 1); }
      if (event.key === 'ArrowLeft') { event.preventDefault(); void this.goTo(this.pageIndex - 1); }
    }
  }
}
