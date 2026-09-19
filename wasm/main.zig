//! One document and render job per instance. The host serializes exported calls.
const std = @import("std");
const heap = @import("heap.zig");
const djvu = @import("djvutang");

var budget: djvu.Budget = .{ .parent = heap.allocator, .limit = 0 };
var input: []u8 = &.{};
var document: ?djvu.Document = null;
var document_source: ?djvu.DocumentSource = null;
var source_request: djvu.ByteRange = undefined;
var job: ?djvu.RenderJob = null;
var job_thumbnail = false;
var page_text: ?djvu.PageText = null;
var annotation_json: ?[]u8 = null;
var outline_json: ?[]u8 = null;
var link_input: ?[]u8 = null;
const LinkResult = extern struct { kind: u32, page: u32 };
var link_result: LinkResult = undefined;
var status: u32 = 0;
var component_input: []u8 = &.{};
var component_target: ?u32 = null;

// Six pointer/length words, kind, declared FORM size, loaded, source range.
const ComponentResult = extern struct {
    id_ptr: u32,
    id_len: u32,
    name_ptr: u32,
    name_len: u32,
    title_ptr: u32,
    title_len: u32,
    kind: u32,
    size: u32,
    loaded: u32,
    offset: u32,
    length: u32,
};
var component_result: ComponentResult = undefined;

// Fixed little-endian ABI: eight u32 values followed by two affine f64[6] matrices.
const TransformResult = extern struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    page_width: u32,
    page_height: u32,
    rotation: u32,
    reserved: u32 = 0,
    matrix: [6]f64,
    inverse: [6]f64,
};
var transform_result: TransformResult = undefined;

comptime {
    std.debug.assert(@sizeOf(djvu.TextZone) == 36);
    std.debug.assert(@offsetOf(djvu.TextZone, "text_start") == 24);
    std.debug.assert(@sizeOf(TransformResult) == 128);
    std.debug.assert(@offsetOf(TransformResult, "matrix") == 32);
}

fn fail(err: djvu.Error) u32 {
    status = switch (err) {
        error.InvalidData => 2,
        error.Unsupported => 3,
        error.LimitExceeded => 4,
        error.Cancelled => 5,
        error.OutOfMemory => if (budget.denied) 4 else 6,
        error.InvalidArgument => 7,
        error.Busy => 8,
        error.MissingComponent => 9,
    };
    return status;
}

fn clearJob() void {
    if (job) |*j| j.deinit();
    job = null;
    job_thumbnail = false;
}

export fn close() void {
    clearJob();
    text_release();
    annotations_release();
    outline_release();
    link_release();
    component_abort();
    if (document) |*doc| doc.deinit();
    document = null;
    if (document_source) |*source| source.deinit();
    document_source = null;
    budget.allocator().free(input);
    input = &.{};
    std.debug.assert(budget.live == 0);
    status = 0;
}

export fn input_alloc(size: u32, limit: u32) u32 {
    close();
    budget = .{ .parent = heap.allocator, .limit = @min(limit, heap.max_memory) };
    if (size == 0 or size > 128 * 1024 * 1024) {
        _ = fail(error.LimitExceeded);
        return 0;
    }
    input = budget.allocator().alloc(u8, size) catch |err| {
        _ = fail(err);
        return 0;
    };
    return @intFromPtr(input.ptr);
}

export fn open() u32 {
    if (document != null or document_source != null or input.len == 0) return fail(error.InvalidArgument);
    budget.denied = false;
    document = djvu.Document.open(budget.allocator(), input, .{}) catch |err| return fail(err);
    status = 0;
    return 0;
}

/// Start range opening; bundled component headers are checked on supply.
export fn source_start(size: u32, limit: u32) u32 {
    close();
    budget = .{ .parent = heap.allocator, .limit = @min(limit, heap.max_memory) };
    document_source = djvu.DocumentSource.init(budget.allocator(), size, .{}) catch |err| return fail(err);
    return 0;
}

/// Pointer to offset/length u32 words, or zero when open has completed/on error.
export fn source_range() u32 {
    const source = if (document_source) |*s| s else {
        if (document == null) _ = fail(error.InvalidArgument) else status = 0;
        return 0;
    };
    const range = source.nextRange() catch |err| {
        _ = fail(err);
        return 0;
    };
    status = 0;
    source_request = range orelse return 0;
    return @intFromPtr(&source_request);
}

