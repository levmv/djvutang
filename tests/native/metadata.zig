const std = @import("std");
const Document = @import("../../src/document.zig").Document;
const DocumentSource = @import("../../src/document.zig").DocumentSource;
const metadata = @import("../../src/metadata.zig");
const Budget = @import("../../src/budget.zig").Budget;
const a = std.testing.allocator;

fn open(allocator: std.mem.Allocator, bytes: []const u8) !Document {
    var source = try DocumentSource.init(allocator, @intCast(bytes.len), .{});
    defer source.deinit();
    while (try source.nextRange()) |range| try source.provide(bytes[range.offset..][0..range.length]);
    return source.finish();
}

fn scan(doc: *Document, bytes: []const u8) !metadata.Metadata {
    var job = try metadata.Scan.init(doc);
    defer job.deinit();
    while (try job.step(7) != .done) {
        if (try job.nextRange()) |range| {
            try std.testing.expectEqual(std.math.maxInt(u32), range.component);
            try job.provide(bytes[range.offset..][0..range.length], @intCast(bytes.len));
        }
    }
    return job.takeResult();
}

test "document metadata agrees for buffered and ranged input without loading images" {
    inline for (.{
        "annotations-a.djvu",      "annotations-z.djvu",      "annotations-split.djvu",
        "annotations-shared.djvu", "annotations-legacy.djvu", "annotations-recovered-split.djvu",
        "annotations-empty.djvu",  "text-z.djvu",             "shared.djvu",
        "thumbnails.thum",         "metadata-book.djvu",      "metadata-context.djvu",
        "metadata-none.djvu",      "metadata-links.djvu",
    }) |name| {
        errdefer std.debug.print("metadata fixture: {s}\n", .{name});
        const bytes = @embedFile("../fixtures/" ++ name);
        var full = try Document.open(a, bytes, .{});
        defer full.deinit();
        var ranged = try open(a, bytes);
        defer ranged.deinit();
        var expected = try scan(&full, bytes);
        defer expected.deinit();
        var actual = try scan(&ranged, bytes);
        defer actual.deinit();
        const first = try std.json.Stringify.valueAlloc(a, &expected, .{});
        defer a.free(first);
        const second = try std.json.Stringify.valueAlloc(a, &actual, .{});
        defer a.free(second);
        try std.testing.expectEqualStrings(first, second);
        try std.testing.expectEqual(@as(usize, 0), ranged.suppliedBytes());
        try std.testing.expectEqual(@as(usize, 0), ranged.dictionary_decodes);
        for (0..full.pageCount()) |page| {
            if (try full.annotations(page)) |value| {
                var annotations = value;
                defer annotations.deinit();
                for (annotations.metadata) |field| {
                    var found = false;
                    for (actual.metadata) |entry| {
                        if (std.mem.eql(u8, entry.key, field.key) and std.mem.eql(u8, entry.value, field.value) and
                            (entry.page == null or entry.page.? == page)) found = true;
                    }
                    try std.testing.expect(found);
                }
                if (annotations.xmp) |packet| {
                    var found = false;
                    for (actual.xmp) |entry| {
                        if (std.mem.eql(u8, entry.value, packet) and (entry.page == null or entry.page.? == page)) found = true;
                    }
                    try std.testing.expect(found);
                }
            }
        }
    }
}

test "metadata cancellation errors and ownership remain independent of the document" {
    const bytes = @embedFile("../fixtures/annotations-z.djvu");
    var doc = try open(a, bytes);
    defer doc.deinit();
    {
        var job = try metadata.Scan.init(&doc);
        defer job.deinit();
        try std.testing.expectError(error.Busy, metadata.Scan.init(&doc));
        try std.testing.expectError(error.Busy, doc.dropComponents());
        try std.testing.expectError(error.InvalidArgument, job.takeResult());
        try std.testing.expectEqual(.input, try job.step(1));
        job.cancel();
        try std.testing.expectError(error.Cancelled, job.step(1));
        try std.testing.expectError(error.Cancelled, job.nextRange());
        try std.testing.expectError(error.Cancelled, job.takeResult());
    }
    {
        var job = try metadata.Scan.init(&doc);
        defer job.deinit();
        try std.testing.expectEqual(.input, try job.step(1));
        try std.testing.expectError(error.InvalidData, job.provide(&.{}, bytes.len));
        job.cancel();
        try std.testing.expectError(error.InvalidData, job.step(1));
    }
    {
        var full = try Document.open(a, bytes, .{});
        defer full.deinit();
        var job = try metadata.Scan.init(&full);
        defer job.deinit();
        while (try job.step(1) != .done) {}
        job.cancel();
        var result = try job.takeResult();
        defer result.deinit();
        try std.testing.expect(result.metadata.len != 0);
    }
    var result = try scan(&doc, bytes);
    defer result.deinit();
    try std.testing.expect(result.metadata.len != 0);
    try doc.dropComponents();
    try std.testing.expectEqualStrings("Title", result.metadata[0].key);
    inline for (.{ "annotations-bad.djvu", "annotations-bzz-bad.djvu" }) |name| {
        const invalid = @embedFile("../fixtures/" ++ name);
        var broken = try open(a, invalid);
        defer broken.deinit();
        try std.testing.expectError(error.InvalidData, scan(&broken, invalid));
    }
}

