const std = @import("std");
const Document = @import("../../src/document.zig").Document;
const Job = @import("../../src/job.zig").Job;
const Budget = @import("../../src/budget.zig").Budget;
const text_module = @import("../../src/text.zig");
const Text = text_module.Text;
const geometry = @import("../../src/geometry.zig");
const Limits = @import("../../src/types.zig").Limits;
const a = std.testing.allocator;

fn expectZone(expected: []const u8, text: Text, index: usize) !void {
    const value = try text.zoneText(a, index);
    defer a.free(value);
    try std.testing.expectEqualStrings(expected, value);
}

fn expectTree(text: Text, node: std.json.Value, parent: u32, next: *usize) !void {
    const index = next.*;
    next.* += 1;
    const z = text.zones[index];
    try std.testing.expectEqualStrings(node.object.get("kind").?.string, @tagName(z.kind));
    try std.testing.expectEqual(parent, z.parent);
    const bounds = node.object.get("bounds").?.object;
    inline for (.{ "x", "y", "width", "height" }) |field|
        try std.testing.expectEqual(bounds.get(field).?.integer, @as(i64, @field(z.bounds, field)));
    const children = node.object.get("children").?;
    if (children == .array) {
        for (children.array.items) |child| try expectTree(text, child, @intCast(index), next);
    } else {
        const expected = try std.fmt.allocPrint(a, "{s}{s}", .{ children.string, if (z.kind == .word) " " else "" });
        defer a.free(expected);
        try expectZone(expected, text, index);
    }
    try std.testing.expectEqual(next.*, z.subtree_end);
}

test "TXTa and TXTz preserve the full UTF8 text byte spans and all seven zone levels" {
    const expected = try std.json.parseFromSlice(std.json.Value, a, @embedFile("../fixtures/text-expected.json"), .{});
    defer expected.deinit();
    for ([_][]const u8{
        @embedFile("../fixtures/text-a.djvu"),
        @embedFile("../fixtures/text-z.djvu"),
        @embedFile("../fixtures/text-rotated.djvu"),
    }) |bytes| {
        var doc = try Document.open(a, bytes, .{});
        defer doc.deinit();
        var t = (try doc.text(0)).?;
        defer t.deinit(a);
        try std.testing.expectEqualStrings(expected.value.object.get("text").?.string, t.bytes);
        var next: usize = 0;
        try expectTree(t, expected.value.object.get("tree").?, text_module.no_parent, &next);
        try std.testing.expectEqual(t.zones.len, next);
        try expectZone("🙂", t, 9);
        try std.testing.expectEqual(@as(u32, 4), t.zones[9].text_length);
        try std.testing.expectError(error.InvalidArgument, t.zoneText(a, t.zones.len));
        try std.testing.expect(!t.has_replacements);
    }
    var doc = try Document.open(a, @embedFile("../fixtures/unicode-text.djvu"), .{});
    defer doc.deinit();
    var t = (try doc.text(0)).?;
    defer t.deinit(a);
    try std.testing.expectEqualStrings("AЖB", t.bytes);
    try expectZone("Ж", t, 1);
}

test "absent empty and unzoned text remain distinct and preserve separators and BOM" {
    var plain = try Document.open(a, @embedFile("../fixtures/shared.djvu"), .{});
    defer plain.deinit();
    try std.testing.expectEqual(@as(?Text, null), try plain.text(0));
    for ([_][]const u8{
        @embedFile("../fixtures/text-empty.djvu"),
        @embedFile("../fixtures/text-only.djvu"),
    }, 0..) |bytes, i| {
        var doc = try Document.open(a, bytes, .{});
        defer doc.deinit();
        var t = (try doc.text(0)).?;
        defer t.deinit(a);
        try std.testing.expectEqual(@as(usize, 0), t.zones.len);
        try std.testing.expectEqualStrings(if (i == 0) "" else "\u{feff}A\x00Ж\r\nB\x0bC\x1dD\x1eE\x1f🙂", t.bytes);
    }
}