/// Allocate exactly the pending range, then fill it and call source_commit.
export fn source_alloc() u32 {
    if (source_range() == 0) {
        if (status == 0) _ = fail(error.InvalidArgument);
        return 0;
    }
    budget.allocator().free(input);
    input = &.{};
    budget.denied = false;
    input = budget.allocator().alloc(u8, source_request.length) catch |err| {
        _ = fail(err);
        return 0;
    };
    return @intFromPtr(input.ptr);
}

export fn source_commit() u32 {
    const source = if (document_source) |*s| s else return fail(error.InvalidArgument);
    if (input.len == 0) return fail(error.InvalidArgument);
    const bytes = input;
    input = &.{};
    defer budget.allocator().free(bytes);
    source.provide(bytes) catch |err| return fail(err);
    if ((source.nextRange() catch |err| return fail(err)) == null) {
        document = source.finish() catch |err| return fail(err);
        source.deinit();
        document_source = null;
    }
    status = 0;
    return 0;
}

export fn last_status() u32 {
    return status;
}

export fn page_count() u32 {
    return if (document) |*doc| @intCast(doc.pageCount()) else 0;
}

export fn document_indirect() u32 {
    return if (document) |doc| @intFromBool(doc.indirect) else 0;
}

export fn component_count() u32 {
    return if (document) |doc| @intCast(doc.components.items.len) else 0;
}

/// Directory index, or 0xffffffff on error (see last_status).
export fn page_component(page: u32) u32 {
    const doc = if (document) |*doc| doc else {
        _ = fail(error.InvalidArgument);
        return 0xffffffff;
    };
    const index = doc.pageComponent(page) catch |err| {
        _ = fail(err);
        return 0xffffffff;
    };
    status = 0;
    return @intCast(index);
}

export fn component_info(index: u32) u32 {
    const doc = if (document) |*doc| doc else {
        _ = fail(error.InvalidArgument);
        return 0;
    };
    if (index >= doc.components.items.len) {
        _ = fail(error.InvalidArgument);
        return 0;
    }
    const c = doc.components.items[index];
    component_result = .{
        .id_ptr = @intFromPtr(c.id.ptr),
        .id_len = @intCast(c.id.len),
        .name_ptr = @intFromPtr(c.name.ptr),
        .name_len = @intCast(c.name.len),
        .title_ptr = @intFromPtr(c.title.ptr),
        .title_len = @intCast(c.title.len),
        .kind = @intFromEnum(c.kind),
        .size = c.size,
        .loaded = @intFromBool(c.form != null),
        .offset = if (c.range) |r| r.offset else 0,
        .length = if (c.range) |r| r.length else 0,
    };
    status = 0;
    return @intFromPtr(&component_result);
}

/// Index + 1, or 0 when ready/on error; scope 0=page, 1=includes, 2=thumbnail.
export fn next_missing(page: u32, scope: u32) u32 {
    const doc = if (document) |*doc| doc else {
        _ = fail(error.InvalidArgument);
        return 0;
    };
    if (scope > 2) {
        _ = fail(error.InvalidArgument);
        return 0;
    }
    budget.denied = false;
    const missing = doc.nextMissing(page, @enumFromInt(scope)) catch |err| {
        _ = fail(err);
        return 0;
    };
    status = 0;
    return if (missing) |index| @intCast(index + 1) else 0;
}

export fn component_alloc(index: u32, size: u32) u32 {
    const doc = if (document) |*doc| doc else {
        _ = fail(error.InvalidArgument);
        return 0;
    };
    if (index >= doc.components.items.len or doc.components.items[index].form != null) {
        _ = fail(error.InvalidArgument);
        return 0;
    }
    component_abort();
    budget.denied = false;
    if (size == 0 or size > doc.limits.max_input_bytes - doc.bytes.len - doc.suppliedBytes()) {
        _ = fail(error.LimitExceeded);
        return 0;
    }
    component_input = budget.allocator().alloc(u8, size) catch |err| {
        _ = fail(err);
        return 0;
    };
    component_target = index;
    status = 0;
    return @intFromPtr(component_input.ptr);
}

export fn component_commit(index: u32) u32 {
    const doc = if (document) |*doc| doc else return fail(error.InvalidArgument);
    if (component_target != index) return fail(error.InvalidArgument);
    doc.provideComponent(index, component_input) catch |err| {
        component_abort();
        return fail(err);
    };
    component_input = &.{};
    component_target = null;
    status = 0;
    return 0;
}

export fn component_abort() void {
    budget.allocator().free(component_input);
    component_input = &.{};
    component_target = null;
}

export fn drop_components() u32 {
    const doc = if (document) |*doc| doc else return fail(error.InvalidArgument);
    clearJob();
    component_abort();
    doc.dropComponents() catch |err| return fail(err);
    status = 0;
    return 0;
}

