/** A decoder or host failure with a stable, machine-readable code. */
export class DjvuError extends Error {
  constructor(code, message = code, { cause } = {}) {
    super(message);
    this.name = 'DjvuError';
    this.code = code;
    if (cause !== undefined) this.cause = cause;
  }
}

/** Browser adapter. One Worker, one document and one render at a time. */
export class DjvuDecoder {
  #worker;
  #pending = new Map();
  #sequence = 0;
  #source = 0;
  #componentRequests = new Map();
  #loadComponent;
  #readRange;

  /** Accepts a URL, WASM bytes, or a compiled module shared by several decoders.
   * workerUrl lets an application place its Worker independently of this module.
   */
  static async create(source = new URL('./djvutang.wasm', import.meta.url), { workerUrl } = {}) {
    let module;
    try {
      if (typeof source === 'string' || source instanceof URL) {
        const response = await fetch(source);
        if (!response.ok) throw new Error(`WASM download failed: ${response.status}`);
        source = await response.arrayBuffer();
      }
      module = source instanceof WebAssembly.Module ? source : await WebAssembly.compile(source);
    } catch (cause) {
      throw new DjvuError('WasmLoadFailed', 'Could not load or compile the decoder WASM', { cause });
    }
    const decoder = new DjvuDecoder(workerUrl);
    try {
      await decoder.#request('init', { module });
      return decoder;
    } catch (error) {
      decoder.destroy();
      throw error;
    }
  }

