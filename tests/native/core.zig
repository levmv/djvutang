const std = @import("std");
const Document = @import("../../src/document.zig").Document;
const Job = @import("../../src/job.zig").Job;
const Budget = @import("../../src/budget.zig").Budget;
const iw44 = @import("../../src/iw44.zig");
const iff = @import("../../src/iff.zig");

test "budget rejection survives cleanup and differs from allocator exhaustion" {
    var storage: [32]u8 = undefined;
    var parent = std.heap.FixedBufferAllocator.init(&storage);
    var budget: Budget = .{ .parent = parent.allocator(), .limit = 64 };
    const a = budget.allocator();
    {
        const bytes = try a.alloc(u8, 32);
        defer a.free(bytes);
        try std.testing.expect(!a.resize(bytes, 96));
    }
    try std.testing.expectEqual(@as(usize, 0), budget.live);
    try std.testing.expectEqualDeep(Budget.Denial{
        .limit = 64,
        .live = 32,
        .requested = 96,
        .replacing = 32,
    }, budget.denied.?);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 65));
    try std.testing.expectEqualDeep(Budget.Denial{
        .limit = 64,
        .live = 0,
        .requested = 65,
        .replacing = 0,
    }, budget.denied.?);
    // The next request fits the budget but exceeds the parent allocator.
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 33));
    try std.testing.expect(budget.denied == null);
}

fn wavelet(allocator: std.mem.Allocator, bytes: []const u8, work: usize) !@import("../../src/pixmap.zig").Pixmap {
    const root = try iff.root(bytes);
    var chunks: std.ArrayList([]const u8) = .empty;
    defer chunks.deinit(allocator);
    var iter = try root.children();
    while (try iter.next()) |chunk| if (iff.tag(chunk.id, "BG44")) {
        try chunks.append(allocator, chunk.data);
    };
    var decoder = try iw44.Decoder.init(allocator, chunks.items, .{});
    defer decoder.deinit();
    while (!try decoder.step(work)) {}
    return decoder.takeImage();
}

test "IW44 grayscale color progressive chroma and tiny boundaries match independent oracle" {
    inline for (.{
        "gray",
        "color",
        "progressive",
        "chroma-half",
        "tiny",
        "narrow",
        "foreground-layer",
        "iw44-empty-parts",
        "iw44-filter-range",
    }) |name| {
        for ([_]usize{ 1, 17, 512, 4096 }) |work| {
            var pixmap = try wavelet(std.testing.allocator, @embedFile("../fixtures/" ++ name ++ ".djvu"), work);
            defer pixmap.deinit(std.testing.allocator);
            const expected = @embedFile("../fixtures/" ++ name ++ "-expected.ppm");
            const header = std.mem.indexOf(u8, expected, "\n255\n").? + 5;
            std.testing.expectEqualSlices(u8, expected[header..], std.mem.sliceAsBytes(pixmap.pixels)) catch |err| {
                std.debug.print("IW44 fixture {s}, work {d}\n", .{ name, work });
                return err;
            };
        }
    }
}

test "IW44 reconstruction shares one work budget across rows and phase boundaries" {
    // One grayscale plane: filtering, extraction and RGB conversion each charge
    // one unit per operation. A batched call must do no more than scalar calls.
    var iter = try (try iff.root(@embedFile("../fixtures/gray.djvu"))).children();
    const chunk = while (try iter.next()) |child| {
        if (iff.tag(child.id, "BG44")) break child.data;
    } else return error.MissingFixtureChunk;
    const expected = @embedFile("../fixtures/gray-expected.ppm");
    const header = std.mem.indexOf(u8, expected, "\n255\n").? + 5;
    var work: usize = 0;
    for ([_]bool{ false, true }) |batched| {
        var decoder = try iw44.Decoder.init(std.testing.allocator, &.{chunk}, .{});
        defer decoder.deinit();
        while (decoder.phase != .filter) try std.testing.expect(!try decoder.step(1));
        if (batched) {
            try std.testing.expect(!try decoder.step(work - 1));
            try std.testing.expect(try decoder.step(1));
        } else {
            while (true) {
                work += 1;
                if (try decoder.step(1)) break;
            }
        }
        var image = decoder.takeImage();
        defer image.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, expected[header..], std.mem.sliceAsBytes(image.pixels));
    }
}

