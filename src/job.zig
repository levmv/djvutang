const std = @import("std");
const types = @import("types.zig");
const Error = types.Error;
const iff = @import("iff.zig");
const Document = @import("document.zig").Document;
const jb2 = @import("jb2.zig");
const composite = @import("composite.zig");
const iw44 = @import("iw44.zig");
const mmr = @import("mmr.zig");
const jpeg = @import("jpeg.zig");
const Pixmap = @import("pixmap.zig").Pixmap;
const Bitmap = @import("pixmap.zig").Bitmap;
const color = @import("color.zig");

const raster_cache_pixels = 2 * 1024 * 1024;
const full_raster_pixels = 8 * 1024 * 1024;

const Task = struct { component: usize, parent: ?usize, data: []const u8, dictionary: bool };
const Layer = struct {
    wavelets: std.ArrayList([]const u8) = .empty,
    jpeg: ?[]const u8 = null,

    fn present(self: Layer) bool {
        return self.jpeg != null or self.wavelets.items.len != 0;
    }
};
pub const Status = enum { progress, done };

/// One active job per Document. No partially decoded image is exposed.
/// Completed shared dictionaries can survive cancellation; partial ones cannot.
/// Keep the Job at a stable address after stepping: the renderer borrows its layers.
pub const Job = struct {
    doc: *Document,
    info: iff.Info,
    options: composite.Options,
    tasks: std.ArrayList(Task) = .empty,
    task: usize = 0,
    decoder: ?jb2.Decoder = null,
    legacy_jb2: bool = false,
    image: ?jb2.Image = null,
    mmr_data: ?[]const u8 = null,
    mmr_decoder: ?mmr.Decoder = null,
    bitmap: ?Bitmap = null,
    layers: [2]Layer = .{ .{}, .{} },
    palette_data: ?[]const u8 = null,
    palette: ?color.Palette = null,
    // A transient decoder transfers its completed raster to background/foreground.
    // Regional decoders instead own coefficients and reusable rasters for the job.
    wavelet: ?iw44.Decoder = null,
    regional: [2]?iw44.Decoder = .{ null, null },
    jpeg_decoder: ?jpeg.Decoder = null,
    background: ?Pixmap = null,
    foreground: ?Pixmap = null,
    layer: usize = 0,
    renderer: ?composite.Renderer = null,
    failure: ?Error = null,
    completed: bool = false,
    // Maximum IW44 reduction for sized output; null disables reduced grids.
    // Public renders use 4. Integer subsample always uses full reconstruction.
    preview_limit: ?u32 = null,
    // Tests retain coefficients even at full resolution to exercise grid changes.
    retain_preview_coefficients: bool = false,
    iw44_reductions: [2]u32 = .{ 0, 0 },

    pub fn init(doc: *Document, page: usize, options: composite.Options) Error!Job {
        if (doc.busy) return error.Busy;
        const info = try doc.info(page);
        _ = try composite.Geometry.init(info, options);
        const component = try doc.pageComponent(page);
        const kind = try (try doc.componentForm(component)).formType();
        const standalone_iw44 = iff.isIw44(kind) or iff.tag(kind, "THUM");
        const wavelet_tag = if (iff.tag(kind, "THUM")) "TH44" else kind;
        var self: Job = .{ .doc = doc, .info = info, .options = options };
        errdefer self.tasks.deinit(doc.allocator);
        errdefer for (&self.layers) |*layer| layer.wavelets.deinit(doc.allocator);
        var mask: ?[]const u8 = null;
        var chunks = try doc.pageChunks(page);
        defer chunks.deinit();
        while (try chunks.next()) |entry| {
            const c = entry.chunk;
            if (standalone_iw44) {
                if (iff.tag(c.id, wavelet_tag)) {
                    const layer = &self.layers[0];
                    if (layer.wavelets.items.len >= 256) return error.LimitExceeded;
                    try layer.wavelets.append(doc.allocator, c.data);
                } else if (iff.isIw44(c.id)) return error.InvalidData;
            } else if (iff.tag(c.id, "INFO")) {
                self.legacy_jb2 = try iff.infoVersion(c.data) <= 18;
            } else if (iff.tag(c.id, "Sjbz") or iff.tag(c.id, "Smmr")) {
                if (mask != null or self.mmr_data != null) return error.InvalidData;
                if (iff.tag(c.id, "Sjbz")) mask = c.data else self.mmr_data = c.data;
            } else if (iff.tag(c.id, "BG44") or iff.tag(c.id, "FG44")) {
                const foreground = iff.tag(c.id, "FG44");
                const layer = &self.layers[@intFromBool(foreground)];
                if (layer.jpeg != null or (foreground and layer.present())) return error.InvalidData;
                if (layer.wavelets.items.len >= 256) return error.LimitExceeded;
                try layer.wavelets.append(doc.allocator, c.data);
            } else if (iff.tag(c.id, "BGjp") or iff.tag(c.id, "FGjp")) {
                const layer = &self.layers[@intFromBool(iff.tag(c.id, "FGjp"))];
                if (layer.present()) return error.InvalidData;
                layer.jpeg = c.data;
            } else if (iff.tag(c.id, "FGbz")) {
                if (self.palette_data != null) return error.InvalidData;
                self.palette_data = c.data;
            } else if (iff.isIw44(c.id) or std.mem.startsWith(u8, c.id, "BG") or std.mem.startsWith(u8, c.id, "FG")) {
                return error.Unsupported;
            }
        }
        const has_mask = mask != null or self.mmr_data != null;
        const has_foreground = self.layers[1].present() or self.palette_data != null;
        if (self.layers[1].present() and self.palette_data != null) return error.InvalidData;
        if (!has_mask and has_foreground) return error.InvalidData;
        for (self.layers) |layer| {
            const layer_chunks = layer.wavelets.items;
            if (layer_chunks.len == 0) continue;
            const header = try iw44.Header.parse(layer_chunks[0]);
            _ = try color.reduction(info.width, info.height, header.width, header.height);
        }
        if (self.layers[0].wavelets.items.len != 0 or self.layers[1].wavelets.items.len != 0) {
            self.preview_limit = 4;
        }
        if (mask) |data| {
            const visited = try doc.allocator.alloc(u8, doc.components.items.len);
            defer doc.allocator.free(visited);
            @memset(visited, 0);
            const parents = try doc.allocator.alloc(?usize, doc.components.items.len);
            defer doc.allocator.free(parents);
            @memset(parents, null);
            const parent = try self.collect(component, visited, parents, 0);
            try self.tasks.append(doc.allocator, .{
                .component = component,
                .parent = parent,
                .data = data,
                .dictionary = false,
            });
        }
        for (chunks.visited, 0..) |visited, index| {
            if (visited != 0) doc.cache.touch(doc.components.items, index);
        }
        doc.busy = true;
        return self;
    }

    /// Decode a stored thumbnail at its encoded size and orientation. No page
    /// layers or INFO are read, and absent thumbnails do not trigger page renders.
    pub fn initThumbnail(doc: *Document, page: usize) Error!?Job {
        if (doc.busy) return error.Busy;
        const component = (try doc.thumbnailComponent(page)) orelse return null;
        const chunk = (try doc.thumbnailChunk(page)) orelse return null;
        const header = try iw44.Header.parse(chunk.data);
        const pixel_count = std.math.mul(usize, header.width, header.height) catch return error.LimitExceeded;
        if (pixel_count > doc.limits.max_page_pixels) return error.LimitExceeded;
        var self: Job = .{
            .doc = doc,
            .info = .{
                .width = header.width,
                .height = header.height,
                .dpi = 300,
                .rotation = 0,
            },
            .options = .{},
        };
        // Encoded thumbnails already have their display orientation and color.
        // INFO gamma/rotation belong to the page and must not be applied again.
        const layer = &self.layers[0];
        errdefer layer.wavelets.deinit(doc.allocator);
        if (doc.components.items[component].kind == .page) {
            // The page-local producer convention uses successive TH44 chunks
            // for one image. Unlike THUM, these are not independent thumbnails.
            var chunks = try (try doc.componentForm(component)).children();
            var count: usize = 0;
            while (try chunks.next()) |part| {
                count += 1;
                if (count > doc.limits.max_chunks) return error.LimitExceeded;
                if (!iff.tag(part.id, "TH44")) continue;
                if (layer.wavelets.items.len >= 256) return error.LimitExceeded;
                try layer.wavelets.append(doc.allocator, part.data);
            }
        } else try layer.wavelets.append(doc.allocator, chunk.data);
        doc.cache.touch(doc.components.items, component);
        doc.busy = true;
        return self;
    }

    fn collect(self: *Job, component: usize, visited: []u8, parents: []?usize, depth: usize) Error!?usize {
        if (depth >= self.doc.limits.max_include_depth) return error.LimitExceeded;
        if (visited[component] == 1) return error.InvalidData;
        if (visited[component] == 2) return parents[component];
        visited[component] = 1;
        var parent: ?usize = null;
        var chunks = try (try self.doc.componentForm(component)).children();
        var count: usize = 0;
        while (try chunks.next()) |chunk| {
            count += 1;
            if (count > self.doc.limits.max_chunks) return error.LimitExceeded;
            if (!iff.tag(chunk.id, "INCL")) continue;
            const child = try self.doc.resolve(chunk.data);
            const inherited = try self.collect(child, visited, parents, depth + 1);
            if (inherited) |p| {
                if (parent) |previous| {
                    // Some producers include the same DJVI under two IDs. Exact
                    // FORM payload equality also covers their inherited context.
                    // Different dictionaries remain ambiguous.
                    if (previous != p) {
                        const previous_form = try self.doc.componentForm(previous);
                        const inherited_form = try self.doc.componentForm(p);
                        if (!std.mem.eql(u8, previous_form.data, inherited_form.data)) return error.Unsupported;
                    }
                } else parent = p;
            }
        }
        if (try self.doc.find(component, "Djbz")) |chunk| {
            if (self.doc.components.items[component].dictionary == null) {
                try self.tasks.append(self.doc.allocator, .{
                    .component = component,
                    .parent = parent,
                    .data = chunk.data,
                    .dictionary = true,
                });
            }
            parent = component;
        }
        visited[component] = 2;
        parents[component] = parent;
        return parent;
    }

    pub fn cancel(self: *Job) void {
        if (!self.completed and self.failure == null) self.failure = error.Cancelled;
    }

    pub fn deinit(self: *Job) void {
        if (self.decoder) |*decoder| decoder.deinit();
        if (self.renderer) |*renderer| renderer.deinit();
        if (self.image) |*image| image.deinit(self.doc.allocator);
        if (self.mmr_decoder) |*decoder| decoder.deinit();
        if (self.bitmap) |*image| image.deinit(self.doc.allocator);
        if (self.wavelet) |*decoder| decoder.deinit();
        for (&self.regional) |*layer| if (layer.*) |*decoder| decoder.deinit();
        if (self.jpeg_decoder) |*decoder| decoder.deinit();
        if (self.background) |*image| image.deinit(self.doc.allocator);
        if (self.foreground) |*image| image.deinit(self.doc.allocator);
        if (self.palette) |*palette| palette.deinit(self.doc.allocator);
        self.tasks.deinit(self.doc.allocator);
        for (&self.layers) |*layer| layer.wavelets.deinit(self.doc.allocator);
        self.doc.busy = false;
        self.* = undefined;
    }

    /// Borrowed RGBA, valid until a successful restart or deinit.
    pub fn pixels(self: *const Job) Error![]const u8 {
        if (self.failure) |err| return err;
        if (!self.completed) return error.Busy;
        return self.renderer.?.rgba;
    }

    pub fn geometry(self: *const Job) Error!composite.Geometry {
        return composite.Geometry.init(self.info, self.options);
    }

    /// Keep the decoded page and union mask while changing scale/rotation/region.
    /// Large or reduced wavelet layers retain coefficients and reconstruct regions.
    /// Failure here preserves completed pixels; success invalidates their borrowed view.
    pub fn restart(self: *Job, options: composite.Options) Error!void {
        if (self.failure) |err| return err;
        if (!self.completed) return error.Busy;
        try self.renderer.?.restart(options);
        self.options = options;
        // An exact small layer may have discarded its coefficients. Promote it
        // only on the first reduced request; decode again in bounded steps, then
        // retain coefficients for subsequent grid changes. Release the old RGB
        // cache before decoding, after restart has successfully allocated output.
        if (self.preview_limit != null) for ([_]*?Pixmap{ &self.background, &self.foreground }, 0..) |cached, index| {
            if (self.regional[index] != null or cached.* == null) continue;
            const chunks = self.layers[index].wavelets.items;
            if (chunks.len != 0 and self.previewReduction(iw44.Header.parse(chunks[0]) catch unreachable) > 1) {
                if (index == 0) {
                    self.renderer.?.layers.background = null;
                    self.renderer.?.bg_color = .{ .solid = .{255} ** 3 };
                } else {
                    self.renderer.?.layers.foreground = null;
                    self.renderer.?.fg_color = .{ .solid = .{0} ** 3 };
                }
                cached.*.?.deinit(self.doc.allocator);
                cached.* = null;
                self.layer = @min(self.layer, index);
            }
        };
        self.configurePreview();
        self.completed = false;
    }

    pub fn step(self: *Job, work: usize) Error!Status {
        if (self.failure) |err| return err;
        if (work == 0) return error.InvalidArgument;
        return self.advance(work) catch |err| {
            self.failure = err;
            return err;
        };
    }

    fn advance(self: *Job, work: usize) Error!Status {
        if (self.completed) return .done;
        if (self.task < self.tasks.items.len) {
            const task = self.tasks.items[self.task];
            if (self.decoder == null) {
                const parent: ?*const jb2.Image = if (task.parent) |i| self.doc.components.items[i].dictionary else null;
                self.decoder = try jb2.Decoder.init(self.doc.allocator, task.data, parent, task.dictionary, self.doc.limits);
                // Placement follows the page's INFO version, never the shared
                // dictionary: the same symbols can serve old and new pages.
                self.decoder.?.legacy_placement = !task.dictionary and self.legacy_jb2;
            }
            if (try self.decoder.?.step(work)) {
                if (task.dictionary) {
                    const image = try self.doc.allocator.create(jb2.Image);
                    image.* = self.decoder.?.takeImage();
                    self.doc.cache.storeDictionary(self.doc.components.items, task.component, task.parent, image);
                    self.doc.dictionary_decodes += 1;
                } else {
                    self.image = self.decoder.?.takeImage();
                    if (self.image.?.width != self.info.width or self.image.?.height != self.info.height) return error.InvalidData;
                }
                self.decoder.?.deinit();
                self.decoder = null;
                self.task += 1;
            }
            return .progress;
        }
        if (self.mmr_data) |data| {
            if (self.bitmap == null) {
                if (self.mmr_decoder == null) {
                    self.mmr_decoder = try mmr.Decoder.init(self.doc.allocator, data, self.doc.limits);
                    const image = self.mmr_decoder.?.image;
                    if (image.width != self.info.width or image.height != self.info.height) return error.InvalidData;
                }
                if (try self.mmr_decoder.?.step(work)) {
                    self.bitmap = self.mmr_decoder.?.takeImage();
                    self.mmr_decoder.?.deinit();
                    self.mmr_decoder = null;
                }
                return .progress;
            }
        }
        if (self.palette_data) |data| {
            if (self.palette == null) {
                const blits: ?usize = if (self.image) |image| image.blits.items.len else null;
                self.palette = try color.Palette.parse(self.doc.allocator, data, blits, self.doc.limits);
                return .progress;
            }
        }
        if (self.layer < 2) {
            // Restart may promote just one color layer. Keep the other decoded
            // IW44/JPEG image, the rasterized mask and palette assignments.
            if (self.regional[self.layer] != null or (if (self.layer == 0) self.background != null else self.foreground != null)) {
                self.layer += 1;
                return .progress;
            }
            const layer = self.layers[self.layer];
            const chunks = layer.wavelets.items;
            if (layer.jpeg) |data| {
                if (self.jpeg_decoder == null) {
                    self.jpeg_decoder = try jpeg.Decoder.init(self.doc.allocator, data, self.doc.limits);
                    const info = self.jpeg_decoder.?.info;
                    _ = try color.reduction(self.info.width, self.info.height, info.width, info.height);
                }
                if (!try self.jpeg_decoder.?.step(work)) return .progress;
                const pixmap = self.jpeg_decoder.?.takeImage();
                if (self.layer == 0) self.background = pixmap else self.foreground = pixmap;
                self.jpeg_decoder.?.deinit();
                self.jpeg_decoder = null;
            } else if (chunks.len != 0) {
                if (self.wavelet == null) {
                    self.wavelet = try iw44.Decoder.init(self.doc.allocator, chunks, self.doc.limits);
                    const header = self.wavelet.?.header;
                    self.iw44_reductions[self.layer] = 1;
                    // Exact small layers keep their reusable RGB raster. Reduced
                    // requests retain coefficients at any encoded size; the area
                    // threshold only bounds full-resolution cache allocations.
                    self.wavelet.?.retain_coefficients = self.retain_preview_coefficients or self.previewReduction(header) > 1 or
                        @as(usize, header.width) * header.height > full_raster_pixels;
                }
                if (!try self.wavelet.?.step(work)) return .progress;
                if (self.wavelet.?.retain_coefficients) {
                    self.regional[self.layer] = self.wavelet;
                    if (self.renderer != null) self.configurePreview();
                } else {
                    const pixmap = self.wavelet.?.takeImage();
                    if (self.layer == 0) self.background = pixmap else self.foreground = pixmap;
                    self.wavelet.?.deinit();
                }
                self.wavelet = null;
            }
            self.layer += 1;
            return .progress;
        }
        if (self.renderer == null) {
            self.configurePreview();
            // FGbz colors are assigned to JB2 blits, never to MMR pixels/runs.
            // Without assignments, keep the ordinary black mask and its background.
            var mapped_palette: ?*const color.Palette = null;
            if (self.image != null) {
                if (self.palette) |*palette| {
                    if (palette.indices.len != 0) mapped_palette = palette;
                }
            }
            self.renderer = try composite.Renderer.init(self.doc.allocator, self.info, self.options, .{
                .mask = if (self.image) |*image|
                    .{ .symbols = image }
                else if (self.bitmap) |*image|
                    .{ .bitmap = image }
                else
                    null,
                .background = if (self.regional[0]) |*decoder| &decoder.image.? else if (self.background) |*image| image else null,
                .foreground = if (self.regional[1]) |*decoder| &decoder.image.? else if (self.foreground) |*image| image else null,
                .palette = mapped_palette,
            });
        }
        if (!try self.prepareLayers(work)) return .progress;
        if (try self.renderer.?.step(work)) {
            self.completed = true;
            return .done;
        }
        return .progress;
    }

    fn prepareLayers(self: *Job, work: usize) Error!bool {
        const renderer = &self.renderer.?;
        const source = renderer.needed orelse return true;
        // With source-row traversal, output_pixel is only a completed count.
        // Deriving a window from it would request the wrong strip after rotation.
        const window = if (renderer.rows == .color) source else renderer.transform.sampleRegion(
            self.info,
            self.options.size != null,
            @intCast(renderer.output_pixel % renderer.geometry.width),
            @intCast(renderer.output_pixel / renderer.geometry.width),
        );
        for (&self.regional, [_]u32{ renderer.bg_reduction, renderer.fg_reduction }, 0..) |*layer, reduction, index| {
            const decoder = if (layer.*) |*d| d else continue;
            if (decoder.phase != .done) {
                if (try decoder.step(work) and renderer.canClassifyLayer())
                    renderer.classifyLayer(index);
                return false;
            }
            const needed = composite.layerRegion(self.info, &decoder.image.?, reduction, source);
            if (decoder.image.?.contains(needed)) continue;
            const full = composite.layerRegion(self.info, &decoder.image.?, reduction, renderer.source_area);
            const sampling = composite.layerRegion(self.info, &decoder.image.?, reduction, window);
            const window_width = if (self.options.size != null)
                (self.info.width - 1) / renderer.transform.base_width + 2
            else
                self.options.subsample;
            const vertical = renderer.rows != .color and renderer.geometry.rotation & 1 != 0 and
                window_width / reduction <= raster_cache_pixels / full.height;
            try decoder.reconstructReduced(@max(1, self.iw44_reductions[index]), cacheRegion(full, needed, sampling, vertical));
            return false;
        }
        return true;
    }

    fn previewReduction(self: *const Job, header: iw44.Header) u32 {
        const limit = self.preview_limit orelse return 1;
        if (self.options.size == null) return 1;
        const transform = @import("geometry.zig").Transform.init(self.info, self.options) catch unreachable;
        const natural = color.reduction(self.info.width, self.info.height, header.width, header.height) catch unreachable;
        var r: u32 = 1;
        while (r < limit and @as(u64, transform.base_width) * natural * r * 2 <= self.info.width and
            @as(u64, transform.base_height) * natural * r * 2 <= self.info.height) r *= 2;
        return r;
    }

    fn configurePreview(self: *Job) void {
        if (self.preview_limit == null) return;
        for (&self.regional, 0..) |*layer, index| {
            const decoder = if (layer.*) |*d| d else continue;
            const header = decoder.header;
            const natural = color.reduction(self.info.width, self.info.height, header.width, header.height) catch unreachable;
            const r = self.previewReduction(header);
            const image = &decoder.image.?;
            if (self.iw44_reductions[index] != r) {
                // A raster from another grid cannot be reused. Coefficients and
                // buffer capacity survive; pixels are reconstructed on demand.
                image.width = (header.width + r - 1) / r;
                image.height = (header.height + r - 1) / r;
                image.region = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            }
            image.sample_step = if (r == 1) 0 else natural * r;
            self.iw44_reductions[index] = r;
            if (self.renderer) |*renderer| {
                if (index == 0) {
                    renderer.layers.background = image;
                    renderer.bg_reduction = natural * r;
                } else {
                    renderer.layers.foreground = image;
                    renderer.fg_reduction = natural * r;
                }
                renderer.classifyLayer(index);
                renderer.regional = true;
            }
        }
        if (self.renderer) |*renderer| renderer.reduced = composite.Renderer.hasReduced(renderer.layers);
    }
};

