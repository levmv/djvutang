const std = @import("std");
const Document = @import("../../src/document.zig").Document;
const Job = @import("../../src/job.zig").Job;
const Budget = @import("../../src/budget.zig").Budget;
const a = std.testing.allocator;
const bundled = @embedFile("../fixtures/thumbnails.djvu");
const color = @embedFile("../fixtures/thumbnail-color-expected.ppm");
const gray = @embedFile("../fixtures/thumbnail-gray-expected.ppm");

fn prepare(doc: *Document, page: usize) !usize {
    return prepareFrom(doc, page, "thumbnails-indirect", .{ "first.thumb", "second.thumb", "empty.thumb", "p0", "p3", "p5" });
}
fn prepareFrom(doc: *Document, page: usize, comptime folder: []const u8, comptime files: anytype) !usize {
    var count: usize = 0;
    while (try doc.nextMissing(page, .thumbnail)) |index| {
        const name = doc.components.items[index].name;
        const source = blk: {
            inline for (files) |path| {
                if (std.mem.eql(u8, name, path)) break :blk @embedFile("../fixtures/" ++ folder ++ "/" ++ path);
            }
            return error.UnexpectedComponent;
        };
        const bytes = try doc.allocator.dupe(u8, source);
        doc.provideComponent(index, bytes) catch |err| {
            doc.allocator.free(bytes);
            return err;
        };
        count += 1;
    }
    return count;
}

fn expectImage(doc: *Document, page: usize, expected: []const u8) !void {
    var job = (try Job.initThumbnail(doc, page)).?;
    defer job.deinit();
    try std.testing.expectError(error.Busy, job.pixels());
    while (try job.step(2048) != .done) {}
    const rgba = try job.pixels();
    const rgb = expected[std.mem.indexOf(u8, expected, "\n255\n").? + 5 ..];
    try std.testing.expectEqual(rgb.len / 3 * 4, rgba.len);
    for (0..rgb.len / 3) |i| {
        try std.testing.expectEqualSlices(u8, rgb[i * 3 ..][0..3], rgba[i * 4 ..][0..3]);
        try std.testing.expectEqual(@as(u8, 255), rgba[i * 4 + 3]);
    }
}

test "TH44 groups follow logical DIRM pages across physical reordering and shared entries" {
    var doc = try Document.open(a, bundled, .{});
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 6), doc.pageCount());
    try std.testing.expectEqual(@as(?usize, null), try doc.thumbnailComponent(0));
    try std.testing.expectEqual(@as(?usize, 1), try doc.thumbnailComponent(2));
    try std.testing.expectEqualSlices(
        u8,
        @embedFile("../fixtures/thumbnail-color.th44"),
        (try doc.thumbnailChunk(1)).?.data,
    );
    try std.testing.expectEqualSlices(u8, @embedFile("../fixtures/thumbnail-gray.th44"), (try doc.thumbnailChunk(2)).?.data);
    for ([_]usize{ 0, 3, 5 }) |page| {
        try std.testing.expect((try doc.thumbnailChunk(page)) == null);
        try std.testing.expect((try Job.initThumbnail(&doc, page)) == null);
        try std.testing.expect(!doc.busy);
    }
    try expectImage(&doc, 1, color);
    try expectImage(&doc, 2, gray);
    try expectImage(&doc, 4, gray);
    try std.testing.expectEqual(@as(usize, 0), doc.dictionary_decodes);
    try std.testing.expectError(error.InvalidArgument, doc.thumbnailChunk(6));
    var single = try Document.open(a, @embedFile("../fixtures/plain.djvu"), .{});
    defer single.deinit();
    try std.testing.expect((try Job.initThumbnail(&single, 0)) == null);
}

test "indirect thumbnails load pages only for absent THUM entries and release supplied files on eviction" {
    var budget: Budget = .{ .parent = a, .limit = 1024 * 1024 };
    var doc = try Document.open(budget.allocator(), @embedFile("../fixtures/thumbnails-indirect/index.djvu"), .{});
    const baseline = budget.live;
    for (0..2) |_| {
        try std.testing.expectEqual(@as(usize, 1), try prepare(&doc, 0));
        try std.testing.expectError(error.MissingComponent, Job.initThumbnail(&doc, 1));
        try std.testing.expect(!doc.busy);
        try std.testing.expectEqual(@as(usize, 1), try prepare(&doc, 1));
        try std.testing.expectError(error.MissingComponent, doc.info(1));
        try expectImage(&doc, 1, color);
        try std.testing.expectEqual(@as(usize, 0), try prepare(&doc, 2));
        try expectImage(&doc, 2, gray);
        try std.testing.expectEqual(@as(usize, 1), try prepare(&doc, 4));
        try expectImage(&doc, 4, gray);
        try std.testing.expectEqual(@as(usize, 2), try prepare(&doc, 5));
        try std.testing.expect((try Job.initThumbnail(&doc, 5)) == null);
        try doc.dropComponents();
        try std.testing.expectEqual(baseline, budget.live);
    }
    doc.deinit();
    try std.testing.expectEqual(@as(usize, 0), budget.live);
}

