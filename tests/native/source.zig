const std = @import("std");
const module = @import("../../src/document.zig");
const Document = module.Document;
const DocumentSource = module.DocumentSource;
const Job = @import("../../src/job.zig").Job;
const Budget = @import("../../src/budget.zig").Budget;
const iff = @import("../../src/iff.zig");
const Limits = @import("../../src/types.zig").Limits;
const a = std.testing.allocator;

fn open(allocator: std.mem.Allocator, bytes: []const u8) !Document {
    return openLimited(allocator, bytes, .{});
}

fn openLimited(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) !Document {
    var source = try DocumentSource.init(allocator, @intCast(bytes.len), limits);
    defer source.deinit();
    while (try source.nextRange()) |range| try source.provide(bytes[range.offset..][0..range.length]);
    return source.finish();
}

fn prepare(doc: *Document, bytes: []const u8, page: usize, scope: Document.Scope) !void {
    while (try doc.nextMissing(page, scope)) |index| {
        const range = doc.components.items[index].range.?;
        const owned = try doc.allocator.dupe(u8, bytes[range.offset..][0..range.length]);
        doc.provideComponent(index, owned) catch |err| {
            doc.allocator.free(owned);
            return err;
        };
    }
}

test "range documents match complete input for pages shared layers text and thumbnails" {
    inline for (.{
        "shared.djvu",
        "reordered.djvu",
        "shared-layers.djvu",
        "annotations-shared.djvu",
        "thumbnails.djvu",
        "color.djvu",
        "pm44-progressive.iw4",
        "thumbnails.thum",
    }) |name| {
        errdefer std.debug.print("range fixture: {s}\n", .{name});
        const bytes = @embedFile("../fixtures/" ++ name);
        var full = try Document.open(a, bytes, .{});
        defer full.deinit();
        const bundled = iff.tag(try full.container.formType(), "DJVM");
        var source = try DocumentSource.init(a, bytes.len, .{});
        defer source.deinit();
        while (try source.nextRange()) |range| {
            if (bundled) for (full.components.items) |component| {
                if (component.size == 0) continue;
                const form = component.form.?;
                try std.testing.expect(range.offset + range.length <= form.offset or
                    range.offset >= form.offset + 8 + form.data.len);
            };
            try source.provide(bytes[range.offset..][0..range.length]);
        }
        var ranged = try source.finish();
        defer ranged.deinit();
        try std.testing.expectEqual(full.pageCount(), ranged.pageCount());
        if (bundled) for (ranged.components.items) |c| {
            try std.testing.expect(c.range != null and c.form == null);
        };
        for (0..full.pageCount()) |page| {
            try prepare(&ranged, bytes, page, .includes);
            try std.testing.expectEqualDeep(try full.info(page), try ranged.info(page));
            {
                var expected = try Job.init(&full, page, .{ .size = .{ .width = 43, .height = 61 }, .rotation = 1 });
                defer expected.deinit();
                var actual = try Job.init(&ranged, page, .{ .size = .{ .width = 43, .height = 61 }, .rotation = 1 });
                defer actual.deinit();
                while (try expected.step(4096) != .done) {}
                while (try actual.step(73) != .done) {}
                try std.testing.expectEqualSlices(u8, try expected.pixels(), try actual.pixels());
            }
            if (try full.text(page)) |value| {
                var expected = value;
                defer expected.deinit(a);
                var actual = (try ranged.text(page)).?;
                defer actual.deinit(a);
                try std.testing.expectEqualSlices(u8, expected.bytes, actual.bytes);
                try std.testing.expectEqualDeep(expected.zones, actual.zones);
            } else try std.testing.expectEqual(null, try ranged.text(page));
            if (try full.annotations(page)) |value| {
                var expected = value;
                defer expected.deinit();
                var actual = (try ranged.annotations(page)).?;
                defer actual.deinit();
                const expected_json = try std.json.Stringify.valueAlloc(a, &expected, .{});
                defer a.free(expected_json);
                const actual_json = try std.json.Stringify.valueAlloc(a, &actual, .{});
                defer a.free(actual_json);
                try std.testing.expectEqualStrings(expected_json, actual_json);
            }
            try prepare(&ranged, bytes, page, .thumbnail);
            if (try Job.initThumbnail(&full, page)) |value| {
                var expected = value;
                defer expected.deinit();
                var actual = (try Job.initThumbnail(&ranged, page)).?;
                defer actual.deinit();
                while (try expected.step(4096) != .done) {}
                while (try actual.step(73) != .done) {}
                try std.testing.expectEqualSlices(u8, try expected.pixels(), try actual.pixels());
            } else try std.testing.expectEqual(null, try Job.initThumbnail(&ranged, page));
            try ranged.dropComponents();
            if (bundled) try std.testing.expectEqual(@as(usize, 0), ranged.suppliedBytes());
        }
        try prepare(&ranged, bytes, 0, .includes);
    }
}