test "IW44 vertical batches preserve signed samples at edges and resume boundaries" {
    const samples = [_]i16{ -32768, 32767, -32767, 32766, -4097, 4096, -33, -32, -1, 0, 1, 15, 16, 17, 31, 32, 33 };
    for ([_]u8{ 1, 3, 4, 5, 7, 8, 9, 17, 33 }) |width| {
        for ([_]u8{ 1, 2, 3, 6, 7, 9 }) |height| {
            for ([_]usize{ 3, 4, 5, 7, 17 }) |work| {
                const chunk = [_]u8{ 0, 0, 0x81, 2, 0, width, 0, height, 0x80 };
                var scalar = try iw44.Decoder.init(std.testing.allocator, &.{&chunk}, .{});
                defer scalar.deinit();
                var batched = try iw44.Decoder.init(std.testing.allocator, &.{&chunk}, .{});
                defer batched.deinit();
                for ([_]*iw44.Decoder{ &scalar, &batched }) |decoder| {
                    decoder.scratch = try std.testing.allocator.alloc(i16, decoder.stride * decoder.padded_height);
                    for (decoder.scratch, 0..) |*sample, i| sample.* = samples[(13 * i + 7 * (i / decoder.stride)) % samples.len];
                    decoder.phase = .filter;
                    decoder.scale = 1;
                }
                // Stop at each row boundary, before horizontal filtering can
                // obscure a difference in the signed 16-bit intermediate raster.
                while (!scalar.horizontal) {
                    const count = @min(work, width - scalar.filter_x);
                    for (0..count) |_| try std.testing.expect(!try scalar.step(1));
                    try std.testing.expect(!try batched.step(count));
                    try std.testing.expectEqual(scalar.filter_x, batched.filter_x);
                    try std.testing.expectEqual(scalar.filter_y, batched.filter_y);
                    try std.testing.expectEqual(scalar.odd, batched.odd);
                    try std.testing.expectEqual(scalar.horizontal, batched.horizontal);
                    try std.testing.expectEqualSlices(i16, scalar.scratch, batched.scratch);
                }
            }
        }
    }
}

test "IW44 zero coefficients render within a bounded memory budget" {
    // A complete color header with zero slices: all three planes reconstruct
    // neutral gray, including the final row at an odd height.
    const chunk = [_]u8{ 0, 0, 1, 2, 1, 0, 1, 1, 0x80 };
    // Enough for RGB and coefficient indexes, but not a scratch plane as well.
    var budget: Budget = .{ .parent = std.testing.allocator, .limit = 256 * 1024 };
    for ([_]bool{ false, true }) |retain| {
        var decoder = try iw44.Decoder.init(budget.allocator(), &.{&chunk}, .{});
        defer decoder.deinit();
        decoder.retain_coefficients = retain;
        while (!try decoder.step(127)) {}
        if (retain) {
            // Repeat at another grid and region before returning to full size.
            try decoder.reconstructReduced(4, .{ .x = 1, .y = 2, .width = 61, .height = 57 });
            while (!try decoder.step(1)) {}
            for (decoder.image.?.pixels) |pixel| try std.testing.expectEqual([3]u8{ 128, 128, 128 }, pixel);
            try decoder.reconstruct(.{ .x = 0, .y = 0, .width = 256, .height = 257 });
            while (!try decoder.step(127)) {}
        }
        try std.testing.expectEqual(@as(u32, 256), decoder.image.?.width);
        try std.testing.expectEqual(@as(u32, 257), decoder.image.?.height);
        for (decoder.image.?.pixels) |pixel| try std.testing.expectEqual([3]u8{ 128, 128, 128 }, pixel);
    }
    try std.testing.expectEqual(@as(usize, 0), budget.live);
}

fn expectRgb(expected: []const u8, rgba: []const u8) !void {
    const rgb = expected[std.mem.indexOf(u8, expected, "\n255\n").? + 5 ..];
    try std.testing.expectEqual(rgb.len / 3 * 4, rgba.len);
    for (0..rgb.len / 3) |i| {
        try std.testing.expectEqualSlices(u8, rgb[i * 3 ..][0..3], rgba[i * 4 ..][0..3]);
        try std.testing.expectEqual(@as(u8, 255), rgba[i * 4 + 3]);
    }
}

