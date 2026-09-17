const std = @import("std");
const mmr = @import("../../src/mmr.zig");
const types = @import("../../src/types.zig");
const Document = @import("../../src/document.zig").Document;
const Job = @import("../../src/job.zig").Job;
const Budget = @import("../../src/budget.zig").Budget;
const eof = "000000000001000000000001";

fn mask(file: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, file, "Smmr").? + 8;
    const length = std.mem.readInt(u32, file[start - 4 ..][0..4], .big);
    return file[start..][0..length];
}

fn encoded(a: std.mem.Allocator, width: u16, height: u16, bits: []const u8) ![]u8 {
    const data = try a.alloc(u8, 8 + (bits.len + 7) / 8);
    @memset(data, 0);
    @memcpy(data[0..3], "MMR");
    std.mem.writeInt(u16, data[4..6], width, .big);
    std.mem.writeInt(u16, data[6..8], height, .big);
    for (bits, 0..) |b, i| {
        std.debug.assert(b == '0' or b == '1');
        data[8 + i / 8] |= @as(u8, b - '0') << @intCast(7 - i % 8);
    }
    return data;
}

fn decode(a: std.mem.Allocator, data: []const u8, limits: types.Limits) !void {
    var decoder = try mmr.Decoder.init(a, data, limits);
    defer decoder.deinit();
    for (0..100_000) |_| if (try decoder.step(127)) return;
    return error.TestWorkLimit;
}

test "MMR reproduces independent PBMs across steps stripes inversion and long runs" {
    const a = std.testing.allocator;
    inline for (.{
        "mmr",
        "mmr-inverted",
        "mmr-striped",
        "mmr-striped-inverted",
        "mmr-tiny",
        "mmr-long",
        "mmr-uncompressed",
    }) |name| {
        const pbm = @embedFile("../fixtures/" ++ name ++ ".pbm");
        const end = std.mem.indexOfScalarPos(u8, pbm, 3, '\n').?;
        var dimensions = std.mem.tokenizeScalar(u8, pbm[3..end], ' ');
        const width = try std.fmt.parseInt(u32, dimensions.next().?, 10);
        const height = try std.fmt.parseInt(u32, dimensions.next().?, 10);
        const source = pbm[end + 1 ..];
        for ([_]usize{ 1, 17, 2048 }) |work| {
            var decoder = try mmr.Decoder.init(a, mask(@embedFile("../fixtures/" ++ name ++ ".djvu")), .{});
            defer decoder.deinit();
            while (!try decoder.step(work)) {}
            var image = decoder.takeImage();
            defer image.deinit(a);
            try std.testing.expectEqual(width, image.width);
            try std.testing.expectEqual(height, image.height);
            for (0..height) |y| for (0..width) |x| {
                const expected: u1 = @truncate(source[y * ((width + 7) / 8) + x / 8] >> @intCast(7 - x % 8));
                const index = y * width + x;
                const actual: u1 = @truncate(image.pixels[index / 8] >> @intCast(index % 8));
                try std.testing.expectEqual(expected, actual);
            };
        }
    }
}

test "MMR bounds codewords runs image extent and optional extensions" {
    const a = std.testing.allocator;
    const cases = [_]struct { bits: []const u8, err: types.Error }{
        .{ .bits = "000000000000", .err = error.InvalidData }, // Invalid mode / early EOFB.
        .{ .bits = eof, .err = error.InvalidData },
        .{ .bits = "011" ++ eof, .err = error.InvalidData }, // V(+1) beyond width 1.
        .{ .bits = "0000010" ++ eof, .err = error.InvalidData }, // V(-3) before the row.
        .{ .bits = "0010011010111" ++ eof, .err = error.InvalidData }, // H: white 0, black 2.
        .{ .bits = "001001101010000110111" ++ eof, .err = error.InvalidData }, // H: two zero runs.
        .{ .bits = "001000111", .err = error.InvalidData }, // H: missing second run.
        .{ .bits = "0000001000", .err = error.Unsupported }, // Reserved extension.
        .{ .bits = "000000111111", .err = error.InvalidData }, // Literal pixels past the image.
        .{ .bits = "1" ++ "000000000001", .err = error.InvalidData }, // Half EOFB.
        .{ .bits = "1" ++ eof ++ "1", .err = error.InvalidData }, // Nonzero padding after EOFB.
    };
    for (cases) |case| {
        const data = try encoded(a, 1, 1, case.bits);
        defer a.free(data);
        try std.testing.expectError(case.err, decode(a, data, .{}));
    }
    for ([_][]const u8{ "1", "11111111", "1" ++ eof, "1" ++ eof ++ "0000000000000000" }) |bits| {
        // Known height permits an omitted EOFB with only final-byte padding.
        const data = try encoded(a, 1, 1, bits);
        defer a.free(data);
        try decode(a, data, .{});
    }
    const bad_padding = try encoded(a, 1, 1, "101");
    defer a.free(bad_padding);
    try std.testing.expectError(error.InvalidData, decode(a, bad_padding, .{}));
}