test "thumbnail decoding is independent of page INFO and neighboring TH44 payloads" {
    var reference = try Document.open(a, bundled, .{});
    defer reference.deinit();
    var bytes: [bundled.len]u8 = bundled.*;
    const info = (try reference.find(try reference.pageComponent(1), "INFO")).?;
    bytes[info.offset + 8] = 0;
    bytes[info.offset + 9] = 0; // unusable page size does not affect its thumbnail
    const second = (try reference.thumbnailChunk(2)).?;
    bytes[second.offset + 8] = 1; // a TH44 must start a new IW44 image
    var doc = try Document.open(a, &bytes, .{});
    defer doc.deinit();
    try std.testing.expectError(error.InvalidData, doc.info(1));
    try expectImage(&doc, 1, color);
    try std.testing.expectError(error.InvalidData, Job.initThumbnail(&doc, 2));
    try std.testing.expect(!doc.busy);
    var page = try Job.init(&doc, 2, .{});
    {
        defer page.deinit();
        while (try page.step(2048) != .done) {}
        try std.testing.expectError(error.Busy, Job.initThumbnail(&doc, 1));
    }
    doc.limits.max_chunks = 1;
    try std.testing.expectError(error.LimitExceeded, doc.thumbnailChunk(1));
    doc.limits.max_chunks = 1_000_000;
    doc.limits.max_page_pixels = 10;
    try std.testing.expectError(error.LimitExceeded, Job.initThumbnail(&doc, 1));
    doc.limits.max_page_pixels = 64 * 1024 * 1024;
    doc.limits.max_iw_slices = 1;
    var limited = (try Job.initThumbnail(&doc, 1)).?;
    defer limited.deinit();
    try std.testing.expectError(error.LimitExceeded, limited.step(4096));
    try std.testing.expectError(error.LimitExceeded, limited.pixels());
}

test "thumbnail steps cancel without exposing partial pixels or retaining the job slot" {
    var doc = try Document.open(a, bundled, .{});
    defer doc.deinit();
    var job = (try Job.initThumbnail(&doc, 1)).?;
    {
        defer job.deinit();
        try std.testing.expectError(error.InvalidArgument, job.step(0));
        try std.testing.expectEqual(.progress, try job.step(1));
        try std.testing.expectError(error.Busy, doc.dropComponents());
        job.cancel();
        try std.testing.expectError(error.Cancelled, job.step(2048));
        try std.testing.expectError(error.Cancelled, job.pixels());
    }
    try expectImage(&doc, 1, color);
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var doc = try Document.open(allocator, @embedFile("../fixtures/thumbnails-indirect/index.djvu"), .{});
    defer doc.deinit();
    _ = try prepare(&doc, 1);
    try expectImage(&doc, 1, color);
    try doc.dropComponents();
    _ = try prepare(&doc, 2);
    try expectImage(&doc, 2, gray);
}

test "thumbnail lookup loading and IW44 decoding release every failed allocation" {
    try std.testing.checkAllAllocationFailures(a, allocationScenario, .{});
}

test "page-local TH44 ignores page INFO and INCL and decodes progressive chunks" {
    inline for (.{ "thumbnail-inline.djvu", "thumbnail-inline-progressive.djvu" }) |name| {
        const source = @embedFile("../fixtures/" ++ name);
        var bytes = source.*;
        var doc = try Document.open(a, &bytes, .{});
        defer doc.deinit();
        const info = (try doc.find(0, "INFO")).?;
        bytes[info.offset + 8] = 0;
        bytes[info.offset + 9] = 0;
        try std.testing.expectError(error.InvalidData, doc.info(0));
        try std.testing.expect((try doc.nextMissing(0, .thumbnail)) == null);
        try expectImage(&doc, 0, color);
        try std.testing.expectEqual(@as(usize, 0), doc.dictionary_decodes);
    }
    const source = @embedFile("../fixtures/thumbnail-inline-progressive.djvu");
    var bytes = source.*;
    var doc = try Document.open(a, &bytes, .{});
    defer doc.deinit();
    const first = (try doc.thumbnailChunk(0)).?;
    const second_offset = first.offset + 8 + first.data.len + first.data.len % 2;
    bytes[second_offset + 8] = 0; // A second independent image is ambiguous in a page.
    var job = (try Job.initThumbnail(&doc, 0)).?;
    defer job.deinit();
    var failure: ?anyerror = null;
    while (true) {
        const status = job.step(4096) catch |err| {
            failure = err;
            break;
        };
        if (status == .done) break;
    }
    try std.testing.expectEqual(error.InvalidData, failure.?);
    try std.testing.expectError(error.InvalidData, job.pixels());
}