test "color page composition gamma and rotation match independent references" {
    inline for (.{
        "gray",
        "color",
        "progressive",
        "chroma-half",
        "tiny",
        "narrow",
        "gamma",
        "rotated-color",
        "palette",
        "compound",
        "foreground",
        "blank-page",
        "reduced-background",
    }) |name| {
        const composed = comptime std.mem.eql(u8, name, "palette") or
            std.mem.eql(u8, name, "compound") or std.mem.eql(u8, name, "foreground") or
            std.mem.eql(u8, name, "blank-page") or std.mem.eql(u8, name, "reduced-background");
        const expected = @embedFile("../fixtures/" ++ name ++ (if (composed) "-reference.ppm" else "-expected.ppm"));
        const rgba = try render(std.testing.allocator, @embedFile("../fixtures/" ++ name ++ ".djvu"));
        defer std.testing.allocator.free(rgba);
        expectRgb(expected, rgba) catch |err| {
            std.debug.print("Color composition fixture {s}\n", .{name});
            return err;
        };
    }
}

test "IW44 cancellation during entropy or reconstruction releases work and restart keeps layers" {
    var budget: Budget = .{ .parent = std.testing.allocator, .limit = 2 * 1024 * 1024 };
    for ([_][]const u8{
        @embedFile("../fixtures/progressive.djvu"),
        @embedFile("../fixtures/pm44-progressive.iw4"),
    }) |bytes| {
        var doc = try Document.open(budget.allocator(), bytes, .{});
        defer doc.deinit();
        for ([_]bool{ false, true }) |filtering| {
            var job = try Job.init(&doc, 0, .{});
            defer job.deinit();
            var reached = false;
            for (0..100000) |_| {
                try std.testing.expectEqual(.progress, try job.step(1));
                if (job.wavelet) |decoder| {
                    reached = if (filtering)
                        decoder.phase == .filter and decoder.filter_x > 0
                    else
                        decoder.phase == .entropy and decoder.slices > 75;
                    if (reached) break;
                }
            }
            try std.testing.expect(reached);
            job.cancel();
            try std.testing.expectError(error.Cancelled, job.step(1));
            try std.testing.expectError(error.Cancelled, job.pixels());
        }
        var job = try Job.init(&doc, 0, .{});
        defer job.deinit();
        while (try job.step(512) != .done) {}
        const address = job.background.?.pixels.ptr;
        try job.restart(.{ .subsample = 3, .rotation = 2 });
        while (try job.step(512) != .done) {}
        try job.restart(.{});
        while (try job.step(512) != .done) {}
        try std.testing.expectEqual(address, job.background.?.pixels.ptr);
        try expectRgb(@embedFile("../fixtures/progressive-expected.ppm"), try job.pixels());
    }
    try std.testing.expectEqual(@as(usize, 0), budget.live);
}

test "progressive ordering slice limit and palette correspondence fail explicitly" {
    const a = std.testing.allocator;
    const original = @embedFile("../fixtures/progressive.djvu");
    var bytes: [original.len]u8 = original.*;
    var iter = try (try iff.root(&bytes)).children();
    var seen: usize = 0;
    while (try iter.next()) |chunk| if (iff.tag(chunk.id, "BG44")) {
        if (seen == 1) bytes[chunk.offset + 8] = 2;
        seen += 1;
    };
    try std.testing.expectError(error.InvalidData, render(a, &bytes));
    {
        var doc = try Document.open(a, original, .{ .max_iw_slices = 80 });
        defer doc.deinit();
        var job = try Job.init(&doc, 0, .{});
        defer job.deinit();
        const result = blk: {
            for (0..10000) |_| {
                const status = job.step(4096) catch |err| break :blk err;
                if (status == .done) break;
            }
            return error.TestExpectedError;
        };
        try std.testing.expectEqual(error.LimitExceeded, result);
    }
    const colored = @embedFile("../fixtures/palette.djvu");
    var bad_palette: [colored.len]u8 = colored.*;
    var parts = try (try iff.root(&bad_palette)).children();
    while (try parts.next()) |chunk| if (iff.tag(chunk.id, "FGbz")) {
        const count = @as(usize, chunk.data[1]) * 256 + chunk.data[2];
        const correspondence = chunk.offset + 8 + 3 + count * 3;
        bad_palette[correspondence + 2] ^= 1;
    };
    try std.testing.expectError(error.InvalidData, render(a, &bad_palette));
}

