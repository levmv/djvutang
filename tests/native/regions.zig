const std = @import("std");
const Document = @import("../../src/document.zig").Document;
const Job = @import("../../src/job.zig").Job;
const Budget = @import("../../src/budget.zig").Budget;
const composite = @import("../../src/composite.zig");
const Region = composite.Region;

fn finish(job: *Job, work: usize) !void {
    for (0..1_000_000) |_| {
        if (try job.step(work) == .done) return;
        try std.testing.expectError(error.Busy, job.pixels());
    }
    return error.TestWorkLimit;
}

fn expectCrop(full: []const u8, width: u32, region: Region, rgba: []const u8) !void {
    try std.testing.expectEqual(@as(usize, region.width) * region.height * 4, rgba.len);
    for (0..region.height) |y| {
        const src = ((region.y + y) * width + region.x) * 4;
        const dest = y * region.width * 4;
        try std.testing.expectEqualSlices(u8, full[src..][0 .. region.width * 4], rgba[dest..][0 .. region.width * 4]);
    }
}

test "sized weights preserve fractional coverage and the full 32-bit area boundary" {
    const geometry = @import("../../src/geometry.zig");
    const narrow = try geometry.Transform.init(
        .{ .width = 11, .height = 1, .dpi = 300, .rotation = 0 },
        .{ .size = .{ .width = 4, .height = 1 } },
    );
    const weights = [_][]const u32{ &.{ 4, 4, 3 }, &.{ 1, 4, 4, 2 }, &.{ 2, 4, 4, 1 }, &.{ 3, 4, 4 } };
    for (weights, 0..) |expected, x| {
        const window = narrow.window(.{ .width = 11, .height = 1, .dpi = 300, .rotation = 0 }, @intCast(x), 0);
        try std.testing.expectEqual(expected.len, window.x.count);
        for (expected, 0..) |weight, i| try std.testing.expectEqual(weight, window.x.weight(@intCast(i)));
        try std.testing.expectEqual(11, window.total());
    }
    const info: @import("../../src/iff.zig").Info = .{ .width = 65535, .height = 65535, .dpi = 300, .rotation = 0 };
    const shrink = try geometry.Transform.init(info, .{ .size = .{ .width = 1, .height = 1 } });
    const whole = shrink.window(info, 0, 0);
    try std.testing.expectEqual(@as(u64, 65535) * 65535, whole.total());
    var sum: u64 = 0;
    for (0..whole.x.count) |i| sum += whole.x.weight(@intCast(i));
    try std.testing.expectEqual(65535, sum);

    // Only the requested tile is allocated, even at the maximum output size.
    // Clamped enlargement samples can sum to exactly 65536 * 65536.
    const max = std.math.maxInt(u32);
    const options: composite.Options = .{
        .size = .{ .width = max, .height = max },
        .region = .{ .x = max - 2, .y = max - 2, .width = 2, .height = 2 },
    };
    var mask = [_]u8{1};
    const bitmap: @import("../../src/pixmap.zig").Bitmap = .{ .width = 1, .height = 1, .pixels = &mask };
    var bilevel = try composite.Renderer.init(
        std.testing.allocator,
        .{ .width = 1, .height = 1, .dpi = 300, .rotation = 0 },
        options,
        .{ .mask = .{ .bitmap = &bitmap } },
    );
    defer bilevel.deinit();
    var colors = [_][3]u8{ .{ 0, 0, 0 }, .{ 127, 31, 59 }, .{ 251, 137, 83 }, .{ 255, 255, 255 } };
    const bg: @import("../../src/pixmap.zig").Pixmap = .{ .width = 2, .height = 2, .pixels = &colors };
    var color = try composite.Renderer.init(
        std.testing.allocator,
        .{ .width = 2, .height = 2, .dpi = 300, .rotation = 0 },
        options,
        .{ .background = &bg },
    );
    defer color.deinit();
    for ([_]usize{ 1, 3, 4096 }) |work| {
        try bilevel.restart(options);
        try color.restart(options);
        while (!try bilevel.step(work)) {}
        while (!try color.step(work)) {}
        for (0..4) |i| {
            try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, bilevel.rgba[i * 4 ..][0..4]);
            try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, color.rgba[i * 4 ..][0..4]);
        }
        try std.testing.expectEqual(@as(u64, 1) << 32, color.transform.window(color.info, 0, 0).total());
    }
}