test "replacement decoding preserves byte ranges and valid scalars around malformed sequences" {
    const utf8 = @import("../../src/utf8.zig");
    for ([_]struct { bytes: []const u8, expected: []const u8 }{
        .{ .bytes = "\xef\xbb\xbfA\x00Ж🙂\xef\xbf\xbd", .expected = "\u{feff}A\x00Ж🙂�" },
        .{ .bytes = "A\x95B\xb1C\xb0D", .expected = "A�B�C�D" },
        .{ .bytes = "\xc0\xaf\xed\xa0\x80", .expected = "�����" },
        .{ .bytes = "\xf4\x90\x80\x80Z", .expected = "����Z" },
        .{ .bytes = "\xe2\x82", .expected = "�" },
        .{ .bytes = "\xe2\x82X\xc2Y\xf0\x9f\x92", .expected = "�X�Y�" },
        .{ .bytes = "\xe0\x9f\xbf\xf0\x8f\xbf\xbf", .expected = "�������" },
        .{ .bytes = "\xe0\xa0\x80\xed\x9f\xbf\xf0\x90\x80\x80\xf4\x8f\xbf\xbf", .expected = "\u{800}\u{d7ff}\u{10000}\u{10ffff}" },
    }) |case| {
        const output = try utf8.toUtf8(a, case.bytes);
        defer a.free(output);
        try std.testing.expectEqualStrings(case.expected, output);
    }
    for ([_][]const u8{ "Ж", "漢", "🙂" }) |scalar| {
        for (1..scalar.len) |i| try std.testing.expect(!utf8.boundary(scalar, i));
    }
    // Orphan continuations and prefixes broken by a later byte may have their
    // own producer zones. Splitting one does not hide a valid scalar.
    for ([_][]const u8{ "\x95\x95", "\xe2\x82X", "\xf4\x90\x80\x80" }) |bytes| {
        for (0..bytes.len + 1) |i| try std.testing.expect(utf8.boundary(bytes, i));
    }
}

test "damaged TXTa and TXTz retain the original tree and copy each zone after recovery" {
    const raw = @embedFile("../fixtures/text-recovered.raw");
    const expected = try std.json.parseFromSlice(std.json.Value, a, @embedFile("../fixtures/text-recovered.json"), .{});
    defer expected.deinit();
    var original = try Text.decode(a, @embedFile("../fixtures/text.raw"), false, 79, .{});
    defer original.deinit(a);
    for ([_][]const u8{
        @embedFile("../fixtures/text-recovered-a.djvu"),
        @embedFile("../fixtures/text-recovered-z.djvu"),
    }) |bytes| {
        var snapshot: Text = undefined;
        {
            var doc = try Document.open(a, bytes, .{});
            defer doc.deinit();
            var job = try Job.init(&doc, 0, .{});
            defer job.deinit();
            _ = try job.step(1);
            snapshot = (try doc.text(0)).?;
            errdefer snapshot.deinit(a);
            while (try job.step(4096) != .done) {}
        }
        defer snapshot.deinit(a);
        try std.testing.expect(snapshot.has_replacements);
        try std.testing.expectEqualSlices(u8, raw[3..66], snapshot.bytes);
        try std.testing.expectEqualDeep(original.zones, snapshot.zones);
        const display = try snapshot.toUtf8(a);
        defer a.free(display);
        try std.testing.expectEqualStrings(expected.value.object.get("text").?.string, display);
        try expectZone("�Ж� ", snapshot, 5);
        try expectZone("�", snapshot, 7);
        try expectZone("\u{301}", snapshot, 8);
        try expectZone("����", snapshot, 9);
        const later = try original.zoneText(a, 11);
        defer a.free(later);
        try expectZone(later, snapshot, 11);
    }
}

test "text errors and image errors stay independent and text outlives its document" {
    var snapshot: Text = undefined;
    {
        const source = @embedFile("../fixtures/text-z.djvu");
        var bytes: [source.len]u8 = source.*;
        const pos = std.mem.indexOf(u8, &bytes, "Sjbz").?;
        @memcpy(bytes[pos..][0..4], "BGzz");
        var doc = try Document.open(a, &bytes, .{});
        defer doc.deinit();
        snapshot = (try doc.text(0)).?;
        errdefer snapshot.deinit(a);
        try std.testing.expectError(error.Unsupported, Job.init(&doc, 0, .{}));
    }
    defer snapshot.deinit(a);
    try expectZone("🙂", snapshot, 9);
    var doc = try Document.open(a, @embedFile("../fixtures/bad-text.djvu"), .{});
    defer doc.deinit();
    var job = try Job.init(&doc, 0, .{});
    defer job.deinit();
    try std.testing.expectEqual(.progress, try job.step(1));
    try std.testing.expectError(error.InvalidData, doc.text(0));
    try std.testing.expect(doc.busy);
    while (try job.step(4096) != .done) {}
    try std.testing.expectEqual(@as(usize, 37 * 29 * 4), (try job.pixels()).len);
}

