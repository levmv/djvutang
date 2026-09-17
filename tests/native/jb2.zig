const std = @import("std");
const jb2 = @import("../../src/jb2.zig");
const iff = @import("../../src/iff.zig");
const Document = @import("../../src/document.zig").Document;
const Job = @import("../../src/job.zig").Job;
const a = std.testing.allocator;

test "INFO version accepts short headers and the legacy high-byte sentinel" {
    const cases = .{
        .{ &[_]u8{ 0, 64, 0, 48, 17 }, 17 },
        .{ &[_]u8{ 0, 64, 0, 48, 18, 0 }, 18 },
        .{ &[_]u8{ 0, 64, 0, 48, 18, 255 }, 18 },
        .{ &[_]u8{ 0, 64, 0, 48, 19, 0 }, 19 },
        .{ &[_]u8{ 0, 64, 0, 48, 17, 1 }, 273 },
    };
    inline for (cases) |case| {
        try std.testing.expectEqual(@as(u16, case[1]), try iff.infoVersion(case[0]));
    }
    const short = [_]u8{ 0, 64, 0, 48 };
    for (0..short.len + 1) |length| {
        try std.testing.expectError(error.InvalidData, iff.infoVersion(short[0..length]));
    }
}

test "JB2 padded copies keep their positions across the DjVu 18 to 19 boundary" {
    const expected = [_]jb2.Blit{
        .{ .shape = 0, .left = 5, .bottom = 33 },
        .{ .shape = 0, .left = 20, .bottom = 33 },
        .{ .shape = 0, .left = 35, .bottom = 33 },
        .{ .shape = 0, .left = 5, .bottom = 18 },
        .{ .shape = 0, .left = 20, .bottom = 18 },
        .{ .shape = 0, .left = 5, .bottom = 3 },
    };
    inline for (.{ "legacy", "modern" }) |name| {
        var bytes = @embedFile("../fixtures/jb2-padded-" ++ name ++ ".djvu").*;
        const versions = if (comptime std.mem.eql(u8, name, "legacy"))
            [_]u8{ 17, 18 }
        else
            [_]u8{ 19, 26 };
        for (versions) |version| {
            bytes[28] = version; // The low version byte in this fixture's INFO.
            for ([_]usize{ 1, 7, 4096 }) |work| {
                var doc = try Document.open(a, &bytes, .{});
                defer doc.deinit();
                var job = try Job.init(&doc, 0, .{});
                defer job.deinit();
                for (0..10_000) |_| {
                    if (try job.step(work) == .done) break;
                } else return error.TestWorkLimit;
                const image = &job.image.?;
                try std.testing.expectEqualDeep(@as([]const jb2.Blit, &expected), image.blits.items);
                const shape = image.shape(0);
                try std.testing.expectEqual(@as(u32, 7), shape.width);
                try std.testing.expectEqual(@as(u32, 9), shape.height);
                try std.testing.expectEqualSlices(u8, &.{ 0, 0, 60, 4, 4, 60, 4, 60, 0 }, shape.pixels);
                const box = jb2.Box{ .left = 2, .right = 5, .bottom = 2, .top = 7 };
                try std.testing.expectEqualDeep(box, shape.box);
            }
        }
    }
}

fn expectImage(expected: *const jb2.Image, actual: *const jb2.Image) !void {
    try std.testing.expectEqual(expected.width, actual.width);
    try std.testing.expectEqual(expected.height, actual.height);
    try std.testing.expectEqual(expected.inherited_count, actual.inherited_count);
    try std.testing.expectEqual(expected.shapeCount(), actual.shapeCount());
    try std.testing.expectEqualSlices(u32, expected.library.items, actual.library.items);
    try std.testing.expectEqualDeep(expected.blits.items, actual.blits.items);
    for (0..expected.shapeCount()) |i| {
        const left = expected.shape(@intCast(i));
        const right = actual.shape(@intCast(i));
        try std.testing.expectEqual(left.width, right.width);
        try std.testing.expectEqual(left.height, right.height);
        try std.testing.expectEqualDeep(left.box, right.box);
        try std.testing.expectEqualSlices(u8, left.pixels, right.pixels);
    }
}

test "JB2 row contexts preserve direct refinement and inherited symbols at every budget" {
    var direct: usize = 0;
    var refinement: usize = 0;
    inline for (.{ "plain", "shared", "foreground", "palette", "palette-empty" }) |name| {
        const bytes = @embedFile("../fixtures/" ++ name ++ ".djvu");
        var reference_doc = try Document.open(a, bytes, .{});
        defer reference_doc.deinit();
        for (0..reference_doc.pageCount()) |page| {
            var reference = try Job.init(&reference_doc, page, .{});
            defer reference.deinit();
            for (0..1_000_000) |_| {
                if (reference.decoder) |decoder| if (decoder.pending) |p| {
                    if (decoder.state == .pixels and p.pixel < p.shape.pixelCount()) {
                        if (p.reference != null) refinement += 1 else direct += 1;
                    }
                };
                // A one-unit call constructs the complete context afresh;
                // it never uses the shifted context for another pixel.
                if (try reference.step(1) == .done) break;
            } else return error.TestWorkLimit;
            for ([_]usize{ 2, 7, 31, 4096 }) |work| {
                var doc = try Document.open(a, bytes, .{});
                defer doc.deinit();
                var actual = try Job.init(&doc, page, .{});
                defer actual.deinit();
                for (0..1_000_000) |_| {
                    if (try actual.step(work) == .done) break;
                } else return error.TestWorkLimit;
                try std.testing.expectEqualSlices(u8, try reference.pixels(), try actual.pixels());
                try expectImage(&reference.image.?, &actual.image.?);
            }
        }
    }
    try std.testing.expect(direct > 0 and refinement > 0);
}

fn payload(bytes: []const u8) ![]const u8 {
    var chunks = try (try iff.root(bytes)).children();
    while (try chunks.next()) |chunk| if (iff.tag(chunk.id, "Sjbz")) return chunk.data;
    return error.MissingFixtureChunk;
}

test "JB2 row batches share one work budget with record and symbol transitions" {
    inline for (.{ "plain", "foreground", "palette-empty" }) |name| {
        const bytes = try payload(@embedFile("../fixtures/" ++ name ++ ".djvu"));
        var scalar = try jb2.Decoder.init(a, bytes, null, false, .{});
        defer scalar.deinit();
        var units: usize = 0;
        while (units < 1_000_000) {
            units += 1;
            if (try scalar.step(1)) break;
        } else return error.TestWorkLimit;
        var batched = try jb2.Decoder.init(a, bytes, null, false, .{});
        defer batched.deinit();
        try std.testing.expectError(error.InvalidArgument, batched.step(0));
        try std.testing.expect(!try batched.step(units - 1));
        try std.testing.expect(try batched.step(1));
        try expectImage(&scalar.image, &batched.image);
    }
}
