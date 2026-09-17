const std = @import("std");
const iw44 = @import("../../src/iw44.zig");
const Region = @import("../../src/geometry.zig").Region;
const Budget = @import("../../src/budget.zig").Budget;
const iff = @import("../../src/iff.zig");

test "compact IW44 grids match independent direct-reduction oracles" {
    const a = std.testing.allocator;
    const Level = struct { reduction: u32, width: u32, height: u32, rgb_sha256: []const u8 };
    const Reference = struct { name: []const u8, levels: []const Level };
    const references = try std.json.parseFromSlice([]const Reference, a, @embedFile("../fixtures/iw44-reduced.json"), .{});
    defer references.deinit();
    inline for (.{ "full", "half", "gray" }, 0..) |mode, fixture| {
        var chunks: std.ArrayList([]const u8) = .empty;
        defer chunks.deinit(a);
        var iter = try (try iff.root(@embedFile("../fixtures/iw44-reduced-" ++ mode ++ ".djvu"))).children();
        while (try iter.next()) |chunk| if (iff.tag(chunk.id, "BG44")) try chunks.append(a, chunk.data);
        var decoder = try iw44.Decoder.init(a, chunks.items, .{});
        defer decoder.deinit();
        decoder.retain_coefficients = true;
        try finish(&decoder, 17);
        for (references.value[fixture].levels) |level| {
            try decoder.reconstructReduced(level.reduction, .{ .x = 0, .y = 0, .width = level.width, .height = level.height });
            try finish(&decoder, 127);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(std.mem.sliceAsBytes(decoder.image.?.pixels[0 .. @as(usize, level.width) * level.height]), &digest, .{});
            try std.testing.expectEqualStrings(level.rgb_sha256, &std.fmt.bytesToHex(digest, .lower));
        }
    }
}

test "compact IW44 keeps every progressive chunk's coarse refinements" {
    const a = std.testing.allocator;
    var chunks: std.ArrayList([]const u8) = .empty;
    defer chunks.deinit(a);
    var iter = try (try iff.root(@embedFile("../fixtures/iw44-storage.djvu"))).children();
    while (try iter.next()) |chunk| if (iff.tag(chunk.id, "BG44")) try chunks.append(a, chunk.data);
    for (1..chunks.items.len + 1) |count| {
        var decoder = try iw44.Decoder.init(a, chunks.items[0..count], .{});
        defer decoder.deinit();
        decoder.retain_coefficients = true;
        try finish(&decoder, 4096);
        for ([_]u32{ 2, 4, 8, 16, 32 }) |reduction| {
            const expected = try fullGridReference(&decoder, reduction);
            defer a.free(expected);
            try decoder.reconstructReduced(reduction, .{
                .x = 0,
                .y = 0,
                .width = (decoder.header.width + reduction - 1) / reduction,
                .height = (decoder.header.height + reduction - 1) / reduction,
            });
            try finish(&decoder, 127);
            try std.testing.expectEqualSlices([3]u8, expected, decoder.image.?.pixels[0..expected.len]);
        }
    }
}

fn finish(decoder: *iw44.Decoder, work: usize) !void {
    while (!try decoder.step(work)) {}
}

fn fill(decoder: *iw44.Decoder) !void {
    const count: usize = if (decoder.header.color) 3 else 1;
    for (decoder.planes[0..count], 0..) |*plane, channel| {
        for (0..plane.coefficients.len() / 16) |i| {
            const values = try plane.coefficients.ensureBucket(decoder.allocator, i);
            for (values, 0..) |*value, j| {
                const bits: u16 = @truncate((i * 31 + j * 997 + channel * 121) *% 631);
                value.* = @bitCast(bits);
            }
        }
    }
}

// Full-size reference: retain every coefficient location and stop scalar lifting
// before finer stages. Convert colors before selecting the coarse grid, without
// compact scatter or reduced-region arithmetic.
fn fullGridReference(decoder: *iw44.Decoder, reduction: u32) ![][3]u8 {
    const w = decoder.header.width;
    const h = decoder.header.height;
    try decoder.reconstruct(.{ .x = 0, .y = 0, .width = w, .height = h });
    while (true) {
        if (decoder.phase == .filter and decoder.scale < reduction) decoder.phase = .extract;
        if (try decoder.step(1)) break;
    }
    const width = (w + reduction - 1) / reduction;
    const height = (h + reduction - 1) / reduction;
    const expected = try decoder.allocator.alloc([3]u8, @as(usize, width) * height);
    for (expected, 0..) |*pixel, i| {
        const x = i % width * reduction;
        const y = h - 1 - (height - 1 - i / width) * reduction;
        pixel.* = decoder.image.?.pixels[y * w + x];
    }
    return expected;
}

