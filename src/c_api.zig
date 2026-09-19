const std = @import("std");
const djvu = @import("djvutang");
const allocator = std.heap.c_allocator;

const Status = enum(i32) {
    ok = 0,
    progress = 1,
    invalid_data = 2,
    unsupported = 3,
    limit_exceeded = 4,
    cancelled = 5,
    out_of_memory = 6,
    invalid_argument = 7,
    busy = 8,
    missing_component = 9,
};

const Document = struct {
    budget: djvu.Budget,
    value: djvu.Document,

    fn fail(self: *const Document, err: djvu.Error) Status {
        return switch (err) {
            error.InvalidData => .invalid_data,
            error.Unsupported => .unsupported,
            error.LimitExceeded => .limit_exceeded,
            error.Cancelled => .cancelled,
            error.OutOfMemory => if (self.budget.denied != null) .limit_exceeded else .out_of_memory,
            error.InvalidArgument => .invalid_argument,
            error.Busy => .busy,
            error.MissingComponent => .missing_component,
        };
    }
};
const Job = struct {
    owner: *Document,
    value: djvu.RenderJob,
    // Keep the translated allocation error after another call resets denied.
    failure: ?Status = null,
};
const MetadataScan = struct {
    owner: *Document,
    value: djvu.MetadataScan,
    failure: ?Status = null,

    fn fail(self: *MetadataScan, err: djvu.Error) Status {
        const status = self.owner.fail(err);
        self.failure = status;
        return status;
    }
};
const PageInfo = extern struct { width: u32, height: u32, dpi: u32, rotation: u32 };
const Region = extern struct { x: u32, y: u32, width: u32, height: u32 };
const Options = extern struct {
    subsample: u32,
    rotation: u32,
    width: u32,
    height: u32,
    region: Region,

    fn decode(raw: ?*const Options) djvu.Error!djvu.RenderOptions {
        const o = raw orelse return .{};
        if (o.subsample > 256 or o.rotation > 3) return error.InvalidArgument;
        var result: djvu.RenderOptions = .{
            .subsample = @intCast(@max(1, o.subsample)),
            .rotation = @intCast(o.rotation),
        };
        if (o.width != 0 or o.height != 0) {
            if (o.width == 0 or o.height == 0 or o.subsample > 1) return error.InvalidArgument;
            result.size = .{ .width = o.width, .height = o.height };
        }
        const r = o.region;
        if (r.x != 0 or r.y != 0 or r.width != 0 or r.height != 0)
            result.region = .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
        return result;
    }
};
const Geometry = extern struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    page_width: u32,
    page_height: u32,
    rotation: u32,
    matrix: [6]f64,
    inverse: [6]f64,
};
const Image = extern struct { rgba: [*]const u8, size: usize, stride: usize, width: u32, height: u32 };
const Memory = extern struct { live_bytes: usize, peak_bytes: usize, cache_bytes: usize };
const Component = extern struct { index: u32, id: ?[*]const u8, id_size: usize, name: ?[*]const u8, name_size: usize };
const Buffer = extern struct {
    data: ?[*]const u8 = null,
    size: usize = 0,

    fn owned(bytes: []u8) Buffer {
        // A present empty value must remain distinct from absent metadata.
        return .{ .data = if (bytes.len == 0) "" else bytes.ptr, .size = bytes.len };
    }
};

export fn djvutang_open(data: ?[*]const u8, size: usize, memory_limit: usize, out: ?*?*Document) Status {
    const result = out orelse return .invalid_argument;
    result.* = null;
    const bytes = data orelse return .invalid_argument;
    const doc = allocator.create(Document) catch return .out_of_memory;
    // The budget and document must reach their final address before any decoder
    // allocations: allocator contexts and jobs retain pointers into this handle.
    doc.budget = .{ .parent = allocator, .limit = if (memory_limit == 0) 64 * 1024 * 1024 else memory_limit };
    doc.value = djvu.Document.open(doc.budget.allocator(), bytes[0..size], .{}) catch |err| {
        const status = doc.fail(err);
        allocator.destroy(doc);
        return status;
    };
    result.* = doc;
    return .ok;
}