test "invalid text spans UTF8 geometry tree tails and versions fail within limits" {
    const raw = @embedFile("../fixtures/text.raw");
    const tree = 3 + 63 + 1;
    const patches = [_]struct { offset: usize, byte: u8 }{
        .{ .offset = tree, .byte = 0 }, // unknown type
        .{ .offset = tree + 5, .byte = 0x7f }, // negative width
        .{ .offset = tree + 11, .byte = 0xff }, // impossible text length
        .{ .offset = tree + 5 * 17 + 10, .byte = 2 }, // inside the UTF-8 Ж
        .{ .offset = tree + 5 * 17 + 13, .byte = 2 }, // span ends inside Ж
    };
    for (patches) |patch| {
        var bytes: [raw.len]u8 = raw.*;
        bytes[patch.offset] = patch.byte;
        try std.testing.expectError(error.InvalidData, Text.decode(a, &bytes, false, 79, .{}));
    }
    var version: [raw.len]u8 = raw.*;
    version[tree - 1] = 2;
    try std.testing.expectError(error.Unsupported, Text.decode(a, &version, false, 79, .{}));
    const trailing = raw.* ++ [_]u8{0};
    try std.testing.expectError(error.InvalidData, Text.decode(a, &trailing, false, 79, .{}));
    for ([_]Limits{ .{ .max_text_bytes = 2 }, .{ .max_text_zones = 2 }, .{ .max_text_depth = 3 } }) |limits|
        try std.testing.expectError(error.LimitExceeded, Text.decode(a, raw, false, 79, limits));
    // Negative/off-page boxes are meaningful data and are not silently clipped.
    var outside: [raw.len]u8 = raw.*;
    outside[tree + 1] = 0x7f;
    outside[tree + 2] = 0xfe;
    var t = try Text.decode(a, &outside, false, 79, .{});
    defer t.deinit(a);
    try std.testing.expectEqual(@as(i32, -2), t.zones[0].bounds.x);
    for (0..raw.len) |len| {
        if (Text.decode(a, raw[0..len], false, 79, .{})) |value| {
            var result = value;
            result.deinit(a);
            try std.testing.expect(len == tree - 1 or len == tree);
        } else |_| {}
    }
    for ([_]usize{ 64, 65 }) |depth| {
        var nested = [_]u8{0} ** (4 + 65 * 17);
        nested[3] = 1;
        for (0..depth) |i| {
            const p = 4 + i * 17;
            nested[p] = 1;
            for ([_]usize{ 1, 3, 5, 7, 9 }) |field| nested[p + field] = 0x80;
            nested[p + 16] = if (i + 1 < depth) 1 else 0;
        }
        if (depth == 65) {
            try std.testing.expectError(error.LimitExceeded, Text.decode(a, &nested, false, 79, .{}));
        } else {
            var deep = try Text.decode(a, nested[0 .. 4 + depth * 17], false, 79, .{});
            defer deep.deinit(a);
            try std.testing.expectEqual(depth, deep.zones[0].subtree_end);
        }
    }
    // Two competing text chunks have no unambiguous interpretation.
    const source = @embedFile("../fixtures/text-z.djvu");
    // The source omits its final odd-chunk padding; restore it before appending.
    const next = source.len + source.len % 2;
    var duplicate = [_]u8{0} ** (next + 8 + raw.len + raw.len % 2);
    @memcpy(duplicate[0..source.len], source);
    std.mem.writeInt(u32, duplicate[8..12], @intCast(duplicate.len - 12), .big);
    @memcpy(duplicate[next..][0..4], "TXTa");
    std.mem.writeInt(u32, duplicate[next + 4 ..][0..4], raw.len, .big);
    @memcpy(duplicate[next + 8 ..][0..raw.len], raw);
    var duplicate_doc = try Document.open(a, &duplicate, .{});
    defer duplicate_doc.deinit();
    try std.testing.expectError(error.InvalidData, duplicate_doc.text(0));
}