test "component header errors are deferred to supply and rejected input remains retryable" {
    const original = @embedFile("../fixtures/shared.djvu");
    const offset = std.mem.readInt(u32, original[35..39], .big); // Second page.
    for (0..4) |corruption| {
        var bytes: [original.len]u8 = original.*;
        switch (corruption) {
            0 => @memcpy(bytes[offset..][0..4], "JUNK"),
            1 => @memcpy(bytes[offset + 8 ..][0..4], "DJVI"),
            2 => std.mem.writeInt(u32, bytes[offset + 4 ..][0..4], 4, .big),
            3 => std.mem.writeInt(u32, bytes[offset + 4 ..][0..4], 0xffffffff, .big),
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidData, Document.open(a, &bytes, .{}));
        var doc = try open(a, &bytes);
        defer doc.deinit();
        try prepare(&doc, &bytes, 0, .includes);
        try std.testing.expectEqual(@as(u32, 160), (try doc.info(0)).width);
        const index = (try doc.nextMissing(1, .page)).?;
        const range = doc.components.items[index].range.?;
        const wrong = try a.dupe(u8, bytes[range.offset..][0..range.length]);
        defer a.free(wrong);
        const retained = doc.suppliedBytes();
        try std.testing.expectError(error.InvalidData, doc.provideComponent(index, wrong));
        try std.testing.expectEqual(retained, doc.suppliedBytes());
        try std.testing.expectEqual(index, (try doc.nextMissing(1, .page)).?);
        try prepare(&doc, original, 1, .includes);
        try std.testing.expectEqual(@as(u32, 160), (try doc.info(1)).width);
    }
}

test "directory skips reject invalid bounds overlaps and preserve structural limits" {
    const original = @embedFile("../fixtures/shared.djvu");
    const first_page = std.mem.readInt(u32, original[31..35], .big);
    for ([_]u32{ 0, 16, 24, first_page + 1, first_page + 12, original.len - 2, 0xfffffffe }) |offset| {
        var bytes: [original.len]u8 = original.*;
        std.mem.writeInt(u32, bytes[35..39], offset, .big);
        try std.testing.expectError(error.InvalidData, open(a, &bytes));
    }
    try std.testing.expectError(error.LimitExceeded, openLimited(a, original, .{ .max_chunks = 3 }));
    try std.testing.expectError(error.LimitExceeded, openLimited(a, original, .{ .max_components = 2 }));
    try std.testing.expectError(error.LimitExceeded, openLimited(a, original, .{ .max_input_bytes = 30 }));
    var extra: [original.len + 8]u8 = undefined;
    @memcpy(extra[0..original.len], original);
    @memcpy(extra[original.len..], "FORM\x00\x00\x00\x00");
    std.mem.writeInt(u32, extra[8..12], extra.len - 12, .big);
    try std.testing.expectError(error.LimitExceeded, openLimited(a, &extra, .{ .max_components = 3 }));
}