export fn djvutang_close(document: ?*Document) Status {
    const doc = document orelse return .ok;
    if (doc.value.busy or doc.value.metadata_busy) return .busy;
    doc.value.deinit();
    std.debug.assert(doc.budget.live == 0);
    allocator.destroy(doc);
    return .ok;
}

export fn djvutang_page_count(document: ?*const Document) u32 {
    return if (document) |doc| @intCast(doc.value.pageCount()) else 0;
}

export fn djvutang_get_page_info(document: ?*Document, page: u32, out: ?*PageInfo) Status {
    const doc = document orelse return .invalid_argument;
    const result = out orelse return .invalid_argument;
    const info = doc.value.info(page) catch |err| return doc.fail(err);
    result.* = .{ .width = info.width, .height = info.height, .dpi = info.dpi, .rotation = info.rotation };
    return .ok;
}

export fn djvutang_get_geometry(document: ?*Document, page: u32, options: ?*const Options, out: ?*Geometry) Status {
    const doc = document orelse return .invalid_argument;
    const result = out orelse return .invalid_argument;
    const opts = Options.decode(options) catch |err| return doc.fail(err);
    const t = doc.value.transform(page, opts) catch |err| return doc.fail(err);
    const g = t.geometry;
    result.* = .{
        .x = g.x,
        .y = g.y,
        .width = g.width,
        .height = g.height,
        .page_width = g.page_width,
        .page_height = g.page_height,
        .rotation = g.rotation,
        .matrix = t.matrix,
        .inverse = t.inverse,
    };
    return .ok;
}

export fn djvutang_get_memory(document: ?*const Document, out: ?*Memory) Status {
    const doc = document orelse return .invalid_argument;
    const result = out orelse return .invalid_argument;
    result.* = .{ .live_bytes = doc.budget.live, .peak_bytes = doc.budget.peak, .cache_bytes = doc.value.cacheBytes() };
    return .ok;
}

export fn djvutang_trim_cache(document: ?*Document, limit: usize) Status {
    const doc = document orelse return .invalid_argument;
    doc.value.trimCache(limit) catch |err| return doc.fail(err);
    return .ok;
}

export fn djvutang_render_start(document: ?*Document, page: u32, options: ?*const Options, out: ?*?*Job) Status {
    const result = out orelse return .invalid_argument;
    result.* = null;
    const doc = document orelse return .invalid_argument;
    const opts = Options.decode(options) catch |err| return doc.fail(err);
    if (doc.value.busy) return .busy;
    doc.budget.denied = null;
    const job = doc.budget.allocator().create(Job) catch |err| return doc.fail(err);
    job.* = .{ .owner = doc, .value = djvu.RenderJob.init(&doc.value, page, opts) catch |err| {
        doc.budget.allocator().destroy(job);
        return doc.fail(err);
    } };
    result.* = job;
    return .ok;
}

export fn djvutang_thumbnail_start(document: ?*Document, page: u32, out: ?*?*Job) Status {
    const result = out orelse return .invalid_argument;
    result.* = null;
    const doc = document orelse return .invalid_argument;
    doc.budget.denied = null;
    var value = (djvu.RenderJob.initThumbnail(&doc.value, page) catch |err| return doc.fail(err)) orelse return .ok;
    const job = doc.budget.allocator().create(Job) catch |err| {
        value.deinit();
        return doc.fail(err);
    };
    job.* = .{ .owner = doc, .value = value };
    result.* = job;
    return .ok;
}

export fn djvutang_render_step(handle: ?*Job, work: u32) Status {
    const job = handle orelse return .invalid_argument;
    if (job.failure) |status| return status;
    job.owner.budget.denied = null;
    const result = job.value.step(work) catch |err| {
        const status = job.owner.fail(err);
        if (job.value.failure != null) job.failure = status;
        return status;
    };
    return if (result == .done) .ok else .progress;
}