test "text allocation failures and bounded mutations release all ownership" {
    for ([_][]const u8{
        @embedFile("../fixtures/text-a.djvu"),
        @embedFile("../fixtures/text-z.djvu"),
        @embedFile("../fixtures/text-recovered-z.djvu"),
    }) |bytes|
        try std.testing.checkAllAllocationFailures(a, struct {
            fn run(allocator: std.mem.Allocator, input: []const u8) !void {
                var doc = try Document.open(allocator, input, .{});
                defer doc.deinit();
                var t = (try doc.text(0)).?;
                defer t.deinit(allocator);
                const display = try t.toUtf8(allocator);
                defer allocator.free(display);
                const word = try t.zoneText(allocator, 5);
                allocator.free(word);
            }
        }.run, .{bytes});
    const raw = @embedFile("../fixtures/text-z.djvu");
    var random = std.Random.DefaultPrng.init(0x5458547a);
    for (0..128) |_| {
        var bytes: [raw.len]u8 = raw.*;
        bytes[random.random().uintLessThan(usize, bytes.len)] ^= random.random().int(u8) | 1;
        var budget: Budget = .{ .parent = a, .limit = 128 * 1024 };
        {
            var doc = Document.open(budget.allocator(), &bytes, .{ .max_text_bytes = 4096, .max_text_zones = 64 }) catch continue;
            defer doc.deinit();
            if (doc.text(0)) |maybe| {
                if (maybe) |value| {
                    var t = value;
                    t.deinit(budget.allocator());
                }
            } else |_| {}
        }
        try std.testing.expectEqual(@as(usize, 0), budget.live);
    }
}

test "continuous text transforms and inverse points match raster sampling including tile padding" {
    var doc = try Document.open(a, @embedFile("../fixtures/text-z.djvu"), .{});
    defer doc.deinit();
    var job = try Job.init(&doc, 0, .{});
    defer job.deinit();
    while (try job.step(4096) != .done) {}
    const pbm = @embedFile("../fixtures/text-mask.pbm")["P4\n101 79\n".len..];
    for ([_]u16{ 1, 2, 3, 4, 256 }) |ss| for (0..4) |rotation| {
        const full = try doc.geometry(0, .{ .subsample = ss, .rotation = @intCast(rotation) });
        const region: geometry.Region = .{
            .x = full.width / 3,
            .y = full.height / 3,
            .width = full.width - full.width / 3,
            .height = full.height - full.height / 3,
        };
        const options: geometry.Options = .{ .subsample = ss, .rotation = @intCast(rotation), .region = region };
        const t = try doc.transform(0, options);
        try job.restart(options);
        while (try job.step(4096) != .done) {}
        const pixels = try job.pixels();
        for (0..region.height) |y| for (0..region.width) |x| {
            // Derive a pixel's source coverage from the continuous inverse,
            // independently of the compositor's integer sample indexing.
            const center = t.unmap(.{ .x = @as(f64, @floatFromInt(x)) + 0.5, .y = @as(f64, @floatFromInt(y)) + 0.5 });
            const left: i64 = @intFromFloat(@round(center.x - @as(f64, @floatFromInt(ss)) / 2));
            const top: i64 = @intFromFloat(@round(center.y - @as(f64, @floatFromInt(ss)) / 2));
            var ink: u32 = 0;
            for (0..ss) |dy| for (0..ss) |dx| {
                const sx = left + @as(i64, @intCast(dx));
                const sy = top + @as(i64, @intCast(dy));
                if (sx < 0 or sy < 0 or sx >= 101 or sy >= 79) continue;
                ink += (pbm[@as(usize, @intCast(sy)) * 13 + @as(usize, @intCast(sx)) / 8] >> @as(u3, @intCast(7 - @mod(sx, 8)))) & 1;
            };
            const area = @as(u32, ss) * ss;
            const expected: u8 = @intCast(255 - (ink * 255 + area / 2) / area);
            try std.testing.expectEqual(expected, pixels[(y * region.width + x) * 4]);
        };
        for ([_]geometry.Point{ .{ .x = 0, .y = 0 }, .{ .x = 101, .y = 79 }, .{ .x = -7.25, .y = 84.5 } }) |p| {
            const restored = t.unmap(t.point(p));
            try std.testing.expectApproxEqAbs(p.x, restored.x, 1e-9);
            try std.testing.expectApproxEqAbs(p.y, restored.y, 1e-9);
        }
        var info = try doc.info(0);
        for (0..4) |info_rotation| {
            info.rotation = @intCast(info_rotation);
            const composed = try geometry.Transform.init(info, .{ .subsample = ss, .rotation = @intCast(rotation) });
            info.rotation = 0;
            const single = try geometry.Transform.init(
                info,
                .{ .subsample = ss, .rotation = @intCast((info_rotation + rotation) % 4) },
            );
            try std.testing.expectEqualSlices(f64, &single.matrix, &composed.matrix);
        }
    };
}
