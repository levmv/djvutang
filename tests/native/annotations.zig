const std = @import("std");
const Document = @import("../../src/document.zig").Document;
const Job = @import("../../src/job.zig").Job;
const annotation = @import("../../src/annotations.zig");
const Annotations = annotation.Annotations;
const Limits = @import("../../src/types.zig").Limits;
const Info = @import("../../src/iff.zig").Info;
const Budget = @import("../../src/budget.zig").Budget;
const a = std.testing.allocator;
const raw = @embedFile("../fixtures/annotations.raw");
const info: Info = .{ .width = 101, .height = 79, .dpi = 300, .rotation = 0 };

fn expectAnnotations(data: Annotations) !void {
    try std.testing.expectEqualStrings(raw, data.source);
    try std.testing.expectEqual(@as(usize, 6), data.areas.len);
    try std.testing.expectEqual(@as(?u32, 0x123456), data.view.background);
    try std.testing.expectEqualStrings("d175", data.view.zoom.?);
    try std.testing.expectEqualStrings("back", data.view.mode.?);
    try std.testing.expectEqualStrings("bottom", data.view.alignment.?.vertical);
    try std.testing.expectEqualStrings("Last title", data.metadataValue("Title").?);
    try std.testing.expectEqualStrings("A\nB", data.metadataValue("Author").?);
    try std.testing.expectEqualStrings("ordinary key", data.metadataValue("__proto__").?);
    try std.testing.expectEqualStrings("<rdf:RDF xmlns:rdf=\"urn:synthetic\"><title>α</title></rdf:RDF>", data.xmp.?);
    try std.testing.expectEqualStrings("Header", data.header.left.?);
    try std.testing.expectEqualStrings("Footer", data.footer.center.?);
    const area = data.areas[0];
    try std.testing.expectEqualStrings("https://example.invalid/α?q=1&b=2", area.href);
    try std.testing.expectEqualStrings("_blank", area.target.?);
    try std.testing.expectEqualStrings("Quote: \"; slash: \\; octal: α", area.comment);
    try std.testing.expectEqual(.solid, area.style.border.?.kind);
    try std.testing.expectEqual(@as(?u32, 0xabcdef), area.style.border.?.color);
    try std.testing.expectEqual(@as(?u8, 75), area.style.opacity);
    try std.testing.expect(area.style.always_visible);
    try std.testing.expectEqual(.oval, data.areas[1].shape);
    try std.testing.expectEqual(@as(usize, 3), data.areas[2].points.len);
    try std.testing.expect(data.areas[3].style.arrow);
    try std.testing.expectEqual(@as(?u32, 3), data.areas[3].style.line_width);
    try std.testing.expect(data.areas[4].style.pushpin);
    try std.testing.expectEqual(.shadow_eout, data.areas[5].style.border.?.kind);
    const span = data.expressions[area.expression];
    try std.testing.expect(std.mem.startsWith(u8, data.source[span.start..][0..span.length], "(maparea"));
    try std.testing.expectEqualStrings("(background #oops)", data.source[data.expressions[data.expressions.len - 1].start .. data.source.len - 1]);
}

test "ANTa ANTz and mixed chunks preserve source and expose all annotation kinds" {
    for ([_][]const u8{
        @embedFile("../fixtures/annotations-a.djvu"),
        @embedFile("../fixtures/annotations-z.djvu"),
        @embedFile("../fixtures/annotations-split.djvu"),
    }, 0..) |bytes, i| {
        var doc = try Document.open(a, bytes, .{});
        defer doc.deinit();
        var data = (try doc.annotations(0)).?;
        defer data.deinit();
        try expectAnnotations(data);
        try std.testing.expectEqual(@as(usize, if (i == 2) 2 else 1), data.chunks.len);
    }
    var legacy = try Document.open(a, @embedFile("../fixtures/annotations-legacy.djvu"), .{});
    defer legacy.deinit();
    var data = (try legacy.annotations(0)).?;
    defer data.deinit();
    try std.testing.expect(data.legacy_escapes);
    try std.testing.expectEqualStrings("C:\\query\\notes", data.metadataValue("path").?);
    try std.testing.expectEqualStrings("keep\\n", data.metadataValue("literal").?);
    try std.testing.expectEqualStrings("a\"b", data.metadataValue("quote").?);
}

