const std = @import("std");
const Document = @import("../../src/document.zig").Document;
const Job = @import("../../src/job.zig").Job;
const iff = @import("../../src/iff.zig");
const a = std.testing.allocator;
const color = @embedFile("../fixtures/pm44.iw4");
const progressive = @embedFile("../fixtures/pm44-progressive.iw4");
const gray = @embedFile("../fixtures/bm44.iw4");

fn finish(job: *Job) !void {
    for (0..100_000) |_| {
        if (try job.step(2048) == .done) return;
        try std.testing.expectError(error.Busy, job.pixels());
    }
    return error.TestWorkLimit;
}

fn render(bytes: []const u8) !void {
    var doc = try Document.open(a, bytes, .{});
    defer doc.deinit();
    var job = try Job.init(&doc, 0, .{});
    defer job.deinit();
    try finish(&job);
}

const Part = struct { id: []const u8, data: []const u8 };
fn form(kind: []const u8, parts: []const Part) ![]u8 {
    var size: usize = 16;
    for (parts) |part| size += 8 + part.data.len + part.data.len % 2;
    const bytes = try a.alloc(u8, size);
    @memcpy(bytes[0..8], "AT&TFORM");
    std.mem.writeInt(u32, bytes[8..12], @intCast(size - 12), .big);
    @memcpy(bytes[12..16], kind);
    var pos: usize = 16;
    for (parts) |part| {
        @memcpy(bytes[pos..][0..4], part.id);
        std.mem.writeInt(u32, bytes[pos + 4 ..][0..4], @intCast(part.data.len), .big);
        @memcpy(bytes[pos + 8 ..][0..part.data.len], part.data);
        pos += 8 + part.data.len;
        if (part.data.len % 2 != 0) {
            bytes[pos] = 0;
            pos += 1;
        }
    }
    return bytes;
}

test "standalone IW44 uses image geometry with optional magic and no page dependencies" {
    inline for (.{ "pm44", "pm44-progressive", "bm44", "bm44-progressive" }) |name| {
        const original = @embedFile("../fixtures/" ++ name ++ ".iw4");
        const bare = comptime if (std.mem.startsWith(u8, original, "AT&T")) original[4..] else original;
        const prefixed = "AT&T" ++ bare;
        for ([_][]const u8{ bare, prefixed }) |bytes| {
            var doc = try Document.open(a, bytes, .{});
            defer doc.deinit();
            const info = try doc.info(0);
            try std.testing.expectEqual(@as(u32, 100), info.dpi);
            try std.testing.expectEqual(@as(u8, 22), info.gamma_tenths);
            try std.testing.expectEqual(@as(u2, 0), info.rotation);
            try std.testing.expectEqual(@as(usize, 1), doc.pageCount());
            try std.testing.expect(!doc.indirect);
            try std.testing.expect((try doc.nextMissing(0, .includes)) == null);
            try std.testing.expect((try doc.text(0)) == null);
            try std.testing.expect((try doc.annotations(0)) == null);
            try std.testing.expect((try doc.outline()) == null);
            try std.testing.expect((try Job.initThumbnail(&doc, 0)) == null);
            try std.testing.expectError(error.InvalidArgument, doc.info(1));
            var job = try Job.init(&doc, 0, .{});
            defer job.deinit();
            try finish(&job);
            const source = comptime if (std.mem.eql(u8, name, "pm44"))
                "color"
            else if (std.mem.eql(u8, name, "pm44-progressive"))
                "progressive"
            else if (std.mem.eql(u8, name, "bm44"))
                "gray"
            else
                "iw44-empty-parts";
            const ppm = @embedFile("../fixtures/" ++ source ++ "-expected.ppm");
            const rgb = ppm[std.mem.indexOf(u8, ppm, "\n255\n").? + 5 ..];
            const pixels = try job.pixels();
            try std.testing.expectEqual(rgb.len / 3 * 4, pixels.len);
            for (0..rgb.len / 3) |i| {
                try std.testing.expectEqualSlices(u8, rgb[i * 3 ..][0..3], pixels[i * 4 ..][0..3]);
                try std.testing.expectEqual(@as(u8, 255), pixels[i * 4 + 3]);
            }
        }
    }
}