/// Cache strips follow the renderer's sampling direction, bounded to about two
/// million samples. The exact row plan uses horizontal strips for every rotation.
/// Their origins use the whole request's grid so reverse traversal also reuses
/// a strip. Include a sampling window across its far edge, so adjacent output
/// pixels never alternate between two strips at an area-filter boundary.
fn cacheRegion(full: composite.Region, needed: composite.Region, sampling: composite.Region, vertical: bool) composite.Region {
    const capacity = raster_cache_pixels;
    if (@as(usize, full.width) * full.height <= capacity) return full;
    var region = full;
    if (vertical) {
        const span = @max(1, capacity / full.height);
        const start = if (sampling.width <= span) sampling.x else needed.x;
        region.x = full.x + (start - full.x) / span * span;
        const overlap = if (sampling.width <= span) sampling.width else 0;
        const end = @max(@min(full.x + full.width, region.x + span + overlap), needed.x + needed.width);
        region.width = end - region.x;
    } else {
        const span = @max(1, capacity / full.width);
        const start = if (sampling.height <= span) sampling.y else needed.y;
        region.y = full.y + (start - full.y) / span * span;
        const overlap = if (sampling.height <= span) sampling.height else 0;
        const end = @max(@min(full.y + full.height, region.y + span + overlap), needed.y + needed.height);
        region.height = end - region.y;
    }
    return region;
}
