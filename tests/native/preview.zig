const std = @import("std");
const Job = @import("../../src/job.zig").Job;
const Document = @import("../../src/document.zig").Document;
const composite = @import("../../src/composite.zig");
const Pixmap = @import("../../src/pixmap.zig").Pixmap;
const Bitmap = @import("../../src/pixmap.zig").Bitmap;
const iw44 = @import("../../src/iw44.zig");
const a = std.testing.allocator;

// Force a reconstruction grid independently of the public automatic choice.
fn previewJob(doc: *Document, page: usize, options: composite.Options, limit: u32) !Job {
    var job = try Job.init(doc, page, options);
    job.preview_limit = limit;
    job.retain_preview_coefficients = true;
    return job;
}

fn finish(job: *Job, work: usize) !void {
    for (0..1_000_000) |_| if (try job.step(work) == .done) return;
    return error.TestWorkLimit;
}

// An independent, deliberately unoptimized reference: expand each compact cell
// to page pixels, then use the ordinary compositor with the original mask.
fn expand(image: Pixmap, width: u32, height: u32) !Pixmap {
    const pixels = try a.alloc([3]u8, @as(usize, width) * height);
    for (0..height) |y| for (0..width) |x| {
        const row = image.height - 1 - (height - 1 - y) / image.sample_step;
        pixels[y * width + x] = image.row(@intCast(row))[x / image.sample_step];
    };
    return .{ .width = width, .height = height, .pixels = pixels };
}

test "uniform compact grids ignore spare capacity but partial strips remain sampled" {
    var pixels = [_][3]u8{.{ 213, 197, 181 }} ** 100;
    @memset(pixels[80..], .{ 1, 2, 3 });
    var compact: Pixmap = .{
        .width = 10,
        .height = 8,
        .sample_step = 4,
        .region = .{ .x = 0, .y = 0, .width = 10, .height = 8 },
        .pixels = &pixels,
    };
    var bits = [_]u8{0x96} ** ((37 * 29 + 7) / 8);
    const mask: Bitmap = .{ .width = 37, .height = 29, .pixels = &bits };
    const info: @import("../../src/iff.zig").Info = .{ .width = 37, .height = 29, .dpi = 300, .rotation = 0, .gamma_tenths = 16 };
    const options: composite.Options = .{ .size = .{ .width = 7, .height = 7 } };
    var expanded = try expand(compact, info.width, info.height);
    defer expanded.deinit(a);
    var reference = try composite.Renderer.init(a, info, options, .{ .mask = .{ .bitmap = &mask }, .background = &expanded });
    defer reference.deinit();
    while (!try reference.step(4096)) {}
    var actual = try composite.Renderer.init(a, info, options, .{ .mask = .{ .bitmap = &mask }, .background = &compact });
    defer actual.deinit();
    while (!try actual.step(1)) {}
    try std.testing.expectEqualSlices(u8, reference.rgba, actual.rgba);
    try std.testing.expectEqual(.solid, actual.plan);

    try actual.restart(options);
    compact.region.?.height = 3;
    actual.classifyLayer(0);
    try std.testing.expectEqual(false, try actual.step(1));
    try std.testing.expectEqual(.general, actual.plan);
}