export fn djvutang_render_restart(handle: ?*Job, options: ?*const Options) Status {
    const job = handle orelse return .invalid_argument;
    if (job.failure) |status| return status;
    const opts = Options.decode(options) catch |err| return job.owner.fail(err);
    job.owner.budget.denied = null;
    job.value.restart(opts) catch |err| return job.owner.fail(err);
    return .ok;
}

export fn djvutang_render_image(handle: ?*const Job, out: ?*Image) Status {
    const job = handle orelse return .invalid_argument;
    const result = out orelse return .invalid_argument;
    if (job.failure) |status| return status;
    const bytes = job.value.pixels() catch |err| return job.owner.fail(err);
    const g = job.value.geometry() catch |err| return job.owner.fail(err);
    result.* = .{ .rgba = bytes.ptr, .size = bytes.len, .stride = @as(usize, g.width) * 4, .width = g.width, .height = g.height };
    return .ok;
}

export fn djvutang_render_cancel(handle: ?*Job) void {
    if (handle) |job| job.value.cancel();
}

export fn djvutang_render_destroy(handle: ?*Job) void {
    const job = handle orelse return;
    const a = job.owner.budget.allocator();
    job.value.deinit();
    a.destroy(job);
}

export fn djvutang_next_missing(document: ?*Document, page: u32, scope: u32, out: ?*Component) Status {
    const doc = document orelse return .invalid_argument;
    const result = out orelse return .invalid_argument;
    if (scope > 2) return .invalid_argument;
    doc.budget.denied = null;
    const missing = doc.value.nextMissing(page, @enumFromInt(scope)) catch |err| return doc.fail(err);
    result.* = .{ .index = std.math.maxInt(u32), .id = null, .id_size = 0, .name = null, .name_size = 0 };
    if (missing) |index| {
        const c = doc.value.components.items[index];
        result.* = .{ .index = @intCast(index), .id = c.id.ptr, .id_size = c.id.len, .name = c.name.ptr, .name_size = c.name.len };
    }
    return .ok;
}

export fn djvutang_provide_component(document: ?*Document, index: u32, data: ?[*]const u8, size: usize) Status {
    const doc = document orelse return .invalid_argument;
    const bytes = data orelse return .invalid_argument;
    if (index >= doc.value.components.items.len or doc.value.components.items[index].form != null) return .invalid_argument;
    if (size > doc.value.limits.max_input_bytes - doc.value.bytes.len - doc.value.suppliedBytes()) return .limit_exceeded;
    doc.budget.denied = null;
    const owned = doc.budget.allocator().dupe(u8, bytes[0..size]) catch |err| return doc.fail(err);
    doc.value.provideComponent(index, owned) catch |err| {
        doc.budget.allocator().free(owned);
        return doc.fail(err);
    };
    return .ok;
}

export fn djvutang_get_component(document: ?*const Document, index: u32, out: ?*Component) Status {
    const doc = document orelse return .invalid_argument;
    const result = out orelse return .invalid_argument;
    if (index >= doc.value.components.items.len) return .invalid_argument;
    const c = doc.value.components.items[index];
    result.* = .{ .index = index, .id = c.id.ptr, .id_size = c.id.len, .name = c.name.ptr, .name_size = c.name.len };
    return .ok;
}

export fn djvutang_metadata_start(document: ?*Document, out: ?*?*MetadataScan) Status {
    const result = out orelse return .invalid_argument;
    result.* = null;
    const doc = document orelse return .invalid_argument;
    doc.budget.denied = null;
    const scan = doc.budget.allocator().create(MetadataScan) catch |err| return doc.fail(err);
    scan.* = .{ .owner = doc, .value = djvu.MetadataScan.init(&doc.value) catch |err| {
        doc.budget.allocator().destroy(scan);
        return doc.fail(err);
    } };
    result.* = scan;
    return .ok;
}