test "overlapping colored glyphs paint once in blit order" {
    const jb2 = @import("../../src/jb2.zig");
    const composite = @import("../../src/composite.zig");
    const a = std.testing.allocator;
    var image: jb2.Image = .{ .width = 2, .height = 2 };
    defer image.deinit(a);
    const pixels = try a.dupe(u8, &.{ 3, 3 });
    try image.shapes.append(a, .{ .width = 2, .height = 2, .pixels = pixels });
    try image.blits.appendSlice(a, &.{ .{ .shape = 0, .left = 0, .bottom = 0 }, .{ .shape = 0, .left = 0, .bottom = 0 } });
    for ([_]usize{ 1, 2, 3, 4, 16, 17, 256, 257, 65535 }) |count| {
        const colors = try a.alloc([3]u8, count);
        defer a.free(colors);
        @memset(colors, .{ 255, 0, 0 });
        colors[count - 1] = .{ 0, 0, 255 };
        var indices = [_]u16{ 0, @intCast(count - 1) };
        const palette: @import("../../src/color.zig").Palette = .{ .colors = colors, .indices = &indices };
        var renderer = try composite.Renderer.init(
            a,
            .{ .width = 2, .height = 2, .dpi = 300, .rotation = 0 },
            .{ .subsample = 2 },
            .{ .mask = .{ .symbols = &image }, .palette = &palette },
        );
        defer renderer.deinit();
        while (!try renderer.step(1)) {}
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, renderer.rgba);
    }
}

test "mutated wavelet payloads stay bounded and release all owned allocations" {
    const original = @embedFile("../fixtures/progressive.djvu");
    var prng = std.Random.DefaultPrng.init(0x49573434);
    for (0..128) |_| {
        var bytes: [original.len]u8 = original.*;
        const index = prng.random().uintLessThan(usize, bytes.len);
        bytes[index] ^= prng.random().int(u8) | 1;
        var budget: Budget = .{ .parent = std.testing.allocator, .limit = 256 * 1024 };
        {
            var doc = Document.open(budget.allocator(), &bytes, .{ .max_page_pixels = 16384, .max_iw_slices = 200 }) catch continue;
            defer doc.deinit();
            var job = Job.init(&doc, 0, .{}) catch continue;
            defer job.deinit();
            for (0..4096) |_| {
                const status = job.step(512) catch break;
                if (status == .done) break;
            }
            job.cancel();
        }
        try std.testing.expectEqual(@as(usize, 0), budget.live);
    }
}

test "directory offsets define logical page order" {
    var doc = try Document.open(std.testing.allocator, @embedFile("../fixtures/reordered.djvu"), .{});
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 2), doc.pageCount());
    try std.testing.expectEqual(@as(u32, 37), (try doc.info(0)).width);
    try std.testing.expectEqual(@as(u32, 31), (try doc.info(1)).width);
}

fn render(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var doc = try Document.open(allocator, bytes, .{});
    defer doc.deinit();
    var job = try Job.init(&doc, 0, .{});
    defer job.deinit();
    while (try job.step(127) != .done) {}
    return allocator.dupe(u8, try job.pixels());
}

test "damaged optional text cannot prevent image rendering" {
    const a = std.testing.allocator;
    const clean = try render(a, @embedFile("../fixtures/plain.djvu"));
    defer a.free(clean);
    const damaged = try render(a, @embedFile("../fixtures/bad-text.djvu"));
    defer a.free(damaged);
    try std.testing.expectEqualSlices(u8, clean, damaged);
    var black: usize = 0;
    for (clean) |b| if (b == 0) {
        black += 1;
    };
    try std.testing.expect(black > 0);
}

