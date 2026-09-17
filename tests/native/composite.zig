const std = @import("std");
const composite = @import("../../src/composite.zig");
const geometry = @import("../../src/geometry.zig");
const jb2 = @import("../../src/jb2.zig");
const Pixmap = @import("../../src/pixmap.zig").Pixmap;
const Bitmap = @import("../../src/pixmap.zig").Bitmap;
const Palette = @import("../../src/color.zig").Palette;
const Info = @import("../../src/iff.zig").Info;
const a = std.testing.allocator;

fn packedShape(width: u32, height: u32, pixels: []const u8) !jb2.Shape {
    std.debug.assert(pixels.len == @as(usize, width) * height);
    const stride = (width + 7) / 8;
    const bits = try a.alloc(u8, @as(usize, stride) * height);
    @memset(bits, 0);
    for (pixels, 0..) |pixel, i| bits[i / width * stride + i % width / 8] |= pixel << @intCast(i % width % 8);
    // Dirty padding must never become visible ink when shifting or clipping.
    if (width % 8 != 0) for (0..height) |y| {
        bits[y * stride + stride - 1] |= @as(u8, 255) << @intCast(width % 8);
    };
    return .{ .width = width, .height = height, .pixels = bits };
}

fn finish(renderer: *composite.Renderer, work: usize) !void {
    for (0..1_000_000) |_| if (try renderer.step(work)) return;
    return error.TestWorkLimit;
}

fn finishScalar(renderer: *composite.Renderer, work: usize) !void {
    // Reference pixels use scalar four-neighbour interpolation and area weights.
    // Select it before workspace is allocated, so the helper cannot orphan a plan.
    std.debug.assert(renderer.rows == .unselected or renderer.rows == .scalar);
    renderer.rows = .scalar;
    try finish(renderer, work);
}

fn supplyRegion(target: *Pixmap, full: Pixmap, region: composite.Region) void {
    target.region = region;
    for (0..region.height) |y| {
        const source = full.row(@intCast(region.y + y))[region.x..][0..region.width];
        @memcpy(target.pixels[y * region.width ..][0..region.width], source);
    }
}

test "packed mask spans exclude neighboring bits at every alignment and allocation tail" {
    const readBits = @import("../../src/mask_rows.zig").readBits;
    var bytes: [17]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i * 137 + 93);
    for (1..bytes.len + 1) |size| {
        for (0..size * 8) |first| {
            var expected: u64 = 0;
            for (0..@min(64, size * 8 - first)) |offset| {
                const index = first + offset;
                const bit = (bytes[index / 8] >> @as(u3, @intCast(index % 8))) & 1;
                expected |= @as(u64, bit) << @as(u6, @intCast(offset));
                try std.testing.expectEqual(expected, readBits(bytes[0..size], first, @intCast(offset + 1)));
            }
        }
    }
    try std.testing.expectEqual(@as(u64, 0), readBits(&.{}, 137, 64));
}

test "mask rows preserve exact coverage through empty bands wide windows rotations and crops" {
    for ([_]u32{ 71, 993, 1103 }) |width| {
        const height = 97;
        const bytes = try a.alloc(u8, (width * height + 7) / 8);
        defer a.free(bytes);
        const bitmap: Bitmap = .{ .width = width, .height = height, .pixels = bytes };
        const info: Info = .{ .width = width, .height = height, .dpi = 300, .rotation = 0 };
        for (0..4) |pattern| {
            // Leave padding bits set: neither empty-row detection nor coverage
            // may read them. Sparse ink includes blank bands and both page edges.
            @memset(bytes, 255);
            for (0..width * height) |i| {
                const x = i % width;
                const y = i / width;
                const ink = switch (pattern) {
                    0 => false,
                    1 => true,
                    2 => (x + y) % 2 == 0,
                    else => i == 0 or i + 1 == width * height or
                        (y % 11 < 5 and x >= width / 4 and x < width * 3 / 4 and (x + y) % 7 < 2),
                };
                if (!ink) bytes[i / 8] &= ~(@as(u8, 1) << @intCast(i % 8));
            }
            var actual = try composite.Renderer.init(a, info, .{}, .{ .mask = .{ .bitmap = &bitmap } });
            defer actual.deinit();
            var reference = try composite.Renderer.init(a, info, .{}, .{ .mask = .{ .bitmap = &bitmap } });
            defer reference.deinit();
            for ([_]u32{ 16, 49 }) |output_width| for (0..4) |turn| {
                var options: composite.Options = .{
                    .size = if (turn & 1 == 0)
                        .{ .width = output_width, .height = height }
                    else
                        .{ .width = height, .height = output_width },
                    .rotation = @intCast(turn),
                };
                try actual.restart(options);
                try reference.restart(options);
                try std.testing.expect(!try actual.step(1));
                try std.testing.expect(actual.rows == .mask);
                const work = ([_]usize{ if (width == 71) 1 else 7, 17, 127, 4096 })[turn];
                try finish(&actual, work);
                try finishScalar(&reference, 4096);
                try std.testing.expectEqualSlices(u8, reference.rgba, actual.rgba);
                try std.testing.expect(actual.rows == .unselected);

                const g = actual.geometry;
                const region: composite.Region = .{
                    .x = @intFromBool(g.width > 2),
                    .y = @intFromBool(g.height > 2),
                    .width = if (g.width > 2) g.width - 2 else g.width,
                    .height = if (g.height > 2) g.height - 2 else g.height,
                };
                options.region = region;
                try actual.restart(options);
                try finish(&actual, 7);
                for (0..region.height) |y| {
                    const offset = ((region.y + y) * g.width + region.x) * 4;
                    try std.testing.expectEqualSlices(u8, reference.rgba[offset..][0 .. region.width * 4], actual.rgba[y * region.width * 4 ..][0 .. region.width * 4]);
                }
            };
        }
    }
}