test "DIRM thumbnails take precedence with page-local fallback for missing entries" {
    const source = @embedFile("../fixtures/thumbnails-inline.djvu");
    var bytes = source.*;
    var doc = try Document.open(a, &bytes, .{});
    defer doc.deinit();
    for ([_][]const u8{ color, gray, gray, color }, 0..) |expected, page| try expectImage(&doc, page, expected);
    try std.testing.expect((try Job.initThumbnail(&doc, 4)) == null);
    const preferred = (try doc.thumbnailChunk(1)).?;
    bytes[preferred.offset + 8] = 1;
    try std.testing.expectError(error.InvalidData, Job.initThumbnail(&doc, 1));
    try std.testing.expect(!doc.busy);
    try expectImage(&doc, 2, gray); // Bad preceding thumbnail does not poison fallback.

    var indirect = try Document.open(a, @embedFile("../fixtures/thumbnails-inline-indirect/index.djvu"), .{});
    defer indirect.deinit();
    for ([_]usize{ 1, 1, 1, 2, 1 }, 0..) |loads, page| {
        try std.testing.expectEqual(loads, try prepareFrom(&indirect, page, "thumbnails-inline-indirect", .{ "group.thumb", "empty.thumb", "p0", "p2", "p3", "p4" }));
        if (page < 4) try expectImage(&indirect, page, ([_][]const u8{ color, gray, gray, color })[page]);
    }
    try std.testing.expectError(error.MissingComponent, indirect.info(1)); // DIRM wins without reading the page.
    try std.testing.expect((try Job.initThumbnail(&indirect, 4)) == null);
}

test "standalone THUM exposes independent ordered images through page and thumbnail jobs" {
    const source = @embedFile("../fixtures/thumbnails.thum");
    var bytes = source.*;
    var doc = try Document.open(a, &bytes, .{});
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 2), doc.pageCount());
    for ([_][]const u8{ color, gray }, 0..) |expected, page| {
        try expectImage(&doc, page, expected);
        try std.testing.expect((try doc.nextMissing(page, .includes)) == null);
        try std.testing.expect((try doc.text(page)) == null);
        var job = try Job.init(&doc, page, .{});
        defer job.deinit();
        while (try job.step(2048) != .done) {}
        const rgba = try job.pixels();
        const rgb = expected[std.mem.indexOf(u8, expected, "\n255\n").? + 5 ..];
        try std.testing.expectEqual(rgb.len / 3 * 4, rgba.len);
        for (0..rgb.len / 3) |i| try std.testing.expectEqualSlices(u8, rgb[i * 3 ..][0..3], rgba[i * 4 ..][0..3]);
    }
    try std.testing.expectEqual(@as(u32, 11), (try doc.info(0)).width);
    try std.testing.expectEqual(@as(u32, 13), (try doc.info(1)).height);
    const second = (try doc.thumbnailChunk(1)).?;
    bytes[second.offset + 8] = 1; // THUM never joins chunks into one IW44 stream.
    try expectImage(&doc, 0, color);
    try std.testing.expectError(error.InvalidData, Job.init(&doc, 1, .{}));
    try std.testing.expectError(error.InvalidArgument, doc.thumbnailChunk(2));
    try std.testing.expectError(error.LimitExceeded, Document.open(a, source, .{ .max_components = 0 }));
    try std.testing.expectError(error.LimitExceeded, Document.open(a, source, .{ .max_chunks = 1 }));
    var empty = try Document.open(a, "AT&TFORM\x00\x00\x00\x04THUM", .{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.pageCount());
    try std.testing.expectError(error.InvalidArgument, Job.initThumbnail(&empty, 0));
}

fn standaloneAllocationScenario(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var doc = try Document.open(allocator, bytes, .{});
    defer doc.deinit();
    try expectImage(&doc, 0, color);
}

test "standalone THUM indexing and progressive inline TH44 release every failed allocation" {
    inline for (.{ "thumbnails.thum", "thumbnail-inline-progressive.djvu" }) |name|
        try std.testing.checkAllAllocationFailures(a, standaloneAllocationScenario, .{@as([]const u8, @embedFile("../fixtures/" ++ name))});
}