/// Does not cancel the current Job or a pending component transfer.
export fn trim_cache(limit: u32) u32 {
    const doc = if (document) |*doc| doc else return fail(error.InvalidArgument);
    if (component_target != null) return fail(error.Busy);
    doc.trimCache(limit) catch |err| return fail(err);
    status = 0;
    return 0;
}

export fn cache_bytes() u32 {
    return if (document) |*doc| @intCast(doc.cacheBytes()) else 0;
}

fn info(page: u32) ?djvu.PageInfo {
    if (document) |*doc| {
        const result = doc.info(page) catch |err| {
            _ = fail(err);
            return null;
        };
        status = 0;
        return result;
    }
    _ = fail(error.InvalidArgument);
    return null;
}

export fn page_width(page: u32) u32 {
    return if (info(page)) |p| p.width else 0;
}

export fn page_height(page: u32) u32 {
    return if (info(page)) |p| p.height else 0;
}

export fn page_rotation(page: u32) u32 {
    return if (info(page)) |p| p.rotation else 0;
}

fn options(subsample: u32, rotation: u32) djvu.Error!djvu.RenderOptions {
    if (subsample == 0 or subsample > 256 or rotation > 3) return error.InvalidArgument;
    return .{ .subsample = @intCast(subsample), .rotation = @intCast(rotation) };
}

fn sizedOptions(
    width: u32,
    height: u32,
    rotation: u32,
    x: u32,
    y: u32,
    region_width: u32,
    region_height: u32,
) djvu.Error!djvu.RenderOptions {
    var opts = try options(1, rotation);
    if (width == 0 or height == 0) return error.InvalidArgument;
    opts.size = .{ .width = width, .height = height };
    if (x != 0 or y != 0 or region_width != 0 or region_height != 0)
        opts.region = .{ .x = x, .y = y, .width = region_width, .height = region_height };
    return opts;
}

/// Fit inside width/height; four zero region words mean the full fitted page.
/// Each IW44 layer uses 1/2/4 reconstruction selected by fitted output size,
/// preserving original masks. Region coordinates do not affect scale selection.
pub export fn render_start_sized(
    page: u32,
    width: u32,
    height: u32,
    rotation: u32,
    x: u32,
    y: u32,
    region_width: u32,
    region_height: u32,
) u32 {
    const opts = sizedOptions(width, height, rotation, x, y, region_width, region_height) catch |err| return fail(err);
    return start(page, opts);
}

export fn render_restart_sized(
    width: u32,
    height: u32,
    rotation: u32,
    x: u32,
    y: u32,
    region_width: u32,
    region_height: u32,
) u32 {
    const opts = sizedOptions(width, height, rotation, x, y, region_width, region_height) catch |err| return fail(err);
    return restart(opts);
}

export fn page_transform_sized(
    page: u32,
    width: u32,
    height: u32,
    rotation: u32,
    x: u32,
    y: u32,
    region_width: u32,
    region_height: u32,
) u32 {
    const opts = sizedOptions(width, height, rotation, x, y, region_width, region_height) catch |err| {
        _ = fail(err);
        return 0;
    };
    return transform(page, opts);
}

export fn render_start(page: u32, subsample: u32, rotation: u32) u32 {
    const opts = options(subsample, rotation) catch |err| return fail(err);
    return start(page, opts);
}

export fn render_start_region(
    page: u32,
    subsample: u32,
    rotation: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) u32 {
    var opts = options(subsample, rotation) catch |err| return fail(err);
    opts.region = .{ .x = x, .y = y, .width = width, .height = height };
    return start(page, opts);
}

fn start(page: u32, opts: djvu.RenderOptions) u32 {
    const doc = if (document) |*doc| doc else return fail(error.InvalidArgument);
    clearJob();
    budget.denied = false;
    job = djvu.RenderJob.init(doc, page, opts) catch |err| return fail(err);
    status = 1;
    return 0;
}

// Internal access for the test probe; no WebAssembly export.
pub fn probeJob() ?*djvu.RenderJob {
    return if (job) |*j| j else null;
}

/// Uses the same render_step/result_*/render_cancel lifecycle as a page job.
/// A successful start with thumbnail_present()==0 means there is no thumbnail.
export fn thumbnail_start(page: u32) u32 {
    const doc = if (document) |*doc| doc else return fail(error.InvalidArgument);
    clearJob();
    budget.denied = false;
    job = djvu.RenderJob.initThumbnail(doc, page) catch |err| return fail(err);
    job_thumbnail = job != null;
    status = if (job_thumbnail) 1 else 0;
    return 0;
}