test "mask row allocation failures and interrupted restarts release workspace" {
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var bytes = [_]u8{0x99} ** ((131 * 97 + 7) / 8);
            const bitmap: Bitmap = .{ .width = 131, .height = 97, .pixels = &bytes };
            const info: Info = .{ .width = 131, .height = 97, .dpi = 300, .rotation = 0 };
            var renderer = try composite.Renderer.init(allocator, info, .{ .size = .{ .width = 79, .height = 63 } }, .{ .mask = .{ .bitmap = &bitmap } });
            defer renderer.deinit();
            try std.testing.expect(!try renderer.step(31));
            try std.testing.expect(renderer.rows == .mask);
            try renderer.restart(.{ .size = .{ .width = 65, .height = 41 }, .rotation = 1 });
            try finish(&renderer, 7);
            try renderer.restart(.{});
            try finish(&renderer, 127);
        }
    }.run, .{});
}

test "row interpolation reciprocal matches division over every supported numerator" {
    const Layer = @import("../../src/composite_rows.zig").Layer;
    var pixels = [_][3]u8{.{ 255, 255, 255 }};
    const image: Pixmap = .{ .width = 1, .height = 1, .pixels = &pixels };
    for (1..13) |r| {
        var layer = try Layer.init(a, &image, @intCast(r), .{ .x = 0, .y = 0, .width = 1, .height = 1 });
        defer layer.deinit(a);
        const divisor = 4 * r * r;
        for (0..255 * divisor + divisor / 2 + 1) |value| {
            try std.testing.expectEqual(@as(u8, @intCast(value / divisor)), layer.normalize(@intCast(value)));
        }
    }
}

test "row workspace failures and incomplete row restarts release every allocation" {
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var pixels: [33 * 25][3]u8 = undefined;
            for (&pixels, 0..) |*rgb, i| rgb.* = .{ @truncate(i * 13), @truncate(i * 37), @truncate(i * 7) };
            const bg: Pixmap = .{ .width = 33, .height = 25, .pixels = &pixels };
            const info: Info = .{ .width = 131, .height = 97, .dpi = 300, .rotation = 0 };
            var renderer = try composite.Renderer.init(allocator, info, .{ .size = .{ .width = 79, .height = 63 } }, .{ .background = &bg });
            defer renderer.deinit();
            try finish(&renderer, 7);
            try renderer.restart(.{ .rotation = 1 });
            try std.testing.expect(!try renderer.step(31));
            try renderer.restart(.{ .size = .{ .width = 63, .height = 79 }, .rotation = 1 });
            try finish(&renderer, 127);
        }
    }.run, .{});
}