test "fit uses area averages and bilinear enlargement on a known gradient" {
    var colors = [_][3]u8{
        .{ 0, 0, 0 },    .{ 60, 60, 60 },    .{ 120, 120, 120 },
        .{ 60, 60, 60 }, .{ 120, 120, 120 }, .{ 180, 180, 180 },
    };
    const bg: @import("../../src/pixmap.zig").Pixmap = .{ .width = 3, .height = 2, .pixels = &colors };
    var renderer = try composite.Renderer.init(
        std.testing.allocator,
        .{ .width = 3, .height = 2, .dpi = 300, .rotation = 0 },
        .{ .size = .{ .width = 2, .height = 2 } },
        .{ .background = &bg },
    );
    defer renderer.deinit();
    while (!try renderer.step(1)) {}
    try std.testing.expectEqualSlices(u8, &.{ 50, 50, 50, 255, 130, 130, 130, 255 }, renderer.rgba);
    try renderer.restart(.{ .size = .{ .width = 6, .height = 4 } });
    while (!try renderer.step(1)) {}
    const expected = [_]u8{
        0,  15, 45,  75,  105, 120,
        15, 30, 60,  90,  120, 135,
        45, 60, 90,  120, 150, 165,
        60, 75, 105, 135, 165, 180,
    };
    for (expected, 0..) |gray, i| try std.testing.expectEqualSlices(
        u8,
        &.{ gray, gray, gray, 255 },
        renderer.rgba[i * 4 ..][0..4],
    );
}

test "fitted pages keep tile samples and text transforms through rotations and restart" {
    const a = std.testing.allocator;
    inline for (.{ "plain", "rotated-color", "palette", "foreground", "jpeg-progressive", "mmr-foreground" }) |name| {
        var doc = try Document.open(a, @embedFile("../fixtures/" ++ name ++ ".djvu"), .{});
        defer doc.deinit();
        var job = try Job.init(&doc, 0, .{});
        defer job.deinit();
        try finish(&job, 4096);
        const sizes = [_]@import("../../src/geometry.zig").Size{
            .{ .width = 17, .height = 23 },
            .{ .width = 139, .height = 127 },
            .{ .width = 1, .height = 1 },
        };
        for (sizes) |size| for (0..4) |turn| {
            const options: composite.Options = .{ .size = size, .rotation = @intCast(turn) };
            try job.restart(options);
            try finish(&job, 4096);
            const full = try a.dupe(u8, try job.pixels());
            defer a.free(full);
            const g = try job.geometry();
            try std.testing.expect(g.width <= size.width and g.height <= size.height);
            try std.testing.expect(g.width == size.width or g.height == size.height);
            const info = try doc.info(0);
            const t = try doc.transform(0, options);
            const bounds = t.rect(.{ .x = 0, .y = 0, .width = @floatFromInt(info.width), .height = @floatFromInt(info.height) });
            try std.testing.expectApproxEqAbs(@as(f64, 0), bounds.x, 1e-8);
            try std.testing.expectApproxEqAbs(@as(f64, 0), bounds.y, 1e-8);
            try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(g.width)), bounds.width, 1e-8);
            try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(g.height)), bounds.height, 1e-8);
            var y: u32 = 0;
            while (y < g.height) : (y += 19) {
                const region: Region = .{
                    .x = g.width / 2,
                    .y = y,
                    .width = g.width - g.width / 2,
                    .height = @min(19, g.height - y),
                };
                var tile_options = options;
                tile_options.region = region;
                try job.restart(tile_options);
                try finish(&job, 127);
                try expectCrop(full, g.width, region, try job.pixels());
                const tt = try doc.transform(0, tile_options);
                const p = tt.unmap(tt.point(.{ .x = 7.25, .y = 3.5 }));
                try std.testing.expectApproxEqAbs(@as(f64, 7.25), p.x, 1e-8);
                try std.testing.expectApproxEqAbs(@as(f64, 3.5), p.y, 1e-8);
            }
        };
        try std.testing.expectError(error.InvalidArgument, job.restart(.{ .size = .{ .width = 0, .height = 9 } }));
        try std.testing.expectError(error.InvalidArgument, job.restart(.{ .size = .{ .width = 9, .height = 9 }, .subsample = 2 }));
        try job.restart(.{ .size = .{ .width = 1, .height = 1 } });
        try std.testing.expectEqual(.progress, try job.step(1));
        job.cancel();
        try std.testing.expectError(error.Cancelled, job.step(1));
    }
}