export fn djvutang_metadata_step(handle: ?*MetadataScan, work: u32) Status {
    const scan = handle orelse return .invalid_argument;
    if (scan.failure) |failure| return failure;
    scan.owner.budget.denied = null;
    const state = scan.value.step(work) catch |err| return scan.fail(err);
    return if (state == .done) .ok else .progress;
}

export fn djvutang_metadata_range(handle: ?*MetadataScan, out: ?*djvu.MetadataRequest) Status {
    const scan = handle orelse return .invalid_argument;
    const result = out orelse return .invalid_argument;
    result.* = .{ .component = std.math.maxInt(u32), .offset = 0, .length = 0 };
    if (scan.failure) |failure| return failure;
    result.* = (scan.value.nextRange() catch |err| return scan.fail(err)) orelse return .ok;
    return .ok;
}

export fn djvutang_metadata_provide(handle: ?*MetadataScan, data: ?[*]const u8, size: usize, source_size: u32) Status {
    const scan = handle orelse return .invalid_argument;
    const bytes = data orelse return .invalid_argument;
    if (scan.failure) |failure| return failure;
    scan.owner.budget.denied = null;
    scan.value.provide(bytes[0..size], source_size) catch |err| return scan.fail(err);
    return .ok;
}

export fn djvutang_metadata_json(handle: ?*MetadataScan, out: ?*Buffer) Status {
    const result = out orelse return .invalid_argument;
    result.* = .{};
    const scan = handle orelse return .invalid_argument;
    if (scan.failure) |failure| return failure;
    scan.owner.budget.denied = null;
    var value = scan.value.takeResult() catch |err| return scan.fail(err);
    defer value.deinit();
    const a = scan.owner.budget.allocator();
    const json = std.json.Stringify.valueAlloc(a, &value, .{}) catch |err| return scan.fail(err);
    defer a.free(json);
    result.* = Buffer.owned(allocator.dupe(u8, json) catch |err| return scan.fail(err));
    return .ok;
}

export fn djvutang_metadata_cancel(handle: ?*MetadataScan) void {
    if (handle) |scan| scan.value.cancel();
}

export fn djvutang_metadata_destroy(handle: ?*MetadataScan) void {
    const scan = handle orelse return;
    const a = scan.owner.budget.allocator();
    scan.value.deinit();
    a.destroy(scan);
}

export fn djvutang_text(document: ?*Document, page: u32, out: ?*Buffer) Status {
    const result = out orelse return .invalid_argument;
    result.* = .{};
    const doc = document orelse return .invalid_argument;
    doc.budget.denied = null;
    var value = (doc.value.text(page) catch |err| return doc.fail(err)) orelse return .ok;
    defer value.deinit(doc.budget.allocator());
    result.* = Buffer.owned(value.toUtf8(allocator) catch |err| return doc.fail(err));
    return .ok;
}

export fn djvutang_annotations_json(document: ?*Document, page: u32, out: ?*Buffer) Status {
    const result = out orelse return .invalid_argument;
    result.* = .{};
    const doc = document orelse return .invalid_argument;
    doc.budget.denied = null;
    var value = (doc.value.annotations(page) catch |err| return doc.fail(err)) orelse return .ok;
    defer value.deinit();
    result.* = Buffer.owned(std.json.Stringify.valueAlloc(allocator, &value, .{}) catch |err| return doc.fail(err));
    return .ok;
}

export fn djvutang_outline_json(document: ?*Document, out: ?*Buffer) Status {
    const result = out orelse return .invalid_argument;
    result.* = .{};
    const doc = document orelse return .invalid_argument;
    doc.budget.denied = null;
    var value = (doc.value.outline() catch |err| return doc.fail(err)) orelse return .ok;
    defer value.deinit(doc.budget.allocator());
    result.* = Buffer.owned(std.json.Stringify.valueAlloc(allocator, &value, .{}) catch |err| return doc.fail(err));
    return .ok;
}

export fn djvutang_buffer_free(buffer: ?*Buffer) void {
    const value = buffer orelse return;
    if (value.data) |data| allocator.free(data[0..value.size]);
    value.* = .{};
}