test "range opening preserves NAVM placement indirect indexes and duplicate errors" {
    inline for (.{
        "outline.djvu",
        "outline-late.djvu",
        "outline-indirect/index.djvu",
        "outline-single.djvu",
        "indirect-v0/index.djvu",
    }) |name| {
        var full = try Document.open(a, @embedFile("../fixtures/" ++ name), .{});
        defer full.deinit();
        var ranged = try open(a, @embedFile("../fixtures/" ++ name));
        defer ranged.deinit();
        try std.testing.expectEqual(full.indirect, ranged.indirect);
        if (try full.outline()) |value| {
            var expected = value;
            defer expected.deinit(a);
            var actual = (try ranged.outline()).?;
            defer actual.deinit(a);
            try std.testing.expectEqualDeep(expected.entries, actual.entries);
        }
        try std.testing.expectEqualDeep(try full.resolveLink("#page-a", 0), try ranged.resolveLink("#page-a", 0));
    }
    var duplicate = try open(a, @embedFile("../fixtures/outline-duplicate.djvu"));
    defer duplicate.deinit();
    try std.testing.expectError(error.InvalidData, duplicate.outline());
}

fn allocationCheck(allocator: std.mem.Allocator) !void {
    inline for (.{ "shared.djvu", "outline-late.djvu" }) |name| {
        const bytes = @embedFile("../fixtures/" ++ name);
        var doc = try open(allocator, bytes);
        defer doc.deinit();
        try prepare(&doc, bytes, 0, .includes);
        try doc.dropComponents();
        try prepare(&doc, bytes, 1, .includes);
    }
}

test "range opening and component ownership unwind partial allocations" {
    try std.testing.checkAllAllocationFailures(a, allocationCheck, .{});
    const bytes = @embedFile("../fixtures/shared.djvu");
    var source = try DocumentSource.init(a, bytes.len, .{});
    defer source.deinit();
    try std.testing.expectError(error.InvalidData, source.provide(bytes[0..15]));
    try std.testing.expectError(error.InvalidArgument, source.nextRange());
    var doc = try open(a, bytes);
    defer doc.deinit();
    const index = (try doc.nextMissing(0, .page)).?;
    const range = doc.components.items[index].range.?;
    const wrong = try a.dupe(u8, bytes[range.offset..][0 .. range.length - 1]);
    defer a.free(wrong);
    try std.testing.expectError(error.InvalidData, doc.provideComponent(index, wrong));
    try prepare(&doc, bytes, 0, .includes);
}

test "a large source skips unknown payloads within a small allocation budget" {
    const original = @embedFile("../fixtures/shared.djvu");
    var prefix: [original.len]u8 = original.*;
    const skipped = 200 * 1024 * 1024;
    const size = original.len + 8 + skipped;
    std.mem.writeInt(u32, prefix[8..12], size - 12, .big);
    var header: [8]u8 = undefined;
    @memcpy(header[0..4], "JUNK");
    std.mem.writeInt(u32, header[4..8], skipped, .big);
    var budget: Budget = .{ .parent = a, .limit = 128 * 1024 };
    {
        var source = try DocumentSource.init(budget.allocator(), size, .{});
        defer source.deinit();
        var read_bytes: usize = 0;
        while (try source.nextRange()) |range| {
            read_bytes += range.length;
            if (range.offset == original.len) {
                try std.testing.expectEqual(@as(u32, 8), range.length);
                try source.provide(&header);
            } else try source.provide(prefix[range.offset..][0..range.length]);
        }
        try std.testing.expect(read_bytes < original.len);
        var doc = try source.finish();
        defer doc.deinit();
        try prepare(&doc, original, 1, .includes);
        try std.testing.expectEqual(@as(u32, 160), (try doc.info(1)).width);
    }
    try std.testing.expectEqual(@as(usize, 0), budget.live);
}