test "compact IW44 grids match stopped full-grid lifting including tiny odd and half-chroma planes" {
    const a = std.testing.allocator;
    for ([_][2]u16{ .{ 1, 1 }, .{ 1, 37 }, .{ 37, 1 }, .{ 33, 35 }, .{ 65, 67 } }) |size| {
        for ([_]u8{ 0, 1, 2 }) |mode| {
            var chunk = [_]u8{ 0, 0, if (mode == 0) 0x81 else 1, 2, 0, 0, 0, 0, if (mode == 1) 0 else 0x80 };
            std.mem.writeInt(u16, chunk[4..6], size[0], .big);
            std.mem.writeInt(u16, chunk[6..8], size[1], .big);
            var decoder = try iw44.Decoder.init(a, &.{&chunk}, .{});
            defer decoder.deinit();
            decoder.retain_coefficients = true;
            try finish(&decoder, 17);
            try fill(&decoder);
            for ([_]u32{ 1, 2, 4, 8, 16, 32 }) |reduction| {
                const expected = try fullGridReference(&decoder, reduction);
                defer a.free(expected);
                const width = (decoder.header.width + reduction - 1) / reduction;
                const height = (decoder.header.height + reduction - 1) / reduction;
                for ([_]usize{ 1, 17, 4096 }) |work| {
                    try decoder.reconstructReduced(reduction, .{ .x = 0, .y = 0, .width = width, .height = height });
                    try finish(&decoder, work);
                    try std.testing.expectEqualSlices([3]u8, expected, decoder.image.?.pixels[0..expected.len]);
                }
            }
        }
    }
}

test "compact IW44 regional halos preserve coarse-grid pixels across scale changes" {
    const a = std.testing.allocator;
    const chunk = [_]u8{ 0, 0, 1, 2, 2, 129, 2, 3, 0 }; // 641 x 515, half chroma
    var decoder = try iw44.Decoder.init(a, &.{&chunk}, .{});
    defer decoder.deinit();
    decoder.retain_coefficients = true;
    try finish(&decoder, 127);
    try fill(&decoder);
    for ([_]u32{ 8, 2, 32, 4, 16, 1, 8 }) |reduction| {
        const width = (decoder.header.width + reduction - 1) / reduction;
        const height = (decoder.header.height + reduction - 1) / reduction;
        try decoder.reconstructReduced(reduction, .{ .x = 0, .y = 0, .width = width, .height = height });
        try finish(&decoder, 4096);
        const expected = try a.dupe([3]u8, decoder.image.?.pixels[0 .. @as(usize, width) * height]);
        defer a.free(expected);
        for ([_]Region{
            .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .{ .x = width - 1, .y = height - 1, .width = 1, .height = 1 },
            .{ .x = width / 2, .y = height / 2, .width = 3, .height = 5 },
            .{ .x = 0, .y = height / 2, .width = width, .height = 3 },
            .{ .x = width / 2, .y = 0, .width = 3, .height = height },
        }) |region| {
            try decoder.reconstructReduced(reduction, region);
            try finish(&decoder, 17);
            for (0..region.height) |y| {
                std.testing.expectEqualSlices([3]u8, expected[(region.y + y) * width + region.x ..][0..region.width], decoder.image.?.row(@intCast(region.y + y))) catch |err| {
                    std.debug.print("reduction={d} region={any} area={any}\n", .{ reduction, region, decoder.area });
                    return err;
                };
            }
        }
    }
}

test "compact IW44 raster allocation scales with the selected grid and rejects invalid requests" {
    const chunk = [_]u8{ 0, 0, 1, 2, 16, 1, 16, 3, 0x80 }; // 4097 x 4099
    var budget: Budget = .{ .parent = std.testing.allocator, .limit = 4 * 1024 * 1024 };
    {
        var decoder = try iw44.Decoder.init(budget.allocator(), &.{&chunk}, .{});
        defer decoder.deinit();
        decoder.retain_coefficients = true;
        try finish(&decoder, 17);
        const region: Region = .{ .x = 0, .y = 0, .width = 513, .height = 513 };
        try decoder.reconstructReduced(8, region);
        try std.testing.expectError(error.Busy, decoder.reconstructReduced(8, region));
        try finish(&decoder, 4096);
        for (decoder.image.?.pixels) |pixel| try std.testing.expectEqual([3]u8{ 128, 128, 128 }, pixel);
        for ([_]u32{ 0, 3, 64, std.math.maxInt(u32) }) |bad| {
            try std.testing.expectError(error.InvalidArgument, decoder.reconstructReduced(bad, region));
        }
        try std.testing.expectError(error.InvalidArgument, decoder.reconstructReduced(32, region));
        try std.testing.expectError(error.InvalidArgument, decoder.reconstructReduced(8, .{ .x = 513, .y = 0, .width = 1, .height = 1 }));
        try std.testing.expectError(error.OutOfMemory, decoder.reconstruct(.{ .x = 0, .y = 0, .width = 4097, .height = 4099 }));
        try std.testing.expectEqual(@as(u32, 8), decoder.reduction);
        try std.testing.expectEqual(region, decoder.image.?.area());
        try std.testing.expectEqual([3]u8{ 128, 128, 128 }, decoder.image.?.pixels[0]);
    }
    try std.testing.expectEqual(@as(usize, 0), budget.live);
}

fn allocationFailures(a: std.mem.Allocator) !void {
    const chunk = [_]u8{ 0, 0, 1, 2, 0, 65, 0, 67, 0 };
    var decoder = try iw44.Decoder.init(a, &.{&chunk}, .{});
    defer decoder.deinit();
    decoder.retain_coefficients = true;
    try finish(&decoder, 17);
    try fill(&decoder);
    for ([_]u32{ 32, 8, 2, 1 }) |reduction| {
        try decoder.reconstructReduced(reduction, .{
            .x = 0,
            .y = 0,
            .width = (decoder.header.width + reduction - 1) / reduction,
            .height = (decoder.header.height + reduction - 1) / reduction,
        });
        try finish(&decoder, 127);
    }
}

test "compact IW44 releases partial rasters at every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{});
}