test "cancellation releases work and a new render succeeds" {
    var budget: Budget = .{ .parent = std.testing.allocator, .limit = 1024 * 1024 };
    {
        var doc = try Document.open(budget.allocator(), @embedFile("../fixtures/plain.djvu"), .{});
        defer doc.deinit();
        {
            var job = try Job.init(&doc, 0, .{});
            defer job.deinit();
            try std.testing.expectEqual(.progress, try job.step(1));
            var inside_symbol = false;
            for (0..10000) |_| {
                if (job.decoder) |decoder| if (decoder.pending) |pending| {
                    if (pending.pixel > 0 and pending.pixel < pending.shape.pixelCount()) {
                        inside_symbol = true;
                        break;
                    }
                };
                try std.testing.expectEqual(.progress, try job.step(1));
            }
            try std.testing.expect(inside_symbol);
            job.cancel();
            try std.testing.expectError(error.Cancelled, job.step(1));
            try std.testing.expectError(error.Cancelled, job.pixels());
        }
        var next = try Job.init(&doc, 0, .{});
        defer next.deinit();
        while (try next.step(37) != .done) {}
        try std.testing.expectEqual(@as(usize, 37 * 29 * 4), (try next.pixels()).len);
        try next.restart(.{ .subsample = 2 });
        while (try next.step(37) != .done) {}
        try std.testing.expectEqual(@as(usize, 19 * 15 * 4), (try next.pixels()).len);
    }
    try std.testing.expectEqual(@as(usize, 0), budget.live);
}

test "all allocation failures unwind safely" {
    for ([_][]const u8{
        @embedFile("../fixtures/plain.djvu"),
        @embedFile("../fixtures/shared.djvu"),
        @embedFile("../fixtures/progressive.djvu"),
        @embedFile("../fixtures/compound.djvu"),
        @embedFile("../fixtures/foreground.djvu"),
        @embedFile("../fixtures/mmr-striped.djvu"),
        @embedFile("../fixtures/mmr-foreground.djvu"),
        @embedFile("../fixtures/pm44-progressive.iw4"),
        @embedFile("../fixtures/bm44.iw4"),
        @embedFile("../fixtures/palette-unmapped-bg.djvu"),
        @embedFile("../fixtures/mmr-palette-bg.djvu"),
        @embedFile("../fixtures/palette-empty.djvu"),
    }) |bytes|
        try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
            fn run(a: std.mem.Allocator, input: []const u8) !void {
                const pixels = try render(a, input);
                a.free(pixels);
            }
        }.run, .{bytes});
}

test "shared symbols decode once and reproduce both original bitmaps" {
    var doc = try Document.open(std.testing.allocator, @embedFile("../fixtures/shared.djvu"), .{});
    defer doc.deinit();
    for ([_][]const u8{ @embedFile("../fixtures/page0.pbm"), @embedFile("../fixtures/page1.pbm") }, 0..) |pbm, page| {
        var job = try Job.init(&doc, page, .{});
        defer job.deinit();
        while (try job.step(53) != .done) {}
        try std.testing.expect(job.image.?.inherited_count > 0);
        try std.testing.expectEqual(@as(usize, 1), doc.dictionary_decodes);
        const rgba = try job.pixels();
        const bits = pbm["P4\n160 100\n".len..];
        for (0..160 * 100) |i| {
            const black = (bits[i / 8] >> @as(u3, @intCast(7 - i % 8))) & 1;
            const expected: u8 = if (black == 1) 0 else 255;
            try std.testing.expectEqual(expected, rgba[i * 4]);
        }
    }
    try doc.dropDictionaries();
    var again = try Job.init(&doc, 0, .{});
    defer again.deinit();
    while (try again.step(4096) != .done) {}
    try std.testing.expectEqual(@as(usize, 2), doc.dictionary_decodes);
}

test "INFO rotation is applied to the pixels" {
    const a = std.testing.allocator;
    const normal = try render(a, @embedFile("../fixtures/plain.djvu"));
    defer a.free(normal);
    const rotated = try render(a, @embedFile("../fixtures/rotated.djvu"));
    defer a.free(rotated);
    for (0..37) |y| for (0..29) |x| {
        const original = (x * 37 + (37 - 1 - y)) * 4;
        try std.testing.expectEqualSlices(u8, normal[original..][0..4], rotated[(y * 29 + x) * 4 ..][0..4]);
    };
}