test "compact cells preserve exact mask coverage gamma and odd page boundaries" {
    const width = 77;
    const height = 59;
    var bits = [_]u8{0x96} ** ((width * height + 7) / 8);
    const mask: Bitmap = .{ .width = width, .height = height, .pixels = &bits };
    var compact: [2]Pixmap = undefined;
    var expanded: [2]Pixmap = undefined;
    for (&compact, &expanded, [_]u32{ 12, 20 }, 0..) |*small, *full, step, layer| {
        const w = (width + step - 1) / step;
        const h = (height + step - 1) / step;
        small.* = .{ .width = w, .height = h, .sample_step = step, .pixels = try a.alloc([3]u8, w * h) };
        for (small.pixels, 0..) |*rgb, i| rgb.* = .{ @intCast((i * 79 + layer * 41) % 256), @intCast(i * 13 % 256), @intCast(i * 107 % 256) };
        full.* = try expand(small.*, width, height);
    }
    defer for (&compact) |*image| image.deinit(a);
    defer for (&expanded) |*image| image.deinit(a);
    for ([_]u32{ 1, 7, 19, 101 }) |edge| for (0..8) |variant| {
        const turn = variant % 4;
        const selected_mask: @FieldType(composite.Layers, "mask") = if (variant < 4) .{ .bitmap = &mask } else null;
        const info: @import("../../src/iff.zig").Info = .{ .width = width, .height = height, .dpi = 300, .rotation = 1, .gamma_tenths = 16 };
        const options: composite.Options = .{ .size = .{ .width = edge, .height = edge }, .rotation = @intCast(turn) };
        var actual = try composite.Renderer.init(a, info, options, .{ .mask = selected_mask, .background = &compact[0], .foreground = &compact[1] });
        defer actual.deinit();
        var reference = try composite.Renderer.init(a, info, options, .{ .mask = selected_mask, .background = &expanded[0], .foreground = &expanded[1] });
        defer reference.deinit();
        while (!try reference.step(4096)) {}
        while (!try actual.step(if (turn == 0) 1 else 257)) {}
        try std.testing.expectEqualSlices(u8, reference.rgba, actual.rgba);
    };
}

fn checkReference(job: *Job) !void {
    var owned: [2]?Pixmap = .{ null, null };
    defer for (&owned) |*image| if (image.*) |*p| p.deinit(a);
    var layers = job.renderer.?.layers;
    for (&job.regional, 0..) |*slot, i| {
        const decoder = if (slot.*) |*d| d else continue;
        // Recover all cells independently of the renderer's regional cache.
        var copy = try iw44.Decoder.init(a, decoder.chunks, .{});
        defer copy.deinit();
        copy.retain_coefficients = true;
        while (!try copy.step(4096)) {}
        const r = job.iw44_reductions[i];
        try copy.reconstructReduced(r, .{ .x = 0, .y = 0, .width = decoder.image.?.width, .height = decoder.image.?.height });
        while (!try copy.step(4096)) {}
        var image = copy.image.?;
        image.sample_step = decoder.image.?.sample_step;
        owned[i] = if (image.sample_step != 0) try expand(image, job.info.width, job.info.height) else .{
            .width = image.width,
            .height = image.height,
            .pixels = try a.dupe([3]u8, image.pixels),
        };
        if (i == 0) layers.background = &owned[i].? else layers.foreground = &owned[i].?;
    }
    var reference = try composite.Renderer.init(a, job.info, job.options, layers);
    defer reference.deinit();
    while (!try reference.step(4096)) {}
    try std.testing.expectEqualSlices(u8, reference.rgba, try job.pixels());
}

test "preview jobs compose shared components palettes MMR foreground and mixed JPEG" {
    inline for (.{ "compound", "foreground", "shared-layers", "shared", "preview-shared", "palette-unmapped-bg", "mmr-palette-bg", "mmr-foreground", "jpeg-compound", "jpeg-mmr", "iw44-reduced-half", "gamma", "rotated-color" }) |name| {
        var doc = try Document.open(a, @embedFile("../fixtures/" ++ name ++ ".djvu"), .{});
        defer doc.deinit();
        const options: composite.Options = .{ .size = .{ .width = 3, .height = 3 }, .rotation = 1 };
        var ordinary = try Job.init(&doc, 0, options);
        try finish(&ordinary, 4096);
        try checkReference(&ordinary);
        const expected = try a.dupe(u8, try ordinary.pixels());
        defer a.free(expected);
        const limit = ordinary.preview_limit orelse 1;
        ordinary.deinit();
        var exact = try previewJob(&doc, 0, options, limit);
        try finish(&exact, 4096);
        try std.testing.expectEqualSlices(u8, expected, try exact.pixels());
        exact.deinit();
        var reduced = try previewJob(&doc, 0, options, 8);
        defer reduced.deinit();
        try finish(&reduced, 7);
        try checkReference(&reduced);
        if (std.mem.eql(u8, name, "foreground")) try std.testing.expectEqualSlices(u32, &.{ 4, 1 }, &reduced.iw44_reductions);
        if (std.mem.eql(u8, name, "shared")) try std.testing.expect(doc.dictionary_decodes > 0);
    }
}