export fn thumbnail_present() u32 {
    return @intFromBool(job_thumbnail);
}

export fn render_step(work: u32) u32 {
    const j = if (job) |*j| j else return fail(error.InvalidArgument);
    budget.denied = false;
    const result = j.step(@min(work, 65536)) catch |err| return fail(err);
    status = if (result == .done) 0 else 1;
    return status;
}

export fn render_cancel() void {
    if (job) |*j| j.cancel();
    clearJob();
    status = 5;
}

export fn render_restart(subsample: u32, rotation: u32) u32 {
    const opts = options(subsample, rotation) catch |err| return fail(err);
    return restart(opts);
}

export fn render_restart_region(
    subsample: u32,
    rotation: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) u32 {
    var opts = options(subsample, rotation) catch |err| return fail(err);
    opts.region = .{ .x = x, .y = y, .width = width, .height = height };
    return restart(opts);
}

fn restart(opts: djvu.RenderOptions) u32 {
    const j = if (job) |*j| j else return fail(error.InvalidArgument);
    budget.denied = false;
    j.restart(opts) catch |err| return fail(err);
    status = 1;
    return 0;
}

fn pageGeometry(page: u32, subsample: u32, rotation: u32) ?djvu.RenderGeometry {
    const opts = options(subsample, rotation) catch |err| {
        _ = fail(err);
        return null;
    };
    const doc = if (document) |*doc| doc else {
        _ = fail(error.InvalidArgument);
        return null;
    };
    const result = doc.geometry(page, opts) catch |err| {
        _ = fail(err);
        return null;
    };
    status = 0;
    return result;
}

export fn render_width(page: u32, subsample: u32, rotation: u32) u32 {
    return if (pageGeometry(page, subsample, rotation)) |g| g.width else 0;
}

export fn render_height(page: u32, subsample: u32, rotation: u32) u32 {
    return if (pageGeometry(page, subsample, rotation)) |g| g.height else 0;
}

export fn page_transform(page: u32, subsample: u32, rotation: u32) u32 {
    const opts = options(subsample, rotation) catch |err| {
        _ = fail(err);
        return 0;
    };
    return transform(page, opts);
}

export fn page_transform_region(
    page: u32,
    subsample: u32,
    rotation: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) u32 {
    var opts = options(subsample, rotation) catch |err| {
        _ = fail(err);
        return 0;
    };
    opts.region = .{ .x = x, .y = y, .width = width, .height = height };
    return transform(page, opts);
}