test "regional color layers resume together across scaling gamma rotation and restart" {
    const width = 71;
    const height = 53;
    var mask_pixels = [_]u8{0x5a} ** ((width * height + 7) / 8);
    const mask: Bitmap = .{ .width = width, .height = height, .pixels = &mask_pixels };
    const info: Info = .{ .width = width, .height = height, .dpi = 300, .rotation = 1, .gamma_tenths = 16 };
    const scales = [_]composite.Options{
        .{},
        .{ .subsample = 7 },
        .{ .size = .{ .width = 11, .height = 8 } },
        .{ .size = .{ .width = 29, .height = 23 } },
        .{ .size = .{ .width = 142, .height = 106 } },
        .{ .size = .{ .width = 1, .height = 1 } },
    };
    for ([_]u32{ 1, 3 }) |bg_reduction| {
        const reductions = [_]u32{ bg_reduction, 4 - bg_reduction };
        var full_pixels: [2][width * height][3]u8 = undefined;
        var partial_pixels: [2][width * height][3]u8 = undefined;
        var full: [2]Pixmap = undefined;
        var partial: [2]Pixmap = undefined;
        for (&full, &partial, reductions, 0..) |*source, *target, reduction, channel| {
            const w = (width + reduction - 1) / reduction;
            const h = (height + reduction - 1) / reduction;
            source.* = .{ .width = w, .height = h, .pixels = full_pixels[channel][0 .. w * h] };
            target.* = .{
                .width = w,
                .height = h,
                .pixels = partial_pixels[channel][0 .. w * h],
                .region = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            };
            for (source.pixels, 0..) |*rgb, i| {
                rgb.* = .{ @intCast((i * 37 + channel * 19) % 256), @intCast(i * 13 % 256), @intCast(i * 3 % 256) };
            }
        }
        // Exercise each regional layer alone, then both with different reductions.
        for (0..3) |kind| {
            const layers: composite.Layers = .{
                .mask = .{ .bitmap = &mask },
                .background = if (kind == 1) &full[0] else &partial[0],
                .foreground = if (kind == 0) &full[1] else &partial[1],
            };
            var actual = try composite.Renderer.init(a, info, .{}, layers);
            defer actual.deinit();
            var reference = try composite.Renderer.init(a, info, .{}, .{
                .mask = .{ .bitmap = &mask },
                .background = &full[0],
                .foreground = &full[1],
            });
            defer reference.deinit();
            for (scales) |scale| for (0..4) |turn| {
                var options = scale;
                options.rotation = @intCast(turn);
                try actual.restart(options);
                try reference.restart(options);
                try finishScalar(&reference, 4096);
                for (0..100_000) |_| {
                    if (try actual.step(([_]usize{ 1, 2, 7, 4096 })[turn])) break;
                    if (actual.needed) |source| {
                        for ([_]?*const Pixmap{ layers.background, layers.foreground }, 0..) |layer, i| {
                            if (layer.?.region == null) continue;
                            const needed = composite.layerRegion(info, &full[i], reductions[i], source);
                            if (!partial[i].contains(needed)) {
                                supplyRegion(&partial[i], full[i], needed);
                                // Match the job's post-refill classification:
                                // a partial first output row already owns sums.
                                if (actual.canClassifyLayer()) actual.classifyLayer(i);
                            }
                        }
                    }
                } else return error.TestWorkLimit;
                try std.testing.expectEqualSlices(u8, reference.rgba, actual.rgba);
            };
        }
    }
}

