const std = @import("std");
const Palette = @import("../../src/color.zig").Palette;
const iff = @import("../../src/iff.zig");
const Document = @import("../../src/document.zig").Document;
const Job = @import("../../src/job.zig").Job;
const a = std.testing.allocator;

fn paletteChunk(bytes: []const u8) !iff.Chunk {
    var chunks = try (try iff.root(bytes)).children();
    while (try chunks.next()) |chunk| if (iff.tag(chunk.id, "FGbz")) return chunk;
    return error.MissingPalette;
}

test "FGbz missing correspondence assigns no colors and empty correspondence requires zero blits" {
    const without_table = "\x00\x00\x01\xbc\x5b\x00";
    for ([_]?usize{ null, 0, 19 }) |blits| {
        var palette = try Palette.parse(a, without_table, blits, .{});
        defer palette.deinit(a);
        try std.testing.expectEqualSlices([3]u8, &.{.{ 0, 91, 188 }}, palette.colors);
        try std.testing.expectEqual(@as(usize, 0), palette.indices.len);
    }
    const empty_table = "\x80" ++ without_table[1..] ++ "\x00\x00\x00";
    for ([_]?usize{ null, 0 }) |blits| {
        var palette = try Palette.parse(a, empty_table, blits, .{});
        defer palette.deinit(a);
        try std.testing.expectEqual(@as(usize, 0), palette.indices.len);
    }
    try std.testing.expectError(error.InvalidData, Palette.parse(a, empty_table, 1, .{}));
    try std.testing.expectError(error.InvalidData, Palette.parse(a, without_table ++ "\x00", null, .{}));
    for (0..without_table.len) |len|
        try std.testing.expectError(error.InvalidData, Palette.parse(a, without_table[0..len], null, .{}));
}

test "unattached FGbz still validates its indices version and resource bounds" {
    const data = (try paletteChunk(@embedFile("../fixtures/mmr-palette.djvu"))).data;
    for ([_]?usize{ null, 3 }) |blits| {
        var palette = try Palette.parse(a, data, blits, .{});
        defer palette.deinit(a);
        try std.testing.expectEqualSlices(u16, &.{ 2, 1, 0 }, palette.indices);
    }
    try std.testing.expectError(error.InvalidData, Palette.parse(a, data, 2, .{}));
    try std.testing.expectError(error.LimitExceeded, Palette.parse(a, data, null, .{ .max_blits = 2 }));
    try std.testing.expectError(error.LimitExceeded, Palette.parse(a, data, null, .{ .max_bzz_bytes = 5 }));
    // Keep the encoded indices, including 2, but remove the third palette entry.
    const bad = try a.alloc(u8, data.len - 3);
    defer a.free(bad);
    @memcpy(bad[0..9], data[0..9]);
    bad[2] = 2;
    @memcpy(bad[9..], data[12..]);
    try std.testing.expectError(error.InvalidData, Palette.parse(a, bad, null, .{}));

    var bytes: [@embedFile("../fixtures/mmr-palette.djvu").len]u8 = @embedFile("../fixtures/mmr-palette.djvu").*;
    bytes[(try paletteChunk(&bytes)).offset + 8] = 0x81;
    var doc = try Document.open(a, &bytes, .{});
    defer doc.deinit();
    var job = try Job.init(&doc, 0, .{});
    defer job.deinit();
    const failure = blk: {
        for (0..100_000) |_| {
            const status = job.step(127) catch |err| break :blk err;
            if (status == .done) return error.TestExpectedError;
        }
        return error.TestWorkLimit;
    };
    try std.testing.expectEqual(error.Unsupported, failure);
    try std.testing.expectError(error.Unsupported, job.pixels());
}