test "MMR literal mode resumes compressed runs and crosses rows" {
    const a = std.testing.allocator;
    // A literal black pixel, exit into a black run, V(0) fills the first row.
    // On the next row V(0), V(0) reproduce the all-black reference line.
    const data = try encoded(a, 7, 2, "0000001111" ++ "1" ++ "00000011" ++ "1" ++ "11" ++ eof);
    defer a.free(data);
    var decoder = try mmr.Decoder.init(a, data, .{});
    defer decoder.deinit();
    while (!try decoder.step(1)) {}
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x3f }, decoder.image.pixels);
}

test "MMR framed stripes reject truncations and malformed headers without leaking" {
    const a = std.testing.allocator;
    const original = mask(@embedFile("../fixtures/mmr-striped.djvu"));
    for (0..original.len) |length|
        try std.testing.expectError(error.InvalidData, decode(a, original[0..length], .{}));
    const bytes = try a.dupe(u8, original);
    defer a.free(bytes);
    for ([_]usize{ 0, 4, 6, 8, 10 }) |field| {
        @memcpy(bytes, original);
        if (field == 0) bytes[0] = 'X' else if (field == 10) @memset(bytes[10..14], 0xff) else @memset(bytes[field..][0..2], 0);
        try std.testing.expectError(error.InvalidData, decode(a, bytes, .{}));
    }
    @memcpy(bytes, original);
    bytes[3] |= 4;
    try std.testing.expectError(error.Unsupported, decode(a, bytes, .{}));
    try std.testing.expectError(error.LimitExceeded, decode(a, original, .{ .max_page_pixels = 1 }));
    try std.testing.expectError(error.LimitExceeded, decode(a, original, .{ .max_records = 1 }));
    for (0..original.len) |i| {
        @memcpy(bytes, original);
        bytes[i] ^= @as(u8, 1) << @intCast(i % 8);
        decode(a, bytes, .{ .max_page_pixels = 4096, .max_records = 4096 }) catch |err| switch (err) {
            error.InvalidData, error.Unsupported, error.LimitExceeded => {},
            else => return err,
        };
    }
}

test "MMR cancellation releases decoder state and completed tiles borrow the mask" {
    var budget: Budget = .{ .parent = std.testing.allocator, .limit = 1024 * 1024 };
    {
        var doc = try Document.open(budget.allocator(), @embedFile("../fixtures/mmr-striped.djvu"), .{});
        defer doc.deinit();
        const baseline = budget.live;
        {
            var job = try Job.init(&doc, 0, .{});
            defer job.deinit();
            _ = try job.step(17);
            try std.testing.expect(job.mmr_decoder != null);
            job.cancel();
            try std.testing.expectError(error.Cancelled, job.step(1));
        }
        try std.testing.expectEqual(baseline, budget.live);
        var job = try Job.init(&doc, 0, .{});
        defer job.deinit();
        while (try job.step(71) != .done) {}
        const bits = job.bitmap.?.pixels.ptr;
        try std.testing.expectEqual(bits, job.renderer.?.mask.ptr);
        try job.restart(.{ .region = .{ .x = 0, .y = 0, .width = 1, .height = 1 } });
        while (try job.step(1) != .done) {}
        try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, try job.pixels());
        try std.testing.expectEqual(bits, job.renderer.?.mask.ptr);
    }
    try std.testing.expectEqual(@as(usize, 0), budget.live);
}

test "MMR dimensions and competing mask chunks cannot silently change the image" {
    const original = @embedFile("../fixtures/mmr-foreground.djvu");
    var bytes: [original.len]u8 = original.*;
    const smmr = std.mem.indexOf(u8, &bytes, "Smmr").?;
    bytes[smmr + 8 + 5] -= 1;
    {
        var doc = try Document.open(std.testing.allocator, &bytes, .{});
        defer doc.deinit();
        var job = try Job.init(&doc, 0, .{});
        defer job.deinit();
        try std.testing.expectError(error.InvalidData, job.step(1));
    }
    const fg = std.mem.indexOf(u8, &bytes, "FG44").?;
    for ([_][]const u8{ "Sjbz", "Smmr" }) |tag| {
        bytes = original.*;
        @memcpy(bytes[fg..][0..4], tag);
        var doc = try Document.open(std.testing.allocator, &bytes, .{});
        defer doc.deinit();
        try std.testing.expectError(error.InvalidData, Job.init(&doc, 0, .{}));
    }
}
