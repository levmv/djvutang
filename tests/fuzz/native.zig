//! Optional coverage-guided tests, run through the guarded `make fuzz` target.
//! Inputs are mutation recipes over our own fixtures, not foreign documents.
const std = @import("std");
const iff = @import("../../src/iff.zig");
const Document = @import("../../src/document.zig").Document;
const MetadataScan = @import("../../src/metadata.zig").Scan;
const Job = @import("../../src/job.zig").Job;
const Budget = @import("../../src/budget.zig").Budget;
const Limits = @import("../../src/types.zig").Limits;
const Smith = std.testing.Smith;
const a = std.testing.allocator;

const limits: Limits = .{
    .max_input_bytes = 128 * 1024,
    .max_bzz_bytes = 64 * 1024,
    .max_page_pixels = 256 * 1024,
    .max_shape_pixels = 64 * 1024,
    .max_shapes = 1024,
    .max_blits = 4096,
    .max_cells = 65536,
    .max_records = 8192,
    .max_components = 128,
    .max_chunks = 1024,
    .max_include_depth = 8,
    .max_iw_slices = 128,
    .max_jpeg_scans = 32,
    .max_jpeg_blocks = 256 * 1024,
    .max_text_bytes = 64 * 1024,
    .max_text_zones = 2048,
    .max_text_depth = 16,
    .max_annotation_bytes = 64 * 1024,
    .max_annotation_nodes = 2048,
    .max_annotation_depth = 16,
    .max_outline_bytes = 64 * 1024,
    .max_outline_entries = 2048,
    .max_outline_depth = 16,
};

const samples = blk: {
    var result: []const []const u8 = &.{};
    for (.{
        "plain.djvu",                        "shared.djvu",            "shared-layers.djvu",
        "dictionary-aliases.djvu",           "include-cycle.djvu",     "color.djvu",
        "progressive.djvu",                  "foreground.djvu",        "palette.djvu",
        "iw44-empty-parts.djvu",             "iw44-filter-range.djvu", "mmr-striped.djvu",
        "mmr-uncompressed.djvu",             "mmr-foreground.djvu",    "jpeg-baseline.djvu",
        "jpeg-progressive-restart.djvu",     "jpeg-sequential.djvu",   "jpeg-cmyk.djvu",
        "jpeg-header-junk.djvu",             "text-a.djvu",            "text-z.djvu",
        "text-recovered-z.djvu",             "annotations-a.djvu",     "annotations-z.djvu",
        "annotations-shared.djvu",           "outline.djvu",           "thumbnails.djvu",
        "thumbnail-inline-progressive.djvu", "thumbnails.thum",        "pm44-progressive.iw4",
        "metadata-book.djvu",                "metadata-context.djvu",  "metadata-none.djvu",
    }) |name| result = result ++ .{@as([]const u8, @embedFile("../fixtures/" ++ name))};
    break :blk result;
};

fn pick(s: *Smith, n: usize) usize {
    return s.valueRangeLessThan(u32, 0, @intCast(n));
}

const Range = struct { start: usize, len: usize };
fn payloads(form: iff.Chunk, ranges: *[128]Range, count: *usize, depth: usize) void {
    if (depth > 3) return;
    var chunks = form.children() catch return;
    while (chunks.next() catch return) |chunk| {
        if (iff.tag(chunk.id, "FORM")) {
            payloads(chunk, ranges, count, depth + 1);
        } else if (chunk.data.len != 0 and count.* < ranges.len) {
            ranges[count.*] = .{ .start = chunk.offset + 8, .len = chunk.data.len };
            count.* += 1;
        }
    }
}

fn mutate(s: *Smith, source: []const u8, buffer: []u8) []const u8 {
    std.debug.assert(source.len <= buffer.len);
    @memcpy(buffer[0..source.len], source);
    var range: Range = .{ .start = 0, .len = source.len };
    // Most mutations preserve IFF boundaries to reach the codecs. The remaining
    // cases exercise arbitrary headers, short files and exact unmodified seeds.
    const mode = s.value(u3);
    if (mode == 0) return buffer[0..source.len];
    if (mode == 1) return buffer[0..pick(s, source.len + 1)];
    if (mode >= 3) {
        var ranges: [128]Range = undefined;
        var count: usize = 0;
        if (iff.root(source)) |form| payloads(form, &ranges, &count, 0) else |_| {}
        if (count != 0) range = ranges[pick(s, count)];
    }
    if (range.len != 0) for (0..1 + pick(s, 8)) |_| {
        const offset = range.start + pick(s, range.len);
        buffer[offset] = s.value(u8);
    };
    return buffer[0..source.len];
}

fn metadata(doc: *Document, page: usize) void {
    if (doc.text(page) catch null) |value| {
        var text = value;
        defer text.deinit(doc.allocator);
        if (text.toUtf8(doc.allocator)) |bytes| doc.allocator.free(bytes) else |_| {}
        if (text.zones.len != 0) {
            if (text.zoneText(doc.allocator, text.zones.len - 1)) |bytes| doc.allocator.free(bytes) else |_| {}
        }
    }
    if (doc.annotations(page) catch null) |value| {
        var annotations = value;
        defer annotations.deinit();
        if (std.json.Stringify.valueAlloc(doc.allocator, annotations, .{})) |bytes| doc.allocator.free(bytes) else |_| {}
    }
    if (doc.outline() catch null) |value| {
        var outline = value;
        defer outline.deinit(doc.allocator);
        if (std.json.Stringify.valueAlloc(doc.allocator, outline, .{})) |bytes| doc.allocator.free(bytes) else |_| {}
    }
    _ = doc.resolveLink("#+1", page) catch {};
    var scan = MetadataScan.init(doc) catch return;
    defer scan.deinit();
    if ((scan.step(4096) catch return) == .done) {
        var value = scan.takeResult() catch return;
        defer value.deinit();
        if (std.json.Stringify.valueAlloc(doc.allocator, &value, .{})) |bytes| doc.allocator.free(bytes) else |_| {}
    }
}