test "preview restarts change compact grids and preserve crop origins and completed images on error" {
    var doc = try Document.open(a, @embedFile("../fixtures/iw44-reduced-full.djvu"), .{});
    defer doc.deinit();
    var job = try previewJob(&doc, 0, .{ .size = .{ .width = 32, .height = 32 } }, 8);
    defer job.deinit();
    try finish(&job, 4096);
    const original = try a.dupe(u8, try job.pixels());
    defer a.free(original);
    try std.testing.expectEqual(@as(u32, 4), job.iw44_reductions[0]);
    try std.testing.expectError(error.InvalidArgument, job.restart(.{ .subsample = 0 }));
    try std.testing.expectError(error.InvalidArgument, job.restart(.{ .size = .{ .width = 0, .height = 0 } }));
    try std.testing.expectEqualSlices(u8, original, try job.pixels());
    for ([_]u32{ 128, 4, 32 }) |edge| for (0..4) |turn| {
        const options: composite.Options = .{ .size = .{ .width = edge, .height = edge }, .rotation = @intCast(turn) };
        try job.restart(options);
        try finish(&job, 37);
        try checkReference(&job);
        const g = try job.geometry();
        const full = try a.dupe(u8, try job.pixels());
        defer a.free(full);
        var crop = options;
        crop.region = .{ .x = 1, .y = 1, .width = g.width - 1, .height = g.height - 1 };
        try job.restart(crop);
        try finish(&job, 1);
        for (0..g.height - 1) |y| try std.testing.expectEqualSlices(u8, full[((y + 1) * g.width + 1) * 4 ..][0 .. (g.width - 1) * 4], (try job.pixels())[y * (g.width - 1) * 4 ..][0 .. (g.width - 1) * 4]);
    };
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var doc = try Document.open(allocator, @embedFile("../fixtures/compound.djvu"), .{});
    defer doc.deinit();
    var job = try Job.init(&doc, 0, .{ .size = .{ .width = 3, .height = 3 } });
    defer job.deinit();
    try finish(&job, 4096);
    try job.restart(.{ .size = .{ .width = 7, .height = 7 } });
    try finish(&job, 4096);
}

test "preview allocation failures release masks palettes coefficients and regional buffers" {
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{});
}

test "automatic masked previews recognize a uniform reduced background" {
    const original = @embedFile("../fixtures/large-page.djvu");
    var bytes: [original.len + 18]u8 = undefined;
    @memcpy(bytes[0..original.len], original);
    std.mem.writeInt(u32, bytes[8..12], bytes.len - 12, .big);
    @memcpy(bytes[original.len..], "BG44\x00\x00\x00\x09\x00\x00\x01\x02\x00\x00\x00\x00\x80\x00");
    std.mem.writeInt(u16, bytes[original.len + 12 ..][0..2], 1024, .big);
    std.mem.writeInt(u16, bytes[original.len + 14 ..][0..2], 768, .big);
    var doc = try Document.open(a, &bytes, .{});
    defer doc.deinit();
    const info = try doc.info(0);
    try std.testing.expect(@as(u64, info.width) * info.height > 8 * 1024 * 1024);
    var masked = try Job.init(&doc, 0, .{ .size = .{ .width = 32, .height = 32 } });
    defer masked.deinit();
    try std.testing.expectEqual(@as(?u32, 4), masked.preview_limit);
    try finish(&masked, 4096);
    try std.testing.expectEqual(@as(u32, 4), masked.iw44_reductions[0]);
    try std.testing.expectEqual(.solid, masked.renderer.?.plan);
}

