const std = @import("std");
const jpeg = @import("../../src/jpeg.zig");
const types = @import("../../src/types.zig");
const Document = @import("../../src/document.zig").Document;
const Job = @import("../../src/job.zig").Job;
const Budget = @import("../../src/budget.zig").Budget;
const a = std.testing.allocator;

fn pixels(ppm: []const u8) []const u8 {
    return ppm[std.mem.indexOf(u8, ppm, "\n255\n").? + 5 ..];
}

fn decode(allocator: std.mem.Allocator, data: []const u8, limits: types.Limits) !void {
    var decoder = try jpeg.Decoder.init(allocator, data, limits);
    defer decoder.deinit();
    for (0..100_000) |_| if (try decoder.step(1024)) return;
    return error.TestWorkLimit;
}

test "JPEG resumes scans IDCT and RGB with upstream pixels and independent libjpeg bounds" {
    inline for (.{
        "baseline",
        "progressive",
        "444",
        "422",
        "rgb",
        "gray",
        "cmyk",
        "ycck",
        "sequential",
        "restart",
        "progressive-restart",
        "tiny",
        "narrow",
        "background-layer",
        "foreground-layer",
    }) |name| {
        const encoded = @embedFile("../fixtures/jpeg-" ++ name ++ ".jpg");
        const expected = pixels(@embedFile("../fixtures/jpeg-" ++ name ++ "-reference.ppm"));
        const independent = pixels(@embedFile("../fixtures/jpeg-" ++ name ++ "-libjpeg.ppm"));
        for ([_]usize{ 1, 2048, 100_000 }) |work| {
            var decoder = try jpeg.Decoder.init(a, encoded, .{});
            defer decoder.deinit();
            while (!try decoder.step(work)) {}
            var image = decoder.takeImage();
            defer image.deinit(a);
            const actual = std.mem.sliceAsBytes(image.pixels);
            try std.testing.expectEqualSlices(u8, expected, actual);
            for (actual, independent) |v, reference|
                try std.testing.expect(@abs(@as(i16, v) - reference) <= 3);
        }
    }
}

test "JPEG rejects every truncation including missing entropy before EOI" {
    inline for (.{ "baseline", "progressive", "progressive-restart", "sequential" }) |name| {
        const original = @embedFile("../fixtures/jpeg-" ++ name ++ ".jpg");
        for (0..original.len) |length|
            try std.testing.expectError(error.InvalidData, decode(a, original[0..length], .{}));
        const bytes = try a.dupe(u8, original);
        defer a.free(bytes);
        // A present EOI must not turn missing entropy bytes into black pixels.
        for (2..@min(40, original.len)) |missing| {
            @memcpy(bytes, original);
            bytes[original.len - missing - 2] = 0xff;
            bytes[original.len - missing - 1] = 0xd9;
            try std.testing.expectError(error.InvalidData, decode(a, bytes[0 .. original.len - missing], .{}));
        }
    }
}

test "JPEG header junk and zero alignment preserve every decoded pixel" {
    inline for (.{ .{ "header-junk", "baseline" }, .{ "zero-padding", "sequential" } }) |case| {
        const encoded = @embedFile("../fixtures/jpeg-" ++ case[0] ++ ".jpg");
        const expected = pixels(@embedFile("../fixtures/jpeg-" ++ case[1] ++ "-reference.ppm"));
        for ([_]usize{ 1, 193 }) |work| {
            var decoder = try jpeg.Decoder.init(a, encoded, .{});
            defer decoder.deinit();
            while (!try decoder.step(work)) {}
            try std.testing.expectEqualSlices(u8, expected, std.mem.sliceAsBytes(decoder.image.?.pixels));
        }
    }
}