fn drive(job: *Job, s: *Smith) !void {
    for (0..1 + pick(s, 32)) |_| {
        const result = job.step(if (s.value(bool)) 1 else 4096) catch break;
        if (result == .done) {
            const geometry = try job.geometry();
            try std.testing.expectEqual(@as(usize, geometry.width) * geometry.height * 4, (try job.pixels()).len);
            break;
        }
        try std.testing.expectError(error.Busy, job.pixels());
    }
}

fn exercise(doc: *Document, s: *Smith) !void {
    var job: ?Job = null;
    defer if (job) |*j| j.deinit();
    for (0..1 + pick(s, 16)) |_| {
        const page = pick(s, @min(doc.pageCount(), 4) + 1);
        switch (s.value(enum { render, thumbnail, step, cancel, restart, metadata, evict, geometry })) {
            .render, .thumbnail => |action| {
                if (job) |*j| j.deinit();
                job = null;
                job = if (action == .thumbnail)
                    Job.initThumbnail(doc, page) catch null
                else
                    Job.init(doc, page, .{ .subsample = @intCast(1 + pick(s, 4)), .rotation = s.value(u2) }) catch null;
                if (job) |*j| try drive(j, s);
            },
            .step => if (job) |*j| {
                try drive(j, s);
            },
            .cancel => if (job) |*j| {
                j.cancel();
            },
            .restart => if (job) |*j| {
                j.restart(.{ .subsample = @intCast(1 + pick(s, 4)), .rotation = s.value(u2) }) catch continue;
                try drive(j, s);
            },
            .metadata => metadata(doc, page),
            .evict => {
                if (job != null) {
                    try std.testing.expectError(error.Busy, doc.dropComponents());
                } else try doc.dropComponents();
            },
            .geometry => {
                _ = doc.geometry(page, .{}) catch {};
            },
        }
        try std.testing.expectEqual(job != null, doc.busy);
    }
}

fn documentMutation(_: void, s: *Smith) !void {
    var buffer: [32768]u8 = undefined;
    const bytes = mutate(s, samples[pick(s, samples.len)], &buffer);
    var budget: Budget = .{ .parent = a, .limit = if (s.value(bool)) 128 * 1024 else 8 * 1024 * 1024 };
    defer std.debug.assert(budget.live == 0);
    var doc = Document.open(budget.allocator(), bytes, limits) catch return;
    defer doc.deinit();
    metadata(&doc, 0);
    try exercise(&doc, s);
}

const Resource = struct { name: []const u8, bytes: []const u8 };
fn resources(comptime folder: []const u8, comptime names: anytype) []const Resource {
    comptime var result: []const Resource = &.{};
    inline for (names) |name| {
        result = result ++ .{Resource{
            .name = name,
            .bytes = @embedFile("../fixtures/" ++ folder ++ "/" ++ name),
        }};
    }
    return result;
}
const indirect = .{
    .{
        .bytes = @embedFile("../fixtures/indirect-layers/index.djvu"),
        .files = resources("indirect-layers", .{
            "sheet a.djvu", "sheet b.djvu", "mask.iff", "foreground.iff", "paint.iff", "tail.iff", "text.iff",
        }),
    },
    .{
        .bytes = @embedFile("../fixtures/standalone-layers/page.djvu"),
        .files = resources("standalone-layers", .{ "mask", "foreground", "paint", "tail", "text" }),
    },
    .{
        .bytes = @embedFile("../fixtures/thumbnails-inline-indirect/index.djvu"),
        .files = resources("thumbnails-inline-indirect", .{ "p0", "p2", "p3", "p4", "group.thumb", "empty.thumb" }),
    },
};

fn componentMutation(_: void, s: *Smith) !void {
    const index = pick(s, indirect.len);
    inline for (indirect, 0..) |fixture, i| if (index == i) {
        var budget: Budget = .{ .parent = a, .limit = if (s.value(bool)) 128 * 1024 else 8 * 1024 * 1024 };
        defer std.debug.assert(budget.live == 0);
        var doc = Document.open(budget.allocator(), fixture.bytes, limits) catch return;
        defer doc.deinit();
        var buffer: [32768]u8 = undefined;
        for (0..3) |_| {
            const page = pick(s, doc.pageCount());
            const scope = s.value(Document.Scope);
            for (0..24) |_| {
                const missing = (doc.nextMissing(page, scope) catch break) orelse break;
                const name = doc.components.items[missing].name;
                const source = blk: {
                    for (fixture.files) |file| if (std.mem.eql(u8, name, file.name)) break :blk file.bytes;
                    break;
                };
                const bytes = doc.allocator.dupe(u8, mutate(s, source, &buffer)) catch break;
                doc.provideComponent(missing, bytes) catch {
                    doc.allocator.free(bytes);
                    break;
                };
            }
            metadata(&doc, page);
            try exercise(&doc, s);
            try doc.dropComponents();
        }
    };
}

fn fuzzOne(_: void, s: *Smith) !void {
    try documentMutation({}, s);
    try componentMutation({}, s);
}

test "fuzz documents components and job lifecycle" {
    // Both families run for every recipe: a finite fuzz run must not spend its
    // entire iteration allowance on just one of several registered tests.
    try std.testing.fuzz({}, fuzzOne, .{});
}