test "symbol row rasterization clips placements preserves palette order and charges skipped work" {
    const width = 19;
    const height = 13;
    var image: jb2.Image = .{ .width = width, .height = height };
    defer image.deinit(a);
    var pixels: [13 * 5]u8 = undefined;
    for (&pixels, 0..) |*bit, i| bit.* = @intFromBool((i * 3 + i / 13) % 7 < 3);
    try image.shapes.append(a, try packedShape(13, 5, &pixels));
    try image.shapes.append(a, try packedShape(1, 7, &.{ 1, 1, 0, 1, 0, 1, 1 }));
    try image.shapes.append(a, try packedShape(0, 3, &.{}));
    try image.blits.appendSlice(a, &.{
        .{ .shape = 0, .left = -5, .bottom = -2 },
        .{ .shape = 0, .left = 8, .bottom = 7 },
        .{ .shape = 0, .left = 1, .bottom = 3 },
        .{ .shape = 0, .left = -20, .bottom = 4 },
        .{ .shape = 0, .left = 20, .bottom = 1 },
        .{ .shape = 0, .left = 5, .bottom = -7 },
        .{ .shape = 0, .left = 3, .bottom = 15 },
        .{ .shape = 1, .left = 0, .bottom = 0 },
        .{ .shape = 1, .left = 18, .bottom = 6 },
        .{ .shape = 2, .left = 17, .bottom = 3 },
    });
    var colors = [_][3]u8{ .{ 31, 137, 229 }, .{ 183, 59, 101 }, .{ 113, 211, 17 } };
    var indices = [_]u16{ 0, 1, 2, 1, 2, 0, 2, 1, 0, 1 };
    const palette: Palette = .{ .colors = &colors, .indices = &indices };
    var expected = [_]u8{255} ** (width * height * 4);
    var raster_work: usize = 1; // End of the placement list.
    for (image.blits.items, indices) |blit, palette_index| {
        const shape = image.shape(blit.shape);
        raster_work += shape.pixelCount() + 1;
        for (0..shape.height) |sy| for (0..shape.width) |sx| {
            const x = blit.left + @as(i64, @intCast(sx));
            const y = blit.bottom + @as(i64, @intCast(sy));
            if (x < 0 or y < 0 or x >= width or y >= height or shape.get(@intCast(sx), @intCast(sy)) == 0) continue;
            const i = ((height - 1 - @as(usize, @intCast(y))) * width + @as(usize, @intCast(x))) * 4;
            expected[i..][0..3].* = colors[palette_index];
        };
    }
    const info: Info = .{ .width = width, .height = height, .dpi = 300, .rotation = 0 };
    for ([_]usize{ 1, 2, 7, 127, 4096 }) |work| {
        var renderer = try composite.Renderer.init(a, info, .{}, .{ .mask = .{ .symbols = &image }, .palette = &palette });
        defer renderer.deinit();
        if (work == 4096) {
            try std.testing.expect(!try renderer.step(raster_work - 1));
            try std.testing.expect(!renderer.rasterized);
            try std.testing.expect(!try renderer.step(1));
            try std.testing.expect(renderer.rasterized);
        }
        try finish(&renderer, work);
        try std.testing.expectEqualSlices(u8, &expected, renderer.rgba);
    }
}

test "color row spans preserve scalar samples through clipping gamma rotations and restart" {
    const width = 71;
    const height = 53;
    var image: jb2.Image = .{ .width = width, .height = height };
    defer image.deinit(a);
    var ink: [width * height]u8 = undefined;
    for (&ink, 0..) |*value, i| value.* = @intFromBool((i * 7 + i / width * 3) % 17 < 6);
    try image.shapes.append(a, try packedShape(width, height, &ink));
    try image.blits.appendSlice(a, &.{
        .{ .shape = 0, .left = 0, .bottom = 0 },
        .{ .shape = 0, .left = 13, .bottom = -5 },
        .{ .shape = 0, .left = -11, .bottom = 7 },
    });
    var colors = [_][3]u8{ .{ 31, 137, 229 }, .{ 183, 59, 101 }, .{ 113, 211, 17 } };
    var indices = [_]u16{ 0, 1, 2 };
    const palette: Palette = .{ .colors = &colors, .indices = &indices };
    const scales = [_]composite.Options{
        .{},
        .{ .subsample = 2 },
        .{ .subsample = 3 },
        .{ .subsample = 7 },
        .{ .subsample = 256 },
        .{ .size = .{ .width = 1, .height = 1 } },
        .{ .size = .{ .width = 13, .height = 11 } },
        .{ .size = .{ .width = 23, .height = 18 } },
        .{ .size = .{ .width = 24, .height = 18 } },
        .{ .size = .{ .width = 55, .height = 41 } },
        .{ .size = .{ .width = 142, .height = 106 } },
    };
    for ([_]u32{ 1, 2, 3, 4, 7, 8, 12 }) |reduction| {
        const bg_width = (width + reduction - 1) / reduction;
        const bg_height = (height + reduction - 1) / reduction;
        const fg_reduction = 13 - reduction;
        const fg_width = (width + fg_reduction - 1) / fg_reduction;
        const fg_height = (height + fg_reduction - 1) / fg_reduction;
        const bg_pixels = try a.alloc([3]u8, bg_width * bg_height);
        defer a.free(bg_pixels);
        const fg_pixels = try a.alloc([3]u8, fg_width * fg_height);
        defer a.free(fg_pixels);
        for (bg_pixels, 0..) |*rgb, i| rgb.* = .{ @intCast(i * 37 % 256), @intCast(i * 13 % 256), @intCast(i * 3 % 256) };
        for (fg_pixels, 0..) |*rgb, i| rgb.* = .{ @intCast(i * 11 % 256), @intCast(i * 47 % 256), @intCast(i * 23 % 256) };
        const bg: Pixmap = .{ .width = bg_width, .height = bg_height, .pixels = bg_pixels };
        const fg: Pixmap = .{ .width = fg_width, .height = fg_height, .pixels = fg_pixels };
        for ([_]u8{ 16, 22 }) |gamma| for ([_]bool{ false, true }) |palette_fg| {
            const info: Info = .{ .width = width, .height = height, .dpi = 300, .rotation = 1, .gamma_tenths = gamma };
            const layers: composite.Layers = .{
                .mask = .{ .symbols = &image },
                .background = &bg,
                .foreground = if (palette_fg) null else &fg,
                .palette = if (palette_fg) &palette else null,
            };
            var actual = try composite.Renderer.init(a, info, .{}, layers);
            defer actual.deinit();
            var reference = try composite.Renderer.init(a, info, .{}, layers);
            defer reference.deinit();
            try finish(&actual, 4096);
            try finishScalar(&reference, 1);
            for (scales) |scale| for (0..4) |turn| {
                var options = scale;
                options.rotation = @intCast(turn);
                try actual.restart(options);
                try reference.restart(options);
                // Keep the reference on scalar sampling while the selected
                // path suspends within rows and writes rotated output.
                try finishScalar(&reference, 1);
                try finish(&actual, ([_]usize{ 1, 17, 127, 4096 })[turn]);
                try std.testing.expectEqualSlices(u8, reference.rgba, actual.rgba);
                const g = reference.geometry;
                const regions = [_]composite.Region{
                    .{ .x = g.width / 3, .y = g.height / 4, .width = @max(1, g.width / 2), .height = @max(1, g.height / 2) },
                    // Keep enough source columns to exercise row filtering in
                    // cropped output as well as the small-region fallback.
                    .{ .x = @intFromBool(g.width > 2), .y = @intFromBool(g.height > 2), .width = if (g.width > 2) g.width - 2 else g.width, .height = if (g.height > 2) g.height - 2 else g.height },
                };
                for (regions) |region| {
                    options.region = region;
                    try actual.restart(options);
                    try finish(&actual, 3);
                    for (0..region.height) |y| {
                        const start = ((region.y + y) * g.width + region.x) * 4;
                        try std.testing.expectEqualSlices(
                            u8,
                            reference.rgba[start..][0 .. region.width * 4],
                            actual.rgba[y * region.width * 4 ..][0 .. region.width * 4],
                        );
                    }
                }
            };
        };
    }
}