test "JPEG marker recovery stays bounded and never skips damaged scan data" {
    const original = @embedFile("../fixtures/jpeg-baseline.jpg");
    const noise = try a.alloc(u8, original.len + 64);
    defer a.free(noise);
    @memcpy(noise[0..2], original[0..2]);
    @memset(noise[2..66], 'x');
    @memcpy(noise[66..], original[2..]);
    try std.testing.expectError(error.LimitExceeded, decode(a, noise, .{ .max_chunks = 16 }));
    @memset(noise[2..66], 0xff);
    try std.testing.expectError(error.LimitExceeded, decode(a, noise, .{ .max_chunks = 16 }));
    // Once a marker is found, its declared length remains authoritative.
    @memcpy(noise[2..8], "\xff\xe1\xff\xffxx");
    try std.testing.expectError(error.InvalidData, decode(a, noise, .{}));

    inline for (.{ "restart", "progressive-restart" }) |name| {
        const source = @embedFile("../fixtures/jpeg-" ++ name ++ ".jpg");
        const bytes = try a.dupe(u8, source);
        defer a.free(bytes);
        const restart = std.mem.indexOf(u8, source, "\xff\xd0").?;
        const interval = std.mem.indexOf(u8, source, "\xff\xdd").?;
        for ([_]struct { offset: usize, value: u8 }{
            .{ .offset = restart + 1, .value = 0xd1 }, // Wrong restart number.
            .{ .offset = restart, .value = 'x' }, // No marker at the restart boundary.
            .{ .offset = interval + 5, .value = 1 }, // More coded blocks than declared.
        }) |case| {
            @memcpy(bytes, source);
            bytes[case.offset] = case.value;
            try std.testing.expectError(error.InvalidData, decode(a, bytes, .{}));
        }
    }
}

test "JPEG limits and allocation failures release all buffers" {
    const original = @embedFile("../fixtures/jpeg-progressive.jpg");
    try std.testing.expectError(error.LimitExceeded, decode(a, original, .{ .max_page_pixels = 100 }));
    try std.testing.expectError(error.LimitExceeded, decode(a, original, .{ .max_chunks = 1 }));
    try std.testing.expectError(error.LimitExceeded, decode(a, original, .{ .max_jpeg_scans = 1 }));
    try std.testing.expectError(error.LimitExceeded, decode(a, original, .{ .max_jpeg_blocks = 2 }));
    try std.testing.checkAllAllocationFailures(a, decode, .{ original, types.Limits{} });
}

test "JPEG distinguishes unsupported profiles from corrupt tables and scan headers" {
    const original = @embedFile("../fixtures/jpeg-baseline.jpg");
    var bytes: [original.len]u8 = undefined;
    const frame = std.mem.indexOf(u8, original, "\xff\xc0").?;
    const scan = std.mem.indexOf(u8, original, "\xff\xda").?;
    const quant = std.mem.indexOf(u8, original, "\xff\xdb").?;
    const cases = [_]struct { offset: usize, value: u8, err: types.Error }{
        .{ .offset = frame + 1, .value = 0xc3, .err = error.Unsupported }, // Lossless.
        .{ .offset = frame + 1, .value = 0xc9, .err = error.Unsupported }, // Arithmetic.
        .{ .offset = frame + 4, .value = 12, .err = error.Unsupported },
        .{ .offset = frame + 11, .value = 0, .err = error.InvalidData }, // Zero sampling.
        .{ .offset = quant + 1, .value = 0xe2, .err = error.InvalidData }, // Missing table.
        .{ .offset = quant + 5, .value = 0, .err = error.InvalidData },
        .{ .offset = scan + 7, .value = 1, .err = error.InvalidData }, // Duplicate component.
        .{ .offset = scan + 6, .value = 0x33, .err = error.InvalidData }, // Missing Huffman tables.
    };
    for (cases) |case| {
        @memcpy(&bytes, original);
        bytes[case.offset] = case.value;
        try std.testing.expectError(case.err, decode(a, &bytes, .{}));
    }
}

test "JPEG progressive components retain their quantizers across later table definitions" {
    const original = @embedFile("../fixtures/jpeg-progressive.jpg");
    const bytes = try a.alloc(u8, original.len + 69);
    defer a.free(bytes);
    const end = original.len - 2;
    @memcpy(bytes[0..end], original[0..end]);
    @memcpy(bytes[end..][0..5], "\xff\xdb\x00\x43\x00");
    @memset(bytes[end + 5 ..][0..64], 1);
    @memcpy(bytes[end + 69 ..], "\xff\xd9");
    var decoder = try jpeg.Decoder.init(a, bytes, .{});
    defer decoder.deinit();
    while (!try decoder.step(2048)) {}
    try std.testing.expectEqualSlices(
        u8,
        pixels(@embedFile("../fixtures/jpeg-progressive-reference.ppm")),
        std.mem.sliceAsBytes(decoder.image.?.pixels),
    );
}