test "small automatic previews select by fitted geometry regardless of cache history" {
    inline for (.{ "iw44-reduced-full", "iw44-reduced-half", "iw44-reduced-gray" }) |name| {
        var budget: @import("../../src/budget.zig").Budget = .{ .parent = a, .limit = 4 * 1024 * 1024 };
        {
            var doc = try Document.open(budget.allocator(), @embedFile("../fixtures/" ++ name ++ ".djvu"), .{});
            defer doc.deinit();
            // Exact first: keep the small RGB cache until a reduced view is requested.
            var job = try Job.init(&doc, 0, .{});
            defer job.deinit();
            try finish(&job, 4096);
            try std.testing.expect(job.background != null and job.regional[0] == null);
            const full = try a.dupe(u8, try job.pixels());
            defer a.free(full);
            try job.restart(.{ .size = .{ .width = 65, .height = 65 } });
            try finish(&job, 4096);
            try std.testing.expect(job.background != null and job.regional[0] == null);
            var retained: usize = 0;
            for (0..2) |cycle| {
                for ([_]u32{ 32, 33, 64, 65, 128, 256, 1 }, [_]u32{ 4, 2, 2, 1, 1, 1, 4 }) |edge, reduction| {
                    try job.restart(.{ .size = .{ .width = edge, .height = edge } });
                    try finish(&job, 37);
                    try std.testing.expectEqual(reduction, job.iw44_reductions[0]);
                    try checkReference(&job);
                    // A fresh job must choose the same filter as a migrated cache.
                    var fresh_doc = try Document.open(a, @embedFile("../fixtures/" ++ name ++ ".djvu"), .{});
                    defer fresh_doc.deinit();
                    var fresh = try Job.init(&fresh_doc, 0, job.options);
                    defer fresh.deinit();
                    try finish(&fresh, 4096);
                    try std.testing.expectEqualSlices(u8, try fresh.pixels(), try job.pixels());
                }
                try job.restart(.{});
                try finish(&job, 4096);
                try std.testing.expectEqualSlices(u8, full, try job.pixels());
                if (cycle == 0) retained = budget.live else try std.testing.expectEqual(retained, budget.live);
            }
        }
        try std.testing.expectEqual(@as(usize, 0), budget.live);
    }
}

test "automatic compound previews promote layers independently and preserve masks and palettes" {
    inline for (.{ "foreground", "mmr-foreground", "compound", "preview-shared", "shared-layers", "palette-unmapped-bg", "mmr-palette-bg", "jpeg-background", "jpeg-foreground" }) |name| {
        const bytes = @embedFile("../fixtures/" ++ name ++ ".djvu");
        var budget: @import("../../src/budget.zig").Budget = .{ .parent = a, .limit = 4 * 1024 * 1024 };
        {
            var doc = try Document.open(budget.allocator(), bytes, .{});
            defer doc.deinit();
            var job = try Job.init(&doc, 0, .{});
            defer job.deinit();
            try finish(&job, 4096);
            const full = try a.dupe(u8, try job.pixels());
            defer a.free(full);
            const mask = try a.dupe(u8, job.renderer.?.mask);
            defer a.free(mask);
            const dictionary_decodes = doc.dictionary_decodes;
            const foreground_cache = if (job.foreground) |fg| fg.pixels.ptr else null;
            var retained: usize = 0;
            for (0..2) |cycle| {
                for ([_]u32{ 8, 5, 2, 1, 65 }, [_][2]u32{ .{ 2, 1 }, .{ 4, 1 }, .{ 4, 2 }, .{ 4, 4 }, .{ 1, 1 } }) |edge, reductions| {
                    try job.restart(.{ .size = .{ .width = edge, .height = edge }, .rotation = @intCast(cycle) });
                    try finish(&job, 7);
                    try checkReference(&job);
                    try std.testing.expectEqualSlices(u8, mask, job.renderer.?.mask);
                    try std.testing.expectEqual(dictionary_decodes, doc.dictionary_decodes);
                    if (std.mem.eql(u8, name, "foreground") or std.mem.eql(u8, name, "mmr-foreground")) {
                        try std.testing.expectEqualSlices(u32, &reductions, &job.iw44_reductions);
                        if (cycle == 0 and edge >= 5 and edge < 65) try std.testing.expectEqual(foreground_cache, job.foreground.?.pixels.ptr);
                    }
                    var fresh_doc = try Document.open(a, bytes, .{});
                    defer fresh_doc.deinit();
                    var fresh = try Job.init(&fresh_doc, 0, job.options);
                    defer fresh.deinit();
                    try finish(&fresh, 4096);
                    try std.testing.expectEqualSlices(u8, try fresh.pixels(), try job.pixels());
                }
                try job.restart(.{});
                try finish(&job, 4096);
                try std.testing.expectEqualSlices(u8, full, try job.pixels());
                if (cycle == 0) retained = budget.live else try std.testing.expectEqual(retained, budget.live);
            }
        }
        try std.testing.expectEqual(@as(usize, 0), budget.live);
    }
}