test "masked color spans preserve interpolation across dense sparse and empty groups" {
    const Foreground = enum { solid, palette, sampled, sampled_on_white };
    const width = 257;
    const height = 17;
    var image: jb2.Image = .{ .width = width, .height = height };
    defer image.deinit(a);
    var ink: [width * height]u8 = undefined;
    for (&ink, 0..) |*value, i| {
        const x = i % width;
        value.* = @intFromBool(switch ((x / 64 + i / width / 5) % 4) {
            0 => true,
            1 => false,
            2 => x % 2 == 0,
            else => x % 17 == 0,
        });
    }
    try image.shapes.append(a, try packedShape(width, height, &ink));
    try image.blits.appendSlice(a, &.{
        .{ .shape = 0, .left = 0, .bottom = 0 },
        .{ .shape = 0, .left = 0, .bottom = -11 },
    });
    var colors = [_][3]u8{ .{ 19, 83, 201 }, .{ 223, 73, 11 } };
    var indices = [_]u16{ 0, 1 };
    for ([_]u32{ 1, 3, 4, 8, 12 }) |reduction| {
        const bg_width = (width + reduction - 1) / reduction;
        const bg_height = (height + reduction - 1) / reduction;
        const pixels = try a.alloc([3]u8, bg_width * bg_height);
        defer a.free(pixels);
        for (pixels, 0..) |*rgb, i| rgb.* = .{ @truncate(i * 37), @truncate(i * 13), @truncate(i * 71) };
        const bg: Pixmap = .{ .width = bg_width, .height = bg_height, .pixels = pixels };
        // Different ratios make mask transitions exercise both interpolation phases.
        const fg_reduction = 13 - reduction;
        const fg_width = (width + fg_reduction - 1) / fg_reduction;
        const fg_height = (height + fg_reduction - 1) / fg_reduction;
        const fg_pixels = try a.alloc([3]u8, fg_width * fg_height);
        defer a.free(fg_pixels);
        for (fg_pixels, 0..) |*rgb, i| rgb.* = .{ @truncate(i * 83), @truncate(i * 19), @truncate(i * 7) };
        const fg: Pixmap = .{ .width = fg_width, .height = fg_height, .pixels = fg_pixels };
        for ([_]u8{ 16, 22 }) |gamma| for ([_]Foreground{ .solid, .palette, .sampled, .sampled_on_white }) |foreground| {
            const palette_fg = foreground == .palette;
            const sampled_fg = foreground == .sampled or foreground == .sampled_on_white;
            indices[1] = @intFromBool(palette_fg);
            const palette: Palette = .{ .colors = colors[0..if (palette_fg) 2 else 1], .indices = &indices };
            const info: Info = .{ .width = width, .height = height, .dpi = 300, .rotation = 0, .gamma_tenths = gamma };
            const layers: composite.Layers = .{
                .mask = .{ .symbols = &image },
                .background = if (foreground == .sampled_on_white) null else &bg,
                .foreground = if (sampled_fg) &fg else null,
                .palette = if (sampled_fg) null else &palette,
            };
            var actual = try composite.Renderer.init(a, info, .{}, layers);
            defer actual.deinit();
            var reference = try composite.Renderer.init(a, info, .{}, layers);
            defer reference.deinit();
            try finish(&actual, 4096);
            try finishScalar(&reference, 4096);
            try std.testing.expectEqualSlices(u8, reference.rgba, actual.rgba);
            for ([_]usize{ 1, 17, 64, 4096 }, 0..) |work, turn| {
                var options: composite.Options = .{
                    .size = if (turn & 1 == 0) .{ .width = 193, .height = 13 } else .{ .width = 13, .height = 193 },
                    .rotation = @intCast(turn),
                };
                try actual.restart(options);
                try reference.restart(options);
                try finish(&actual, work);
                try finishScalar(&reference, 4096);
                try std.testing.expectEqualSlices(u8, reference.rgba, actual.rgba);

                const g = actual.geometry;
                const region: composite.Region = .{ .x = 3, .y = 2, .width = g.width - 6, .height = g.height - 4 };
                options.region = region;
                try actual.restart(options);
                try finish(&actual, work);
                for (0..region.height) |y| {
                    const start = ((region.y + y) * g.width + region.x) * 4;
                    try std.testing.expectEqualSlices(u8, reference.rgba[start..][0 .. region.width * 4], actual.rgba[y * region.width * 4 ..][0 .. region.width * 4]);
                }
            }
        };
    }
}