test "JPEG mutations remain bounded and do not leak across failure phases" {
    var random = std.Random.DefaultPrng.init(81239);
    inline for (.{ "baseline", "progressive", "progressive-restart" }) |name| {
        const original = @embedFile("../fixtures/jpeg-" ++ name ++ ".jpg");
        var bytes: [original.len]u8 = undefined;
        for (0..1000) |iteration| {
            @memcpy(&bytes, original);
            for (0..1 + iteration % 4) |_|
                bytes[random.random().uintLessThan(usize, bytes.len)] ^= random.random().int(u8);
            var budget: Budget = .{ .parent = a, .limit = 1024 * 1024 };
            decode(budget.allocator(), &bytes, .{ .max_page_pixels = 100_000, .max_jpeg_blocks = 10_000 }) catch |err| switch (err) {
                error.InvalidData, error.Unsupported, error.LimitExceeded, error.OutOfMemory => {},
                else => return err,
            };
            try std.testing.expectEqual(@as(usize, 0), budget.live);
        }
    }
}

test "JPEG layer dimensions are checked before output allocation" {
    const original = @embedFile("../fixtures/jpeg-baseline.djvu");
    var bytes: [original.len]u8 = original.*;
    bytes[25] = 38; // INFO width disagrees with JPEG; neither is a valid reduction.
    var doc = try Document.open(a, &bytes, .{});
    defer doc.deinit();
    var job = try Job.init(&doc, 0, .{});
    defer job.deinit();
    try std.testing.expectError(error.InvalidData, job.step(2048));
    try std.testing.expect(job.jpeg_decoder.?.image == null);
}

test "JPEG background can be reduced without a foreground mask" {
    const original = @embedFile("../fixtures/jpeg-baseline.djvu");
    var bytes: [original.len]u8 = original.*;
    var reference = try Document.open(a, original, .{});
    defer reference.deinit();
    const info = try reference.info(0);
    var small = try Job.init(&reference, 0, .{});
    defer small.deinit();
    while (try small.step(127) != .done) {}
    const expected = try small.pixels();
    std.mem.writeInt(u16, bytes[24..26], @intCast(info.width * 3), .big);
    std.mem.writeInt(u16, bytes[26..28], @intCast(info.height * 3), .big);
    var doc = try Document.open(a, &bytes, .{});
    defer doc.deinit();
    var job = try Job.init(&doc, 0, .{});
    defer job.deinit();
    while (try job.step(17) != .done) {}
    const actual = try job.pixels();
    try std.testing.expectEqual(info.width * info.height * 9 * 4, actual.len);
    // Pixel centres in the expanded background retain the original RGB exactly.
    for (0..info.height) |y| for (0..info.width) |x| {
        const from = (y * info.width + x) * 4;
        const to = ((3 * y + 1) * (3 * info.width) + 3 * x + 1) * 4;
        try std.testing.expectEqualSlices(u8, expected[from..][0..4], actual[to..][0..4]);
    };
}

test "JPEG decoders interleave without shared state and cancellation frees progressive buffers" {
    var first = try jpeg.Decoder.init(a, @embedFile("../fixtures/jpeg-progressive.jpg"), .{});
    defer first.deinit();
    var second = try jpeg.Decoder.init(a, @embedFile("../fixtures/jpeg-cmyk.jpg"), .{});
    defer second.deinit();
    while (!first.done or !second.done) {
        _ = try first.step(1);
        _ = try second.step(193);
    }
    try std.testing.expectEqualSlices(
        u8,
        pixels(@embedFile("../fixtures/jpeg-progressive-reference.ppm")),
        std.mem.sliceAsBytes(first.image.?.pixels),
    );
    try std.testing.expectEqualSlices(
        u8,
        pixels(@embedFile("../fixtures/jpeg-cmyk-reference.ppm")),
        std.mem.sliceAsBytes(second.image.?.pixels),
    );
    var budget: Budget = .{ .parent = a, .limit = 1024 * 1024 };
    var doc = try Document.open(budget.allocator(), @embedFile("../fixtures/jpeg-progressive.djvu"), .{});
    defer doc.deinit();
    const baseline = budget.live;
    var job = try Job.init(&doc, 0, .{});
    for (0..20) |_| try std.testing.expectEqual(.progress, try job.step(64));
    try std.testing.expect(budget.live > baseline + 10_000);
    job.cancel();
    try std.testing.expectError(error.Cancelled, job.step(64));
    try std.testing.expectError(error.Cancelled, job.pixels());
    job.deinit();
    try std.testing.expectEqual(baseline, budget.live);
    var resumed = try Job.init(&doc, 0, .{});
    defer resumed.deinit();
    while (try resumed.step(2048) != .done) {}
    try std.testing.expectEqual(@as(usize, 37 * 29 * 4), (try resumed.pixels()).len);
}