fn compoundAllocationCase(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var doc = try Document.open(allocator, bytes, .{});
    defer doc.deinit();
    var job = try Job.init(&doc, 0, .{});
    defer job.deinit();
    try finish(&job, 4096);
    for ([_]u32{ 5, 2, 1 }) |edge| {
        try job.restart(.{ .size = .{ .width = edge, .height = edge } });
        try finish(&job, 4096);
    }
    try job.restart(.{});
    try finish(&job, 4096);
}

test "compound cache promotion allocation failures release every layer and mask" {
    inline for (.{ "foreground", "compound", "jpeg-background", "jpeg-foreground", "mmr-foreground" }) |name| {
        try std.testing.checkAllAllocationFailures(a, compoundAllocationCase, .{@as([]const u8, @embedFile("../fixtures/" ++ name ++ ".djvu"))});
    }
}

fn promoteAllocationCase(allocator: std.mem.Allocator) !void {
    var doc = try Document.open(allocator, @embedFile("../fixtures/iw44-reduced-half.djvu"), .{});
    defer doc.deinit();
    var job = try Job.init(&doc, 0, .{});
    defer job.deinit();
    try finish(&job, 4096);
    try job.restart(.{ .size = .{ .width = 32, .height = 32 } });
    try finish(&job, 4096);
    try job.restart(.{});
    try finish(&job, 4096);
}

test "small RGB cache promotion releases allocations on failure" {
    try std.testing.checkAllAllocationFailures(a, promoteAllocationCase, .{});
}

test "automatic selection accounts for encoded layer reduction and odd INFO bounds" {
    var bytes = @embedFile("../fixtures/iw44-reduced-full.djvu").*;
    std.mem.writeInt(u16, bytes[24..26], 255, .big);
    std.mem.writeInt(u16, bytes[26..28], 191, .big);
    var doc = try Document.open(a, &bytes, .{});
    defer doc.deinit();
    var job = try Job.init(&doc, 0, .{});
    defer job.deinit();
    try finish(&job, 4096);
    for (0..4) |turn| for ([_]u32{ 31, 32, 63, 64, 128 }, [_]u32{ 4, 2, 2, 1, 1 }) |edge, reduction| {
        try job.restart(.{ .size = .{ .width = edge, .height = edge }, .rotation = @intCast(turn) });
        try finish(&job, 4096);
        try std.testing.expectEqual(reduction, job.iw44_reductions[0]);
        try checkReference(&job);
        const expected = try a.dupe(u8, try job.pixels());
        defer a.free(expected);
        const g = try job.geometry();
        var tile = job.options;
        tile.region = .{ .x = 1, .y = 2, .width = 3, .height = 4 };
        try job.restart(tile);
        try finish(&job, 1);
        try std.testing.expectEqual(reduction, job.iw44_reductions[0]);
        for (0..4) |y| try std.testing.expectEqualSlices(u8, expected[((y + 2) * g.width + 1) * 4 ..][0..12], (try job.pixels())[y * 12 ..][0..12]);
    };
}