test "constant layers match general composition through fractional scaling rotation and tiles" {
    // Odd rows cross every bit alignment. Equal palette entries force the
    // general per-pixel path to act as a reference for the same two colors.
    const width = 137;
    const height = 17;
    var image: jb2.Image = .{ .width = width, .height = height };
    defer image.deinit(a);
    var pixels: [width * height]u8 = undefined;
    for (&pixels, 0..) |*pixel, i| pixel.* = @intFromBool((i * 13 + i / width * 7) % 11 < 5);
    try image.shapes.append(a, try packedShape(width, height, &pixels));
    try image.blits.append(a, .{ .shape = 0, .left = 0, .bottom = 0 });
    var bg_pixels = [_][3]u8{.{ 237, 222, 198 }} ** (46 * 6);
    var fg_pixels = [_][3]u8{.{ 43, 91, 149 }} ** (20 * 3);
    const bg: Pixmap = .{ .width = 46, .height = 6, .pixels = &bg_pixels };
    const fg: Pixmap = .{ .width = 20, .height = 3, .pixels = &fg_pixels };
    var colors = [_][3]u8{fg_pixels[0]} ** 2;
    var indices = [_]u16{0};
    const palette: Palette = .{ .colors = colors[0..1], .indices = &indices };
    const repeated: Palette = .{ .colors = &colors, .indices = &indices };
    const scales = [_]composite.Options{
        .{},
        .{ .subsample = 2 },
        .{ .subsample = 3 },
        .{ .subsample = 7 },
        .{ .subsample = 8 },
        .{ .subsample = 63 },
        .{ .subsample = 64 },
        .{ .subsample = 65 },
        .{ .subsample = 128 },
        .{ .subsample = 256 },
        .{ .size = .{ .width = 1, .height = 1 } },
        .{ .size = .{ .width = 17, .height = 13 } },
        .{ .size = .{ .width = 93, .height = 71 } },
        .{ .size = .{ .width = width, .height = height } },
        .{ .size = .{ .width = height, .height = width } },
        .{ .size = .{ .width = 301, .height = 277 } },
    };
    for ([_]u8{ 16, 22 }) |gamma| for ([_]bool{ false, true }) |palette_fg| {
        const info: Info = .{ .width = width, .height = height, .dpi = 300, .rotation = 1, .gamma_tenths = gamma };
        var fast = try composite.Renderer.init(
            a,
            info,
            .{},
            .{
                .mask = .{ .symbols = &image },
                .background = &bg,
                .foreground = if (palette_fg) null else &fg,
                .palette = if (palette_fg) &palette else null,
            },
        );
        defer fast.deinit();
        var reference = try composite.Renderer.init(
            a,
            info,
            .{},
            .{ .mask = .{ .symbols = &image }, .background = &bg, .palette = &repeated },
        );
        defer reference.deinit();
        try finish(&fast, 1);
        try finishScalar(&reference, 127);
        try std.testing.expect(fast.plan == .solid and reference.plan == .general);
        for (scales) |scale| for (0..4) |turn| {
            var options = scale;
            options.rotation = @intCast(turn);
            try fast.restart(options);
            try reference.restart(options);
            try finish(&fast, 1);
            try finishScalar(&reference, 127);
            try std.testing.expectEqualSlices(u8, reference.rgba, fast.rgba);
            const g = reference.geometry;
            const region: composite.Region = .{
                .x = g.width / 3,
                .y = g.height / 4,
                .width = @max(1, g.width / 2),
                .height = @max(1, g.height / 2),
            };
            options.region = region;
            try fast.restart(options);
            try finish(&fast, 73);
            for (0..region.height) |y| {
                const start = ((region.y + y) * g.width + region.x) * 4;
                try std.testing.expectEqualSlices(
                    u8,
                    reference.rgba[start..][0 .. region.width * 4],
                    fast.rgba[y * region.width * 4 ..][0 .. region.width * 4],
                );
            }
        };
    };
}