fn allocations(allocator: std.mem.Allocator) !void {
    const bytes = @embedFile("../fixtures/annotations-shared.djvu");
    var doc = try open(allocator, bytes);
    defer doc.deinit();
    var result = try scan(&doc, bytes);
    defer result.deinit();
    try std.testing.expect(result.metadata.len != 0);
}

test "metadata scan releases partial state after allocation failures" {
    try std.testing.checkAllAllocationFailures(a, allocations, .{});
    var budget: Budget = .{ .parent = a, .limit = 256 * 1024 };
    try allocations(budget.allocator());
    try std.testing.expectEqual(@as(usize, 0), budget.live);
}

test "metadata structural and annotation limits fail explicitly" {
    const bytes = @embedFile("../fixtures/metadata-book.djvu");
    const Limits = @import("../../src/types.zig").Limits;
    for ([_]Limits{
        .{ .max_chunks = 2 },    .{ .max_include_depth = 1 },    .{ .max_annotation_bytes = 8 },
        .{ .max_bzz_bytes = 8 }, .{ .max_annotation_nodes = 3 }, .{ .max_annotation_depth = 1 },
    }) |limits| {
        var doc = try open(a, bytes);
        defer doc.deinit();
        doc.limits = limits;
        try std.testing.expectError(error.LimitExceeded, scan(&doc, bytes));
    }
    inline for (.{ "metadata-cycle.djvu", "metadata-bad-length.djvu" }) |name| {
        const invalid = @embedFile("../fixtures/" ++ name);
        var doc = try open(a, invalid);
        defer doc.deinit();
        try std.testing.expectError(error.InvalidData, scan(&doc, invalid));
    }
}

test "standalone metadata skips large image payloads with constant memory" {
    var previous_peak: usize = 0;
    for ([_]u32{ 128, 1024 * 1024 * 1024 }) |payload| {
        var prefix: [24]u8 = "AT&TFORM0000DJVUSjbz0000".*;
        const size: u32 = @as(u32, prefix.len) + payload;
        std.mem.writeInt(u32, prefix[8..12], size - 12, .big);
        std.mem.writeInt(u32, prefix[20..24], payload, .big);
        var budget: Budget = .{ .parent = a, .limit = 64 * 1024 };
        {
            var source = try DocumentSource.init(budget.allocator(), size, .{});
            defer source.deinit();
            while (try source.nextRange()) |range| {
                try std.testing.expect(range.offset + range.length <= prefix.len);
                try source.provide(prefix[range.offset..][0..range.length]);
            }
            var doc = try source.finish();
            defer doc.deinit();
            var job = try metadata.Scan.init(&doc);
            defer job.deinit();
            while (try job.step(1) != .done) {
                if (try job.nextRange()) |range| {
                    try std.testing.expect(range.offset + range.length <= prefix.len);
                    try job.provide(prefix[range.offset..][0..range.length], size);
                }
            }
            var result = try job.takeResult();
            defer result.deinit();
            try std.testing.expectEqual(@as(usize, 0), result.metadata.len);
            try std.testing.expectEqual(@as(usize, 0), result.xmp.len);
        }
        try std.testing.expectEqual(@as(usize, 0), budget.live);
        if (previous_peak != 0) try std.testing.expectEqual(previous_peak, budget.peak);
        previous_peak = budget.peak;
    }
}