test "IW44 optional chunks remain accessible and do not override image geometry or load INCL" {
    var chunks = try (try iff.root(gray)).children();
    const payload = (try chunks.next()).?.data;
    // Header color type is authoritative even in a PM44 wrapper.
    const bytes = try form("PM44", &.{
        .{ .id = "INFO", .data = "broken" },
        .{ .id = "PM44", .data = payload },
        .{ .id = "INCL", .data = "unused" },
        .{ .id = "JUNK", .data = "opaque" },
    });
    defer a.free(bytes);
    var doc = try Document.open(a, bytes, .{});
    defer doc.deinit();
    try std.testing.expectEqual(@as(u32, 37), (try doc.info(0)).width);
    try std.testing.expectEqual(@as(usize, 1), doc.components.items.len);
    try std.testing.expect((try doc.nextMissing(0, .includes)) == null);
    try std.testing.expectEqualStrings("opaque", (try doc.find(0, "JUNK")).?.data);
    try render(bytes);
    doc.limits.max_chunks = 3;
    try std.testing.expectError(error.LimitExceeded, doc.info(0));
}

test "IW44 requires its own image chunks and consecutive progressive serials" {
    var chunks = try (try iff.root(color)).children();
    const payload = (try chunks.next()).?.data;
    for ([_][]const Part{
        &.{},
        &.{.{ .id = "BG44", .data = payload }},
        &.{.{ .id = "BM44", .data = payload }},
        &.{ .{ .id = "PM44", .data = payload }, .{ .id = "BM44", .data = payload } },
        &.{ .{ .id = "PM44", .data = payload }, .{ .id = "PM44", .data = payload } },
    }) |parts| {
        const bytes = try form("PM44", parts);
        defer a.free(bytes);
        try std.testing.expectError(error.InvalidData, render(bytes));
    }
    var broken: [progressive.len]u8 = progressive.*;
    chunks = try (try iff.root(&broken)).children();
    _ = try chunks.next();
    broken[(try chunks.next()).?.offset + 8] = 2; // missing serial 1
    try std.testing.expectError(error.InvalidData, render(&broken));
    try std.testing.expectError(error.InvalidData, Document.open(a, @embedFile("../fixtures/plain.djvu")[4..], .{}));
}

test "IW44 malformed headers and exhausted entropy fail with bounded work" {
    var chunks = try (try iff.root(color)).children();
    const payload = (try chunks.next()).?.data;
    const Mutation = struct { offset: usize, value: u8, expected: anyerror };
    for ([_]Mutation{
        .{ .offset = 0, .value = 1, .expected = error.InvalidData },
        .{ .offset = 2, .value = 2, .expected = error.Unsupported },
        .{ .offset = 3, .value = 3, .expected = error.Unsupported },
        .{ .offset = 5, .value = 0, .expected = error.InvalidData },
    }) |mutation| {
        var bytes: [color.len]u8 = color.*;
        bytes[24 + mutation.offset] = mutation.value;
        try std.testing.expectError(mutation.expected, render(&bytes));
    }
    var header: [9]u8 = payload[0..9].*;
    header[1] = 0;
    // Empty arithmetic parts can be legal. Truncate actual coded coefficients
    // after a zero-slice first chunk so that ZP exhausts its bounded EOF padding.
    const tail = [_]u8{ 1, payload[1], payload[9], payload[10], payload[11] };
    const exhausted = try form("PM44", &.{ .{ .id = "PM44", .data = &header }, .{ .id = "PM44", .data = &tail } });
    defer a.free(exhausted);
    try std.testing.expectError(error.InvalidData, render(exhausted));
    const short = try form("PM44", &.{.{ .id = "PM44", .data = payload[0..8] }});
    defer a.free(short);
    try std.testing.expectError(error.InvalidData, render(short));
    try std.testing.expectError(error.LimitExceeded, Document.open(a, color, .{ .max_components = 0 }));
    var limited = try Document.open(a, color, .{ .max_page_pixels = 1024 });
    defer limited.deinit();
    try std.testing.expectError(error.LimitExceeded, limited.info(0));
    try std.testing.expectError(error.LimitExceeded, Job.init(&limited, 0, .{}));
    try std.testing.expect(!limited.busy);
}