  constructor(workerUrl = new URL('./worker.mjs', import.meta.url)) {
    try {
      this.#worker = new Worker(workerUrl, { type: 'module' });
    } catch (cause) {
      throw new DjvuError('WorkerFailed', 'Could not start the decoder Worker', { cause });
    }
    this.#worker.onmessage = ({ data }) => {
      if (data.type === 'component-request' || data.type === 'range-request') {
        void this.#loadRequestedComponent(data);
        return;
      }
      if (data.type === 'component-cancel') {
        this.#componentRequests.get(data.request)?.abort();
        this.#componentRequests.delete(data.request);
        return;
      }
      const request = this.#pending.get(data.id);
      if (!request) return;
      this.#pending.delete(data.id);
      if (data.error) request.reject(new DjvuError(data.error.code, data.error.message));
      else request.resolve(data.result);
    };
    this.#worker.onerror = () => this.#terminate(new DjvuError('WorkerFailed', 'Decoder Worker failed'));
    this.#worker.onmessageerror = () => this.#terminate(new DjvuError('WorkerFailed', 'Could not read a decoder Worker response'));
  }

  #request(type, payload = {}, transfer = []) {
    if (!this.#worker) return Promise.reject(new DjvuError('Destroyed', 'Decoder has been destroyed'));
    const id = ++this.#sequence;
    return new Promise((resolve, reject) => {
      this.#pending.set(id, { resolve, reject });
      try { this.#worker.postMessage({ id, type, ...payload }, transfer); }
      catch (cause) {
        this.#pending.delete(id);
        reject(new DjvuError('InvalidArgument', 'Could not transfer the request to the decoder Worker', { cause }));
      }
    });
  }

  /** Accepts an ArrayBuffer (transferred) or { size, read(offset, length, { signal }) }.
   * Range readers return exactly the requested bytes as an ArrayBuffer (transferred).
   * Bundled files load pages on demand; standalone files are read whole.
   * Indirect files use loadComponent(component, { signal }). The host resolves names.
   */
  open(bytes, { memoryLimit = 64 * 1024 * 1024, cacheLimit = Math.floor(memoryLimit / 4), loadComponent } = {}) {
    if (!this.#worker) return Promise.reject(new DjvuError('Destroyed', 'Decoder has been destroyed'));
    const ranged = !(bytes instanceof ArrayBuffer);
    if (ranged && (!bytes || typeof bytes.read !== 'function'
      || !Number.isInteger(bytes.size) || bytes.size < 1 || bytes.size > 0xffffffff)) {
      return Promise.reject(new DjvuError('InvalidArgument'));
    }
    if (loadComponent != null && typeof loadComponent !== 'function') {
      return Promise.reject(new DjvuError('InvalidArgument'));
    }
    try {
      if (!ranged) new Uint8Array(bytes);
    } catch {
      return Promise.reject(new DjvuError('InvalidArgument'));
    }
    this.#abortComponents();
    this.#loadComponent = loadComponent;
    this.#readRange = ranged ? bytes.read.bind(bytes) : undefined;
    return this.#request('open', {
      ...(ranged ? { size: bytes.size } : { bytes }),
      memoryLimit, cacheLimit, source: ++this.#source,
    }, ranged ? [] : [bytes]);
  }

  async #loadRequestedComponent(message) {
    if (!this.#worker || message.source !== this.#source) return;
    const controller = new AbortController();
    this.#componentRequests.set(message.request, controller);
    let bytes, error;
    const range = message.range ?? message.component?.range;
    try {
      if (range) {
        if (!this.#readRange) throw new DjvuError('MissingComponent');
        bytes = await this.#readRange(range.offset, range.length, { signal: controller.signal });
      } else {
        if (!this.#loadComponent) throw new DjvuError('MissingComponent');
        bytes = await this.#loadComponent(message.component, { signal: controller.signal });
      }
      if (!(bytes instanceof ArrayBuffer)) throw new DjvuError('InvalidArgument');
      if (range && bytes.byteLength !== range.length) throw new DjvuError('InvalidArgument');
    } catch (cause) {
      if (['MissingComponent', 'InvalidArgument'].includes(cause?.code)) {
        error = cause.code;
      } else {
        error = range ? 'SourceReadFailed' : 'ComponentLoadFailed';
      }
    }
    if (controller.signal.aborted || !this.#worker || message.source !== this.#source) return;
    this.#componentRequests.delete(message.request);
    try {
      this.#worker.postMessage({
        type: 'component-response', request: message.request, source: message.source,
        bytes: error ? undefined : bytes, error,
      }, error ? [] : [bytes]);
    } catch {
      this.#worker.postMessage({
        type: 'component-response', request: message.request, source: message.source, error: 'InvalidArgument',
      });
    }
  }

  #abortComponents() {
    for (const controller of this.#componentRequests.values()) controller.abort();
    this.#componentRequests.clear();
  }

  /** Output geometry and source→region / region→source affine matrices.
   * Source coordinates are unrotated INFO pixels, top-left. No layers decoded.
   */
  geometry(page, { subsample = 1, size = null, rotation = 0, region = null } = {}) {
    return this.#request('geometry', { page, subsample, size, rotation, region });
  }

  /** Owned display text, original bytes and tree; null if absent.
   * hasReplacements reports malformed UTF-8. Zone ranges address original bytes.
   */
  text(page) { return this.#request('text', { page }); }

  /** Owned annotation snapshot or null. Areas use unrotated, top-left pixels;
   * geometry().matrix maps them into the rendered region. Links are data only.
   */
  annotations(page) { return this.#request('annotations', { page }); }

  /** Owned NAVM snapshot, or null. Flat preorder entries carry parent/subtreeEnd.
   * Reads the index only; does not load pages or cancel a render.
   */
  outline() { return this.#request('outline'); }

  /** Classify a DjVu href and resolve internal page references without IO.
   * Relative links require fromPage; page numbers in the result are zero-based.
   */
  resolveLink(href, fromPage = null) { return this.#request('resolve-link', { href, fromPage }); }

  /** Owned RGBA for a zero-based page. Render tiles sequentially: a new request
   * cancels the current render or storedThumbnail request with Cancelled.
   */
  render(page, { subsample = 1, size = null, rotation = 0, region = null } = {}) {
    return this.#request('render', { page, subsample, size, rotation, region });
  }

  /** Stored thumbnail at its encoded size/orientation, or null if absent.
   * Owns its RGBA buffer and shares render's job slot and cancellation.
   * A missing thumbnail never triggers a page render.
   */
  storedThumbnail(page) { return this.#request('thumbnail', { page }); }

  /** Cancels the current render/thumbnail with Cancelled. Metadata reads continue. */
  cancelRender() { return this.#request('cancel'); }
  /** Cancels pending operations and releases cached components and decoded layers. */
  dropCache() { this.#abortComponents(); return this.#request('drop-cache'); }
  /** Current allocation counters and timing of the most recently started render. */
  diagnostics() { return this.#request('diagnostics'); }
  /** Cancels pending operations and closes the document; the Worker can be reused. */
  close() {
    this.#abortComponents();
    this.#loadComponent = undefined;
    this.#readRange = undefined;
    this.#source++;
    return this.#request('close');
  }

  /** Terminates the Worker and cancels all pending operations. Safe to repeat. */
  destroy() { this.#terminate(new DjvuError('Cancelled')); }

  #terminate(error) {
    this.#abortComponents();
    this.#loadComponent = undefined;
    this.#readRange = undefined;
    this.#worker?.terminate();
    this.#worker = null;
    for (const request of this.#pending.values()) request.reject(error);
    this.#pending.clear();
  }
}

const utf8 = new TextDecoder('utf-8', { ignoreBOM: true });

/** Decode a byte span; JS String.substring uses different units. */
export function zoneText(layer, zone) {
  return utf8.decode(new Uint8Array(layer.bytes, zone.start, zone.length));
}

export function mapPoint(matrix, { x, y }) {
  return { x: matrix[0] * x + matrix[2] * y + matrix[4], y: matrix[1] * x + matrix[3] * y + matrix[5] };
}

export function mapRect(matrix, { x, y, width, height }) {
  const points = [[x, y], [x + width, y], [x, y + height], [x + width, y + height]]
    .map(([x, y]) => mapPoint(matrix, { x, y }));
  const left = Math.min(...points.map(p => p.x));
  const top = Math.min(...points.map(p => p.y));
  return {
    x: left, y: top,
    width: Math.max(...points.map(p => p.x)) - left,
    height: Math.max(...points.map(p => p.y)) - top,
  };
}