test "tiles equal full frames across layers rotations reductions and request order" {
    const a = std.testing.allocator;
    const fixtures = [_][]const u8{
        @embedFile("../fixtures/plain.djvu"),
        @embedFile("../fixtures/rotated.djvu"),
        @embedFile("../fixtures/shared.djvu"),
        @embedFile("../fixtures/progressive.djvu"),
        @embedFile("../fixtures/pm44-progressive.iw4"),
        @embedFile("../fixtures/bm44.iw4"),
        @embedFile("../fixtures/chroma-half.djvu"),
        @embedFile("../fixtures/rotated-color.djvu"),
        @embedFile("../fixtures/palette.djvu"),
        @embedFile("../fixtures/palette-unmapped-bg.djvu"),
        @embedFile("../fixtures/mmr-palette-bg.djvu"),
        @embedFile("../fixtures/compound.djvu"),
        @embedFile("../fixtures/foreground.djvu"),
        @embedFile("../fixtures/tiny.djvu"),
        @embedFile("../fixtures/mmr-striped-inverted.djvu"),
        @embedFile("../fixtures/mmr-foreground.djvu"),
        @embedFile("../fixtures/mmr-uncompressed.djvu"),
    };
    for (fixtures) |bytes| {
        var doc = try Document.open(a, bytes, .{});
        defer doc.deinit();
        for (0..doc.pageCount()) |page| {
            const geometry = try doc.geometry(page, .{ .subsample = 3, .rotation = 1 });
            const corner: Region = .{ .x = geometry.width - 1, .y = geometry.height - 1, .width = 1, .height = 1 };
            var job = try Job.init(&doc, page, .{ .subsample = 3, .rotation = 1, .region = corner });
            defer job.deinit();
            try finish(&job, 71);
            const cold = (try job.pixels())[0..4].*;
            const mask_ptr = job.renderer.?.mask.ptr;
            const bg_ptr = if (job.background) |bg| bg.pixels.ptr else null;
            for ([_]u16{ 1, 2, 3, 4, 256 }) |ss| for (0..4) |turn| {
                const rotation: u2 = @intCast(turn);
                try job.restart(.{ .subsample = ss, .rotation = rotation });
                try finish(&job, 4096);
                const full_geometry = try job.geometry();
                const full = try a.dupe(u8, try job.pixels());
                defer a.free(full);
                if (ss == 3 and rotation == 1) try expectCrop(full, full_geometry.width, corner, &cold);
                // Odd-sized tiles in reverse order exercise shared edges, corners,
                // palette overlaps, rotated padding and partial filter cells.
                var bottom = full_geometry.height;
                while (bottom > 0) {
                    const height = @min(bottom, 11);
                    var right = full_geometry.width;
                    while (right > 0) {
                        const width = @min(right, 7);
                        const region: Region = .{ .x = right - width, .y = bottom - height, .width = width, .height = height };
                        try job.restart(.{ .subsample = ss, .rotation = rotation, .region = region });
                        try finish(&job, 4096);
                        const g = try job.geometry();
                        try std.testing.expectEqual(region.x, g.x);
                        try std.testing.expectEqual(region.y, g.y);
                        try std.testing.expectEqual(full_geometry.width, g.page_width);
                        try std.testing.expectEqual(full_geometry.height, g.page_height);
                        try expectCrop(full, full_geometry.width, region, try job.pixels());
                        try std.testing.expectEqual(mask_ptr, job.renderer.?.mask.ptr);
                        try std.testing.expectEqual(bg_ptr, if (job.background) |bg| bg.pixels.ptr else null);
                        right -= width;
                    }
                    bottom -= height;
                }
            };
        }
        if (doc.pageCount() == 2) try std.testing.expectEqual(@as(usize, 1), doc.dictionary_decodes);
    }
}

test "invalid regions cannot overflow allocate or change a completed result" {
    var budget: Budget = .{ .parent = std.testing.allocator, .limit = 1024 * 1024 };
    {
        var doc = try Document.open(budget.allocator(), @embedFile("../fixtures/shared.djvu"), .{});
        defer doc.deinit();
        const before = budget.live;
        const g = try doc.geometry(0, .{ .subsample = 3, .rotation = 1 });
        try std.testing.expectEqual(@as(u32, 34), g.width);
        try std.testing.expectEqual(@as(u32, 54), g.height);
        try std.testing.expectEqual(before, budget.live);
        try std.testing.expect(!doc.busy);
        const invalid = [_]Region{
            .{ .x = 0, .y = 0, .width = 0, .height = 1 },
            .{ .x = 0, .y = 0, .width = 1, .height = 0 },
            .{ .x = 160, .y = 0, .width = 1, .height = 1 },
            .{ .x = 0, .y = 100, .width = 1, .height = 1 },
            .{ .x = 159, .y = 99, .width = 2, .height = 1 },
            .{ .x = 0, .y = 99, .width = 1, .height = 2 },
            .{ .x = std.math.maxInt(u32), .y = 0, .width = 2, .height = 1 },
            .{ .x = 1, .y = 1, .width = std.math.maxInt(u32), .height = std.math.maxInt(u32) },
        };
        for (invalid) |region| {
            try std.testing.expectError(error.InvalidArgument, Job.init(&doc, 0, .{ .region = region }));
            try std.testing.expect(!doc.busy);
            try std.testing.expectEqual(before, budget.live);
        }
        var job = try Job.init(&doc, 0, .{ .region = .{ .x = 3, .y = 7, .width = 2, .height = 2 } });
        defer job.deinit();
        try finish(&job, 4096);
        const original = (try job.pixels())[0..16].*;
        const live = budget.live;
        for (invalid) |region| {
            try std.testing.expectError(error.InvalidArgument, job.restart(.{ .region = region }));
            try std.testing.expectEqual(live, budget.live);
            try std.testing.expectEqualSlices(u8, &original, try job.pixels());
            try std.testing.expectEqual(@as(u32, 3), (try job.geometry()).x);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), budget.live);
}

