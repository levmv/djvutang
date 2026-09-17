const std = @import("std");
const iw44 = @import("../../src/iw44.zig");
const Region = @import("../../src/geometry.zig").Region;
const iff = @import("../../src/iff.zig");
const Document = @import("../../src/document.zig").Document;
const Job = @import("../../src/job.zig").Job;
const Budget = @import("../../src/budget.zig").Budget;
const composite = @import("../../src/composite.zig");

test "regional IW44 matches full reconstruction across block grids and image edges" {
    const a = std.testing.allocator;
    for ([_]u8{ 0, 0x80 }) |chroma| {
        const chunk = [_]u8{ 0, 0, 1, 2, 2, 129, 2, 3, chroma }; // 641 x 515
        var decoder = try iw44.Decoder.init(a, &.{&chunk}, .{});
        defer decoder.deinit();
        decoder.retain_coefficients = true;
        while (!try decoder.step(4096)) {}
        // Exercise every frequency, including signed 16-bit overflow during
        // lifting, independently of an encoder's usual quantization choices.
        for (&decoder.planes, 0..) |*plane, channel| {
            const coefficients = &plane.coefficients;
            for (0..coefficients.len() / 16) |i| {
                const values = try coefficients.ensureBucket(a, i);
                for (values, 0..) |*value, j| {
                    const bits: u16 = @truncate((i * 31 + j * 997 + channel * 121) *% 631);
                    value.* = @bitCast(bits);
                }
            }
        }
        const full: Region = .{ .x = 0, .y = 0, .width = 641, .height = 515 };
        try decoder.reconstruct(full);
        while (!try decoder.step(4096)) {}
        const expected = try a.dupe([3]u8, decoder.image.?.pixels);
        defer a.free(expected);
        const regions = [_]Region{
            .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .{ .x = 640, .y = 514, .width = 1, .height = 1 },
            .{ .x = 257, .y = 257, .width = 3, .height = 5 },
            .{ .x = 0, .y = 250, .width = 641, .height = 3 },
            .{ .x = 319, .y = 0, .width = 3, .height = 515 },
            .{ .x = 31, .y = 33, .width = 577, .height = 449 },
        };
        for (regions, 0..) |region, index| {
            try decoder.reconstruct(region);
            while (!try decoder.step(if (index == 2) 1 else 4096)) {}
            for (0..region.height) |y| {
                const row = expected[(region.y + y) * full.width + region.x ..][0..region.width];
                try std.testing.expectEqualSlices([3]u8, row, decoder.image.?.row(@intCast(region.y + y)));
            }
        }
        try std.testing.expectError(error.InvalidArgument, decoder.reconstruct(.{ .x = 641, .y = 0, .width = 1, .height = 1 }));
    }
}

test "large IW44 jobs retain exact pixels through sized rotated and reduced restarts" {
    const a = std.testing.allocator;
    const bytes = @embedFile("../fixtures/iw44-regions.djvu");
    var chunks: std.ArrayList([]const u8) = .empty;
    defer chunks.deinit(a);
    var iter = try (try iff.root(bytes)).children();
    while (try iter.next()) |chunk| if (iff.tag(chunk.id, "BG44")) try chunks.append(a, chunk.data);
    var decoder = try iw44.Decoder.init(a, chunks.items, .{});
    defer decoder.deinit();
    while (!try decoder.step(16384)) {}
    var full = decoder.takeImage();
    defer full.deinit(a);
    const Reference = struct { width: u32, height: u32, rgb_sha256: []const u8 };
    const oracle = try std.json.parseFromSlice(Reference, a, @embedFile("../fixtures/iw44-regions.json"), .{});
    defer oracle.deinit();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(std.mem.sliceAsBytes(full.pixels), &digest, .{});
    try std.testing.expectEqualStrings(oracle.value.rgb_sha256, &std.fmt.bytesToHex(digest, .lower));

    var budget: Budget = .{ .parent = a, .limit = 24 * 1024 * 1024 };
    for ([_]bool{ false, true }) |reduced| {
        var input: [bytes.len]u8 = bytes.*;
        if (reduced) {
            // The same large layer under a page grid with reduction 2, including
            // partial final cells. Gamma is applied before its interpolation.
            std.mem.writeInt(u16, input[24..26], @intCast(full.width * 2 - 1), .big);
            std.mem.writeInt(u16, input[26..28], @intCast(full.height * 2 - 1), .big);
            input[32] = 10;
        }
        var doc = try Document.open(budget.allocator(), &input, .{});
        defer doc.deinit();
        const options = [_]composite.Options{
            .{ .size = .{ .width = 137, .height = 181 } },
            .{ .subsample = 3, .rotation = 1, .region = .{ .x = 11, .y = 29, .width = 83, .height = 79 } },
            .{ .region = .{ .x = 973, .y = 1007, .width = 333, .height = 257 } },
            .{ .size = .{ .width = 181, .height = 137 }, .rotation = 3 },
            .{ .size = .{ .width = 1, .height = 1 }, .rotation = 2 },
            .{ .size = .{ .width = 137, .height = 181 } },
        };
        // Keep an exact reconstruction control alongside automatic previews.
        var job = try Job.init(&doc, 0, options[0]);
        job.preview_limit = 1;
        defer job.deinit();
        for (options, 0..) |opt, pass| {
            if (pass != 0) try job.restart(opt);
            while (try job.step(16384) != .done) {}
            try std.testing.expect(job.regional[0] != null);
            var reference = try composite.Renderer.init(a, job.info, opt, .{ .background = &full });
            defer reference.deinit();
            while (!try reference.step(16384)) {}
            try std.testing.expectEqualSlices(u8, reference.rgba, try job.pixels());
        }
        const previous = try a.dupe(u8, try job.pixels());
        defer a.free(previous);
        try std.testing.expectError(error.InvalidArgument, job.restart(.{ .region = .{ .x = 65535, .y = 0, .width = 1, .height = 1 } }));
        try std.testing.expectError(error.OutOfMemory, job.restart(.{}));
        try std.testing.expectEqualSlices(u8, previous, try job.pixels());
        try job.restart(.{ .region = .{ .x = 3, .y = 7, .width = 3, .height = 5 } });
        try std.testing.expectEqual(.progress, try job.step(1));
        job.cancel();
        try std.testing.expectError(error.Cancelled, job.step(1));
    }
    try std.testing.expectEqual(@as(usize, 0), budget.live);
}

fn allocationFailures(a: std.mem.Allocator) !void {
    const chunk = [_]u8{ 0, 0, 1, 2, 0, 37, 0, 29, 0x80 };
    var decoder = try iw44.Decoder.init(a, &.{&chunk}, .{});
    defer decoder.deinit();
    decoder.retain_coefficients = true;
    while (!try decoder.step(127)) {}
    for ([_]Region{
        .{ .x = 3, .y = 5, .width = 1, .height = 1 },
        .{ .x = 0, .y = 0, .width = 37, .height = 29 },
    }) |region| {
        try decoder.reconstruct(region);
        while (!try decoder.step(127)) {}
    }
}

test "regional IW44 releases partial rasters and coefficients after allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{});
}
