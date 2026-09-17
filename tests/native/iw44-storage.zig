const std = @import("std");
const iw44 = @import("../../src/iw44.zig");
const iff = @import("../../src/iff.zig");
const Budget = @import("../../src/budget.zig").Budget;

test "sparse IW44 coefficient indexes stay bounded and survive pool growth" {
    // A large empty color stream must not reserve one index per possible group.
    const chunk = [_]u8{ 0, 0, 1, 2, 16, 1, 16, 3, 0x80 }; // 4097 x 4099
    var budget: Budget = .{ .parent = std.testing.allocator, .limit = 2 * 1024 * 1024 };
    {
        const a = budget.allocator();
        var decoder = try iw44.Decoder.init(a, &.{&chunk}, .{});
        defer decoder.deinit();
        decoder.retain_coefficients = true;
        while (!try decoder.step(17)) {}
        const coefficients = &decoder.planes[0].coefficients;
        for (0..1024) |i| {
            const values = try coefficients.ensureBucket(a, i * 1024 + 7);
            try std.testing.expectEqualSlices(i16, &(.{0} ** 16), values);
            for (values, 0..) |*value, j| value.* = @intCast(@as(i32, @intCast(i * 16 + j)) - 8192);
        }
        // An absent directory page and an absent entry in a populated page both
        // read as zero. Revisit inserted groups after both pools have relocated.
        try std.testing.expect(coefficients.bucket(8) == null);
        try std.testing.expect(coefficients.bucket(0) == null);
        const live = budget.live;
        for (0..1024) |i| {
            const values = try coefficients.ensureBucket(a, i * 1024 + 7);
            for (values, 0..) |value, j| {
                try std.testing.expectEqual(@as(i16, @intCast(@as(i32, @intCast(i * 16 + j)) - 8192)), value);
            }
        }
        try std.testing.expectEqual(live, budget.live);
        const last = try coefficients.ensureBucket(a, coefficients.len() / 16 - 1);
        last[15] = -32768;
        try std.testing.expectEqual(@as(i16, -32768), coefficients.bucket(coefficients.len() / 16 - 1).?[15]);
    }
    try std.testing.expectEqual(@as(usize, 0), budget.live);
}

fn densePrefixes(a: std.mem.Allocator) !void {
    const Reference = struct { width: u32, height: u32, rgb_sha256: []const []const u8 };
    const oracle = try std.json.parseFromSlice(Reference, a, @embedFile("../fixtures/iw44-storage.json"), .{});
    defer oracle.deinit();
    var chunks: std.ArrayList([]const u8) = .empty;
    defer chunks.deinit(a);
    var iter = try (try iff.root(@embedFile("../fixtures/iw44-storage.djvu"))).children();
    while (try iter.next()) |chunk| if (iff.tag(chunk.id, "BG44")) try chunks.append(a, chunk.data);
    try std.testing.expectEqual(oracle.value.rgb_sha256.len, chunks.items.len);
    for (oracle.value.rgb_sha256, 1..) |expected, count| {
        var decoder = try iw44.Decoder.init(a, chunks.items[0..count], .{});
        defer decoder.deinit();
        decoder.retain_coefficients = true;
        while (!try decoder.step(127)) {}
        try decoder.reconstruct(.{ .x = 0, .y = 0, .width = oracle.value.width, .height = oracle.value.height });
        while (!try decoder.step(127)) {}
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(std.mem.sliceAsBytes(decoder.image.?.pixels), &digest, .{});
        try std.testing.expectEqualStrings(expected, &std.fmt.bytesToHex(digest, .lower));
    }
}

test "dense IW44 progressive coefficients match independent prefix images" {
    try densePrefixes(std.testing.allocator);
}

test "IW44 directory and value pool growth unwind on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, densePrefixes, .{});
}