test "annotation rotation is undone before the common page transform" {
    const bounds = [_][4]f64{ .{ 5, 61, 23, 11 }, .{ 7, 5, 11, 23 }, .{ 73, 7, 23, 11 }, .{ 83, 51, 11, 23 } };
    for ([_][]const u8{
        @embedFile("../fixtures/annotations-rot0.djvu"),
        @embedFile("../fixtures/annotations-rot1.djvu"),
        @embedFile("../fixtures/annotations-rot2.djvu"),
        @embedFile("../fixtures/annotations-rot3.djvu"),
    }, 0..) |bytes, rotation| {
        var doc = try Document.open(a, bytes, .{});
        defer doc.deinit();
        var data = (try doc.annotations(0)).?;
        defer data.deinit();
        const b = data.areas[0].bounds;
        try std.testing.expectEqualSlices(f64, &bounds[rotation], &.{ b.x, b.y, b.width, b.height });
        const t = try doc.transform(0, .{});
        const mapped = t.rect(b);
        try std.testing.expectEqual(@as(f64, 5), mapped.x);
        try std.testing.expectEqual(@as(f64, @floatFromInt(t.geometry.page_height)) - 18, mapped.y);
        const line = data.areas[3].points;
        const p = t.point(line[0]);
        try std.testing.expectEqual(@as(f64, 4), p.x);
        try std.testing.expectEqual(@as(f64, @floatFromInt(t.geometry.page_height)) - 6, p.y);
    }
}

test "shared annotation component type and local directives combine in source order" {
    var doc = try Document.open(a, @embedFile("../fixtures/annotations-shared.djvu"), .{});
    defer doc.deinit();
    var shared: usize = 0;
    for (doc.components.items) |entry| {
        if (entry.kind == .shared_annotations) shared += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), shared);
    var data = (try doc.annotations(0)).?;
    defer data.deinit();
    try std.testing.expectEqual(@as(usize, 7), data.areas.len);
    try std.testing.expectEqual(@as(usize, 2), data.chunks.len);
    try std.testing.expectEqualStrings("Shared book", data.metadataValue("Book").?);
    try std.testing.expectEqualStrings("A\nB", data.metadataValue("Author").?);
    try std.testing.expectEqualStrings("d175", data.view.zoom.?);
    var second = (try doc.annotations(1)).?;
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), second.areas.len);
    try std.testing.expectEqualStrings("Shared author", second.metadataValue("Author").?);
    // Dedicated shared annotation components must not prevent ordinary rendering.
    var job = try Job.init(&doc, 1, .{});
    defer job.deinit();
    while (try job.step(4096) != .done) {}
}

test "annotation snapshots outlive documents and errors stay independent of image jobs" {
    var saved: Annotations = undefined;
    {
        var doc = try Document.open(a, @embedFile("../fixtures/annotations-z.djvu"), .{});
        defer doc.deinit();
        saved = (try doc.annotations(0)).?;
    }
    defer saved.deinit();
    try expectAnnotations(saved);
    for ([_][]const u8{
        @embedFile("../fixtures/annotations-bad.djvu"),
        @embedFile("../fixtures/annotations-bzz-bad.djvu"),
    }) |bytes| {
        var doc = try Document.open(a, bytes, .{});
        defer doc.deinit();
        var job = try Job.init(&doc, 0, .{});
        defer job.deinit();
        _ = try job.step(1);
        try std.testing.expectError(error.InvalidData, doc.annotations(0));
        try std.testing.expectEqual(@as(?@import("../../src/text.zig").Text, null), try doc.text(0));
        while (try job.step(4096) != .done) {}
    }
    var absent = try Document.open(a, @embedFile("../fixtures/text-z.djvu"), .{});
    defer absent.deinit();
    try std.testing.expectEqual(@as(?Annotations, null), try absent.annotations(0));
    var empty = try Document.open(a, @embedFile("../fixtures/annotations-empty.djvu"), .{});
    defer empty.deinit();
    var data = (try empty.annotations(0)).?;
    defer data.deinit();
    try std.testing.expectEqual(@as(usize, 0), data.source.len);
    try std.testing.expectEqual(@as(usize, 0), data.expressions.len);
}

test "annotation syntax limits and invalid known constructs preserve bounded behavior" {
    for ([_][]const u8{ "(", ")", "(x \"bad)" }) |bytes|
        try std.testing.expectError(error.InvalidData, Annotations.decode(a, bytes, info, .{}));
    for ([_]Limits{ .{ .max_annotation_bytes = 20 }, .{ .max_annotation_nodes = 5 }, .{ .max_annotation_depth = 1 } }) |limits|
        try std.testing.expectError(error.LimitExceeded, Annotations.decode(a, raw, info, limits));
    for ([_][]const u8{
        @embedFile("../fixtures/annotations-a.djvu"),
        @embedFile("../fixtures/annotations-z.djvu"),
        @embedFile("../fixtures/annotations-split.djvu"),
    }) |bytes| {
        var doc = try Document.open(a, bytes, .{ .max_annotation_bytes = raw.len - 1 });
        defer doc.deinit();
        try std.testing.expectError(error.LimitExceeded, doc.annotations(0));
    }
    var compressed = try Document.open(a, @embedFile("../fixtures/annotations-z.djvu"), .{ .max_bzz_bytes = 20 });
    defer compressed.deinit();
    try std.testing.expectError(error.LimitExceeded, compressed.annotations(0));
    const huge = "(maparea \"\" \"\" (poly 0 0 1 1 999999999999999999 2)) (zoom d33) (maparea \"\" \"\" (rect -2147483648 -2147483648 2147483647 2147483647))";
    var data = try Annotations.decode(a, huge, info, .{});
    defer data.deinit();
    try std.testing.expectEqual(@as(usize, 1), data.areas.len);
    try std.testing.expectEqualStrings("d33", data.view.zoom.?);
    var nested = [_]u8{'('} ** 65 ++ [_]u8{')'} ** 65;
    try std.testing.expectError(error.LimitExceeded, Annotations.decode(a, &nested, info, .{}));
    var boundary = try Annotations.decode(a, nested[1..129], info, .{});
    boundary.deinit();
}