test "packed mask reduction clips rows and allocation tails and keeps bilevel rounding" {
    for ([_]u32{ 1, 2, 7, 8, 9, 63, 64, 65, 137 }) |width| {
        const height = 9;
        const bytes = try a.alloc(u8, (width * height + 7) / 8);
        defer a.free(bytes);
        @memset(bytes, 255); // Padding bits must not contribute to coverage.
        for (0..width * height) |i| if ((i * 13 + i / width * 7) % 11 >= 5) {
            bytes[i / 8] &= ~(@as(u8, 1) << @intCast(i % 8));
        };
        const bitmap: Bitmap = .{ .width = width, .height = height, .pixels = bytes };
        const info: Info = .{ .width = width, .height = height, .dpi = 300, .rotation = 0 };
        var renderer = try composite.Renderer.init(a, info, .{}, .{ .mask = .{ .bitmap = &bitmap } });
        defer renderer.deinit();
        try finish(&renderer, 127);
        for ([_]u16{ 1, 2, 3, 7, 8, 63, 64, 65, 256 }) |ss| for (0..4) |turn| {
            const options: composite.Options = .{ .subsample = ss, .rotation = @intCast(turn) };
            try renderer.restart(options);
            try finish(&renderer, 1);
            const transform = try geometry.Transform.init(info, options);
            const area = @as(u32, ss) * ss;
            for (0..renderer.rgba.len / 4) |i| {
                var ink: u32 = 0;
                // Scalar bit reads deliberately avoid grouped loads/popcounts.
                for (0..area) |sample| {
                    const p = transform.sample(
                        @intCast(i % renderer.geometry.width),
                        @intCast(i / renderer.geometry.width),
                        @intCast(sample),
                    );
                    if (p[0] < 0 or p[1] < 0 or p[0] >= width or p[1] >= height) continue;
                    const bit = @as(usize, @intCast(p[1])) * width + @as(usize, @intCast(p[0]));
                    ink += (bytes[bit / 8] >> @as(u3, @intCast(bit % 8))) & 1;
                }
                const gray: u8 = @intCast(255 - (ink * 255 + area / 2) / area);
                try std.testing.expectEqualSlices(u8, &.{ gray, gray, gray, 255 }, renderer.rgba[i * 4 ..][0..4]);
            }
        };
    }
    // Exactly half ink: integer bilevel reduction and sized RGB reduction
    // deliberately round opposite ways, even for the same source rectangle.
    var bits = [_]u8{3};
    const bitmap: Bitmap = .{ .width = 2, .height = 2, .pixels = &bits };
    var renderer = try composite.Renderer.init(
        a,
        .{ .width = 2, .height = 2, .dpi = 300, .rotation = 0 },
        .{ .subsample = 2 },
        .{ .mask = .{ .bitmap = &bitmap } },
    );
    defer renderer.deinit();
    try finish(&renderer, 1);
    try std.testing.expectEqualSlices(u8, &.{ 127, 127, 127, 255 }, renderer.rgba);
    try renderer.restart(.{ .size = .{ .width = 1, .height = 1 } });
    try finish(&renderer, 1);
    try std.testing.expectEqualSlices(u8, &.{ 128, 128, 128, 255 }, renderer.rgba);
}