test "large page tiles fit 64 MiB and failed growth preserves the last tile" {
    var budget: Budget = .{ .parent = std.testing.allocator, .limit = 64 * 1024 * 1024 };
    {
        var doc = try Document.open(budget.allocator(), @embedFile("../fixtures/large-page.djvu"), .{});
        defer doc.deinit();
        var job = try Job.init(&doc, 0, .{ .region = .{ .x = 0, .y = 0, .width = 256, .height = 256 } });
        defer job.deinit();
        try finish(&job, 4096);
        const g = try job.geometry();
        try std.testing.expectEqual(@as(u32, 8192), g.page_width);
        try std.testing.expectEqual(@as(u32, 6144), g.page_height);
        try std.testing.expectEqual(@as(usize, 256 * 256 * 4), (try job.pixels()).len);
        const live = budget.live;
        try std.testing.expect(budget.peak < 8 * 1024 * 1024);
        try std.testing.expectError(error.OutOfMemory, job.restart(.{}));
        try std.testing.expectEqual(live, budget.live);
        for (0..256) |y| for (0..256) |x| {
            const expected: u8 = if (x < 16 and y < 16) 0 else 255;
            try std.testing.expectEqualSlices(
                u8,
                &.{ expected, expected, expected, 255 },
                (try job.pixels())[(y * 256 + x) * 4 ..][0..4],
            );
        };
        const mask_ptr = job.renderer.?.mask.ptr;
        try job.restart(.{ .region = .{ .x = 8192 - 256, .y = 6144 - 256, .width = 256, .height = 256 } });
        try finish(&job, 4096);
        try std.testing.expectEqual(live, budget.live);
        try std.testing.expectEqual(mask_ptr, job.renderer.?.mask.ptr);
        for (0..256) |y| for (0..256) |x| {
            const expected: u8 = if (x >= 240 and y >= 240) 0 else 255;
            try std.testing.expectEqual(expected, (try job.pixels())[(y * 256 + x) * 4]);
        };
    }
    try std.testing.expectEqual(@as(usize, 0), budget.live);
}

test "tile cancellation hides partial filter output and cache eviction preserves pixels" {
    var doc = try Document.open(std.testing.allocator, @embedFile("../fixtures/shared.djvu"), .{});
    defer doc.deinit();
    const options: composite.Options = .{ .subsample = 3, .rotation = 3, .region = .{ .x = 3, .y = 5, .width = 7, .height = 9 } };
    var expected: [7 * 9 * 4]u8 = undefined;
    {
        var job = try Job.init(&doc, 0, options);
        defer job.deinit();
        try finish(&job, 4096);
        @memcpy(&expected, try job.pixels());
        try job.restart(options);
        try std.testing.expectEqual(.progress, try job.step(1));
        const partial = job.renderer.?.sample;
        try std.testing.expect(partial > 0 and partial < options.subsample * options.subsample);
        job.cancel();
        try std.testing.expectError(error.Cancelled, job.pixels());
        try std.testing.expectError(error.Cancelled, job.step(1));
    }
    for ([_]bool{ false, true }) |evict| {
        if (evict) try doc.dropDictionaries();
        var job = try Job.init(&doc, 0, options);
        defer job.deinit();
        try finish(&job, 71);
        try std.testing.expectEqualSlices(u8, &expected, try job.pixels());
    }
    try std.testing.expectEqual(@as(usize, 2), doc.dictionary_decodes);
}

test "allocation failures during cold tiles and resized restarts release all ownership" {
    for ([_][]const u8{
        @embedFile("../fixtures/shared.djvu"),
        @embedFile("../fixtures/compound.djvu"),
        @embedFile("../fixtures/foreground.djvu"),
    }) |bytes|
        try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
            fn run(a: std.mem.Allocator, input: []const u8) !void {
                var doc = try Document.open(a, input, .{});
                defer doc.deinit();
                var job = try Job.init(&doc, 0, .{ .region = .{ .x = 3, .y = 5, .width = 2, .height = 3 } });
                defer job.deinit();
                try finish(&job, 4096);
                try job.restart(.{});
                try finish(&job, 4096);
                try job.restart(.{ .rotation = 2, .region = .{ .x = 1, .y = 7, .width = 3, .height = 2 } });
                try finish(&job, 4096);
            }
        }.run, .{bytes});
}