test "failed promotion preserves the small RGB cache and cancellation releases it" {
    var budget: @import("../../src/budget.zig").Budget = .{ .parent = a, .limit = 4 * 1024 * 1024 };
    {
        var doc = try Document.open(budget.allocator(), @embedFile("../fixtures/iw44-reduced-full.djvu"), .{});
        defer doc.deinit();
        var job = try Job.init(&doc, 0, .{ .region = .{ .x = 0, .y = 0, .width = 1, .height = 1 } });
        defer job.deinit();
        try finish(&job, 4096);
        const pixel = (try job.pixels())[0..4].*;
        const preview_options: composite.Options = .{ .size = .{ .width = 32, .height = 32 } };
        budget.limit = budget.live;
        try std.testing.expectError(error.OutOfMemory, job.restart(preview_options));
        try std.testing.expectEqualSlices(u8, &pixel, try job.pixels());
        try std.testing.expect(job.background != null and job.regional[0] == null);
        budget.limit = 4 * 1024 * 1024;
        try job.restart(preview_options);
        try std.testing.expectEqual(.progress, try job.step(1));
        job.cancel();
        try std.testing.expectError(error.Cancelled, job.pixels());
    }
    try std.testing.expectEqual(@as(usize, 0), budget.live);
}

test "automatic previews return from exact views without changing pixels or accumulating buffers" {
    var budget: @import("../../src/budget.zig").Budget = .{ .parent = a, .limit = 24 * 1024 * 1024 };
    {
        var doc = try Document.open(budget.allocator(), @embedFile("../fixtures/iw44-regions.djvu"), .{});
        defer doc.deinit();
        const preview: composite.Options = .{ .size = .{ .width = 137, .height = 181 } };
        var job = try Job.init(&doc, 0, preview);
        defer job.deinit();
        try finish(&job, 16384);
        try std.testing.expectEqual(@as(u32, 4), job.iw44_reductions[0]);
        // Small fixtures above check cell composition independently; this large
        // fixture exercises retained buffers, strip transitions and failures.
        const expected = try a.dupe(u8, try job.pixels());
        defer a.free(expected);
        var retained: usize = 0;
        for (0..2) |cycle| {
            for ([_]composite.Options{
                .{ .region = .{ .x = 973, .y = 1007, .width = 512, .height = 512 } },
                .{ .size = .{ .width = 1300, .height = 1800 }, .region = .{ .x = 11, .y = 13, .width = 31, .height = 29 } },
                .{ .size = .{ .width = 4000, .height = 4000 }, .rotation = 1, .region = .{ .x = 11, .y = 13, .width = 31, .height = 29 } },
                .{ .subsample = 3, .rotation = 2, .region = .{ .x = 11, .y = 13, .width = 31, .height = 29 } },
                .{ .size = .{ .width = 1, .height = 1 } },
                preview,
            }, [_]u32{ 1, 2, 1, 1, 4, 4 }) |options, reduction| {
                try job.restart(options);
                try finish(&job, 16384);
                try std.testing.expectEqual(reduction, job.iw44_reductions[0]);
            }
            try std.testing.expectEqualSlices(u8, expected, try job.pixels());
            if (cycle == 0) retained = budget.live else try std.testing.expectEqual(retained, budget.live);
        }
        const before = job.iw44_reductions;
        try std.testing.expectError(error.OutOfMemory, job.restart(.{}));
        try std.testing.expectEqualSlices(u32, &before, &job.iw44_reductions);
        try std.testing.expectEqualSlices(u8, expected, try job.pixels());
        try job.restart(.{ .region = .{ .x = 0, .y = 0, .width = 512, .height = 512 } });
        try std.testing.expectEqual(.progress, try job.step(1));
        job.cancel();
        try std.testing.expectError(error.Cancelled, job.pixels());
    }
    try std.testing.expectEqual(@as(usize, 0), budget.live);
}