fn transform(page: u32, opts: djvu.RenderOptions) u32 {
    const doc = if (document) |*doc| doc else {
        _ = fail(error.InvalidArgument);
        return 0;
    };
    const t = doc.transform(page, opts) catch |err| {
        _ = fail(err);
        return 0;
    };
    const g = t.geometry;
    transform_result = .{
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
    status = 0;
    return @intFromPtr(&transform_result);
}

/// Synchronous, bounded text snapshot. Does not cancel or replace an image job.
export fn text_load(page: u32) u32 {
    const doc = if (document) |*doc| doc else return fail(error.InvalidArgument);
    text_release();
    budget.denied = false;
    page_text = doc.text(page) catch |err| return fail(err);
    status = 0;
    return 0;
}

export fn text_present() u32 {
    return @intFromBool(page_text != null);
}

export fn text_ptr() u32 {
    return if (page_text) |t| @intFromPtr(t.bytes.ptr) else 0;
}

export fn text_len() u32 {
    return if (page_text) |t| @intCast(t.bytes.len) else 0;
}

export fn text_has_replacements() u32 {
    return if (page_text) |t| @intFromBool(t.has_replacements) else 0;
}

export fn text_zones_ptr() u32 {
    return if (page_text) |t| (if (t.zones.len == 0) 0 else @intFromPtr(t.zones.ptr)) else 0;
}

export fn text_zones_count() u32 {
    return if (page_text) |t| @intCast(t.zones.len) else 0;
}

export fn text_release() void {
    if (page_text) |*t| t.deinit(budget.allocator());
    page_text = null;
}

/// UTF-8 JSON snapshot using the same serialization as the native API and CLI.
export fn annotations_load(page: u32) u32 {
    const doc = if (document) |*doc| doc else return fail(error.InvalidArgument);
    annotations_release();
    budget.denied = false;
    if (doc.annotations(page) catch |err| return fail(err)) |value| {
        var data = value;
        defer data.deinit();
        annotation_json = std.json.Stringify.valueAlloc(budget.allocator(), &data, .{}) catch |err| return fail(err);
    }
    status = 0;
    return 0;
}

export fn annotations_present() u32 {
    return @intFromBool(annotation_json != null);
}

export fn annotations_ptr() u32 {
    return if (annotation_json) |data| @intFromPtr(data.ptr) else 0;
}

export fn annotations_len() u32 {
    return if (annotation_json) |data| @intCast(data.len) else 0;
}

export fn annotations_release() void {
    if (annotation_json) |data| budget.allocator().free(data);
    annotation_json = null;
}

export fn outline_load() u32 {
    const doc = if (document) |*doc| doc else return fail(error.InvalidArgument);
    outline_release();
    budget.denied = false;
    if (doc.outline() catch |err| return fail(err)) |value| {
        var data = value;
        defer data.deinit(budget.allocator());
        outline_json = std.json.Stringify.valueAlloc(budget.allocator(), &data, .{}) catch |err| return fail(err);
    }
    status = 0;
    return 0;
}

export fn outline_present() u32 {
    return @intFromBool(outline_json != null);
}

export fn outline_ptr() u32 {
    return if (outline_json) |data| @intFromPtr(data.ptr) else 0;
}

export fn outline_len() u32 {
    return if (outline_json) |data| @intCast(data.len) else 0;
}

export fn outline_release() void {
    if (outline_json) |data| budget.allocator().free(data);
    outline_json = null;
}

/// One extra byte provides a valid writable pointer even for an empty href.
export fn link_alloc(size: u32) u32 {
    link_release();
    const doc = if (document) |*doc| doc else {
        _ = fail(error.InvalidArgument);
        return 0;
    };
    if (size > doc.limits.max_input_bytes) {
        _ = fail(error.LimitExceeded);
        return 0;
    }
    budget.denied = false;
    link_input = budget.allocator().alloc(u8, @as(usize, size) + 1) catch |err| {
        _ = fail(err);
        return 0;
    };
    status = 0;
    return @intFromPtr(link_input.?.ptr);
}

/// from_page == 0xffffffff means no origin. Result: kind, page (or 0xffffffff).
export fn link_resolve(from_page: u32) u32 {
    const doc = if (document) |*doc| doc else {
        _ = fail(error.InvalidArgument);
        return 0;
    };
    const bytes = link_input orelse {
        _ = fail(error.InvalidArgument);
        return 0;
    };
    const result = doc.resolveLink(bytes[0 .. bytes.len - 1], if (from_page == 0xffffffff) null else from_page) catch |err| {
        _ = fail(err);
        return 0;
    };
    link_result = .{ .kind = @intFromEnum(result.kind), .page = result.page orelse 0xffffffff };
    status = 0;
    return @intFromPtr(&link_result);
}

export fn link_release() void {
    if (link_input) |bytes| budget.allocator().free(bytes);
    link_input = null;
}

export fn result_ptr() u32 {
    const j = if (job) |*j| j else return 0;
    const pixels = j.pixels() catch return 0;
    return @intFromPtr(pixels.ptr);
}

export fn result_len() u32 {
    const j = if (job) |*j| j else return 0;
    return @intCast((j.pixels() catch return 0).len);
}

export fn result_width() u32 {
    const j = if (job) |*j| j else return 0;
    return (j.geometry() catch return 0).width;
}

export fn result_height() u32 {
    const j = if (job) |*j| j else return 0;
    return (j.geometry() catch return 0).height;
}

export fn result_x() u32 {
    const j = if (job) |*j| j else return 0;
    return (j.geometry() catch return 0).x;
}

export fn result_y() u32 {
    const j = if (job) |*j| j else return 0;
    return (j.geometry() catch return 0).y;
}

export fn result_page_width() u32 {
    const j = if (job) |*j| j else return 0;
    return (j.geometry() catch return 0).page_width;
}

export fn result_page_height() u32 {
    const j = if (job) |*j| j else return 0;
    return (j.geometry() catch return 0).page_height;
}

export fn drop_dictionaries() u32 {
    const doc = if (document) |*doc| doc else return fail(error.InvalidArgument);
    clearJob();
    doc.dropDictionaries() catch |err| return fail(err);
    status = 0;
    return 0;
}

export fn live_bytes() u32 {
    return @intCast(budget.live);
}

export fn peak_bytes() u32 {
    return @intCast(budget.peak);
}

export fn dictionary_decodes() u32 {
    return if (document) |*doc| @intCast(doc.dictionary_decodes) else 0;
}