test "dictionary aliases preserve both pages and unequal dictionaries remain ambiguous" {
    const a = std.testing.allocator;
    const original = @embedFile("../fixtures/dictionary-aliases.djvu");
    var bytes: [original.len]u8 = original.*;
    var offset: usize = undefined;
    {
        var doc = try Document.open(a, &bytes, .{});
        defer doc.deinit();
        var reference = try Document.open(a, @embedFile("../fixtures/shared.djvu"), .{});
        defer reference.deinit();
        for ([_]usize{ 1, 0, 1 }) |page| {
            var actual = try Job.init(&doc, page, .{});
            defer actual.deinit();
            var expected = try Job.init(&reference, page, .{});
            defer expected.deinit();
            while (try actual.step(17) != .done) {}
            while (try expected.step(2048) != .done) {}
            try std.testing.expectEqualSlices(u8, try expected.pixels(), try actual.pixels());
        }
        offset = (try doc.find(1, "Djbz")).?.offset + 8;
    }
    bytes[offset] ^= 1;
    var different = try Document.open(a, &bytes, .{});
    defer different.deinit();
    try std.testing.expectError(error.Unsupported, Job.init(&different, 0, .{}));
}

test "damaged page info does not prevent another page from rendering" {
    const original = @embedFile("../fixtures/shared.djvu");
    var bytes: [original.len]u8 = original.*;
    const info = std.mem.indexOf(u8, &bytes, "INFO").?;
    bytes[info + 8] = 0;
    bytes[info + 9] = 0;
    var doc = try Document.open(std.testing.allocator, &bytes, .{});
    defer doc.deinit();
    try std.testing.expectError(error.InvalidData, doc.info(0));
    var job = try Job.init(&doc, 1, .{});
    defer job.deinit();
    while (try job.step(4096) != .done) {}
    try std.testing.expectEqual(@as(usize, 160 * 100 * 4), (try job.pixels()).len);
}

test "unsupported image layers are explicit and unknown optional chunks survive" {
    // Replace the existing TXTa tag without changing its bounded payload.
    const original = @embedFile("../fixtures/bad-text.djvu");
    var bytes: [original.len]u8 = original.*;
    const chunk = std.mem.indexOf(u8, &bytes, "TXTa").?;
    for ([_][]const u8{ "BGzz", "FGzz", "JUNK" }) |tag| {
        @memcpy(bytes[chunk..][0..4], tag);
        var doc = try Document.open(std.testing.allocator, &bytes, .{});
        defer doc.deinit();
        if (std.mem.eql(u8, tag, "JUNK")) {
            var job = try Job.init(&doc, 0, .{});
            defer job.deinit();
            while (try job.step(4096) != .done) {}
        } else try std.testing.expectError(error.Unsupported, Job.init(&doc, 0, .{}));
    }
}

test "truncations and deterministic mutations remain bounded and releasable" {
    const original = @embedFile("../fixtures/shared.djvu");
    for (0..original.len) |len| {
        const result = Document.open(std.testing.allocator, original[0..len], .{});
        if (result) |value| {
            var doc = value;
            doc.deinit();
        } else |_| {}
    }
    var prng = std.Random.DefaultPrng.init(0x444a5655);
    for (0..128) |_| {
        var input: [original.len]u8 = original.*;
        const index = prng.random().uintLessThan(usize, input.len);
        input[index] ^= prng.random().int(u8) | 1;
        var budget: Budget = .{ .parent = std.testing.allocator, .limit = 512 * 1024 };
        {
            var doc = Document.open(budget.allocator(), &input, .{
                .max_bzz_bytes = 65536,
                .max_page_pixels = 65536,
                .max_shape_pixels = 65536,
                .max_shapes = 256,
                .max_blits = 2048,
                .max_cells = 8192,
                .max_records = 2048,
                .max_components = 256,
            }) catch continue;
            defer doc.deinit();
            var job = Job.init(&doc, 0, .{}) catch continue;
            defer job.deinit();
            for (0..1024) |_| {
                const status = job.step(1024) catch break;
                if (status == .done) break;
            }
            job.cancel();
        }
        try std.testing.expectEqual(@as(usize, 0), budget.live);
    }
}