test "annotation recovery preserves original expressions and does not repair navigation identifiers" {
    const bytes = @embedFile("../fixtures/annotations-recovered.raw");
    for ([_][]const u8{
        @embedFile("../fixtures/annotations-recovered-a.djvu"),
        @embedFile("../fixtures/annotations-recovered-z.djvu"),
        @embedFile("../fixtures/annotations-recovered-split.djvu"),
    }) |file| {
        var data: Annotations = undefined;
        {
            var doc = try Document.open(a, file, .{});
            defer doc.deinit();
            data = (try doc.annotations(0)).?;
        }
        defer data.deinit();
        try std.testing.expect(data.has_replacements);
        try std.testing.expectEqualSlices(u8, bytes, data.bytes);
        try std.testing.expect(std.unicode.utf8ValidateSlice(data.source));
        try std.testing.expectEqualStrings("A�B", data.metadataValue("Title").?);
        try std.testing.expectEqualStrings("�X�", data.metadataValue("Escaped").?);
        try std.testing.expectEqualStrings("Ж🙂", data.metadataValue("Good").?);
        try std.testing.expectEqual(@as(usize, 3), data.metadata.len);
        try std.testing.expectEqual(@as(usize, 1), data.areas.len);
        try std.testing.expectEqualStrings("#1", data.areas[0].href);
        try std.testing.expectEqualStrings("C�D", data.areas[0].comment);
        const span = data.expressions[data.areas[0].expression];
        try std.testing.expectEqualStrings("(maparea \"#1\" \"C\xc2D\" (rect 5 7 23 11))", data.bytes[span.start..][0..span.length]);
        try std.testing.expectEqualStrings("d175", data.view.zoom.?);
        const json = try std.json.Stringify.valueAlloc(a, &data, .{});
        defer a.free(json);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
        defer parsed.deinit();
        for (parsed.value.object.get("bytes").?.array.items, data.bytes) |value, byte| try std.testing.expectEqual(byte, value.integer);
    }
    var escaped = try Annotations.decode(a, "(metadata (bad \"\\377\")) (maparea \"#�\" \"valid replacement character\" (rect 1 1 2 2))", info, .{});
    defer escaped.deinit();
    try std.testing.expect(escaped.has_replacements);
    try std.testing.expectEqualStrings("�", escaped.metadataValue("bad").?);
    try std.testing.expectEqualStrings("#�", escaped.areas[0].href);
    try std.testing.expectEqual(escaped.source.ptr, escaped.bytes.ptr);
}

test "annotation allocation failures and mutations release ownership" {
    for ([_][]const u8{
        @embedFile("../fixtures/annotations-z.djvu"),
        @embedFile("../fixtures/annotations-shared.djvu"),
        @embedFile("../fixtures/annotations-recovered-z.djvu"),
    }) |bytes|
        try std.testing.checkAllAllocationFailures(a, struct {
            fn run(allocator: std.mem.Allocator, input: []const u8) !void {
                var doc = try Document.open(allocator, input, .{});
                defer doc.deinit();
                var data = (try doc.annotations(0)).?;
                defer data.deinit();
                const json = try std.json.Stringify.valueAlloc(allocator, &data, .{});
                allocator.free(json);
            }
        }.run, .{bytes});
    var random = std.Random.DefaultPrng.init(0x414e547a);
    for (0..128) |_| {
        var bytes: [raw.len]u8 = raw.*;
        bytes[random.random().uintLessThan(usize, bytes.len)] ^= random.random().int(u8) | 1;
        var budget: Budget = .{ .parent = a, .limit = 256 * 1024 };
        if (Annotations.decode(budget.allocator(), &bytes, info, .{})) |value| {
            var data = value;
            data.deinit();
        } else |_| {}
        try std.testing.expectEqual(@as(usize, 0), budget.live);
    }
}