test "constant colors apply gamma before averaging coverage" {
    var bg_pixels = [_][3]u8{.{ 128, 128, 128 }} ** 2;
    var fg_pixels = [_][3]u8{.{ 64, 64, 64 }} ** 2;
    const bg: Pixmap = .{ .width = 2, .height = 1, .pixels = &bg_pixels };
    const fg: Pixmap = .{ .width = 2, .height = 1, .pixels = &fg_pixels };
    var bits = [_]u8{1};
    const bitmap: Bitmap = .{ .width = 2, .height = 1, .pixels = &bits };
    var renderer = try composite.Renderer.init(
        a,
        .{ .width = 2, .height = 1, .dpi = 300, .rotation = 0, .gamma_tenths = 11 },
        .{ .size = .{ .width = 1, .height = 1 } },
        .{ .background = &bg, .foreground = &fg, .mask = .{ .bitmap = &bitmap } },
    );
    defer renderer.deinit();
    try finish(&renderer, 1);
    // Gamma 1.1 -> 2.2 maps the samples to 181 and 128 before averaging.
    try std.testing.expectEqualSlices(u8, &.{ 155, 155, 155, 255 }, renderer.rgba);
}

test "uniform detection checks the final pixel incrementally and survives restart" {
    var pixels = [_][3]u8{.{ 131, 157, 173 }} ** (129 * 3);
    const bg: Pixmap = .{ .width = 129, .height = 3, .pixels = &pixels };
    for ([_]u8{ 131, 132 }) |last_red| {
        pixels[pixels.len - 1][0] = last_red;
        var renderer = try composite.Renderer.init(
            a,
            .{ .width = bg.width, .height = bg.height, .dpi = 300, .rotation = 0 },
            .{},
            .{ .background = &bg },
        );
        defer renderer.deinit();
        try std.testing.expect(!try renderer.step(1));
        try std.testing.expect(renderer.output_pixel == 0 and renderer.bg_color == .checking);
        try finish(&renderer, 1);
        try std.testing.expectEqual(last_red == 131, renderer.bg_color == .solid);
        try std.testing.expectEqualSlices(u8, &.{ last_red, 157, 173, 255 }, renderer.rgba[renderer.rgba.len - 4 ..]);
        try renderer.restart(.{ .region = .{ .x = 128, .y = 2, .width = 1, .height = 1 } });
        try std.testing.expect(try renderer.step(1)); // No second scan of the layer.
        try std.testing.expectEqualSlices(u8, &.{ last_red, 157, 173, 255 }, renderer.rgba);
    }
}

test "cancelling uniform layer classification hides output and frees the job" {
    const Document = @import("../../src/document.zig").Document;
    const Job = @import("../../src/job.zig").Job;
    // A valid 129x67 IW44 page with zero slices, hence a uniform decoded layer.
    const bytes = "AT&TFORM\x00\x00\x00\x28DJVU" ++
        "INFO\x00\x00\x00\x0a\x00\x81\x00\x43\x18\x00\x2c\x01\x16\x00" ++
        "BG44\x00\x00\x00\x09\x00\x00\x01\x02\x00\x81\x00\x43\x80\x00";
    var doc = try Document.open(a, bytes, .{});
    defer doc.deinit();
    var job = try Job.init(&doc, 0, .{});
    defer job.deinit();
    for (0..100_000) |_| {
        try std.testing.expectEqual(.progress, try job.step(1));
        if (job.renderer) |r| if (r.bg_color == .checking and r.bg_color.checking > 0) {
            try std.testing.expectError(error.Busy, job.pixels());
            try std.testing.expectEqual(@as(usize, 0), r.output_pixel);
            job.cancel();
            try std.testing.expectError(error.Cancelled, job.step(1));
            try std.testing.expectError(error.Cancelled, job.pixels());
            return;
        };
    }
    return error.TestWorkLimit;
}
