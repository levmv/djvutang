const std = @import("std");
const Document = @import("../../src/document.zig").Document;
const Outline = @import("../../src/outline.zig").Outline;
const Link = @import("../../src/links.zig").Link;
const Budget = @import("../../src/budget.zig").Budget;
const Job = @import("../../src/job.zig").Job;
const Limits = @import("../../src/types.zig").Limits;
const a = std.testing.allocator;

fn expectOutline(outline: Outline) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, @embedFile("../fixtures/outline-expected.json"), .{});
    defer parsed.deinit();
    const expected = parsed.value.object.get("entries").?.array.items;
    try std.testing.expectEqual(expected.len, outline.entries.len);
    for (outline.entries, expected) |entry, node| {
        const value = node.object;
        try std.testing.expectEqualStrings(value.get("title").?.string, entry.title);
        try std.testing.expectEqualStrings(value.get("href").?.string, entry.href);
        const parent = value.get("parent").?;
        try std.testing.expectEqual(if (parent == .null) @as(?u32, null) else @as(u32, @intCast(parent.integer)), entry.parent);
        try std.testing.expectEqual(@as(u32, @intCast(value.get("subtreeEnd").?.integer)), entry.subtree_end);
    }
}

test "NAVM reads a preorder forest from bundled indirect and single-page roots" {
    inline for (.{
        "outline.djvu",
        "outline-indirect/index.djvu",
        "outline-late.djvu",
        "outline-single.djvu",
        "outline-djvused.djvu",
    }) |name| {
        var doc = try Document.open(a, @embedFile("../fixtures/" ++ name), .{});
        defer doc.deinit();
        var outline = (try doc.outline()).?;
        defer outline.deinit(a);
        try expectOutline(outline);
        if (doc.indirect) {
            try std.testing.expectEqual(@as(usize, 0), doc.suppliedBytes());
            for (doc.components.items) |component| try std.testing.expect(component.form == null);
        }
    }
}

test "absent empty duplicate and corrupt outlines remain independent of pages" {
    var absent = try Document.open(a, @embedFile("../fixtures/text-z.djvu"), .{});
    defer absent.deinit();
    try std.testing.expectEqual(@as(?Outline, null), try absent.outline());
    var empty = try Document.open(a, @embedFile("../fixtures/outline-empty.djvu"), .{});
    defer empty.deinit();
    var outline = (try empty.outline()).?;
    defer outline.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), outline.entries.len);
    inline for (.{ "outline-bad.djvu", "outline-duplicate.djvu" }) |name| {
        var doc = try Document.open(a, @embedFile("../fixtures/" ++ name), .{});
        defer doc.deinit();
        var job = try Job.init(&doc, 0, .{});
        defer job.deinit();
        _ = try job.step(1);
        try std.testing.expectError(error.InvalidData, doc.outline());
        var text = (try doc.text(0)).?;
        defer text.deinit(a);
        try std.testing.expect(text.bytes.len > 0);
        try std.testing.expectEqual(Link{ .kind = .page, .page = 2 }, try doc.resolveLink("#2", null));
        while (try job.step(4096) != .done) {}
    }
}

test "navigation snapshots survive document and input release" {
    var outline: Outline = undefined;
    {
        const bytes = try a.dupe(u8, @embedFile("../fixtures/outline.djvu"));
        defer a.free(bytes);
        var doc = try Document.open(a, bytes, .{});
        defer doc.deinit();
        outline = (try doc.outline()).?;
    }
    defer outline.deinit(a);
    try expectOutline(outline);
    var strings = try Document.open(a, @embedFile("../fixtures/outline-strings.djvu"), .{});
    defer strings.deinit();
    var literal = (try strings.outline()).?;
    defer literal.deinit(a);
    try std.testing.expectEqualStrings("\u{feff}A\x00B\n\"\\α", literal.entries[0].title);
    try std.testing.expectEqualStrings("#page-a\x00", literal.entries[0].href);
}

test "NAVM validates counts children string lengths UTF8 tails depth and budgets" {
    inline for (.{
        "count",
        "children",
        "unfinished",
        "title-utf8",
        "href-utf8",
        "length",
        "trailing",
        "short",
        "empty-stream",
    }) |name|
        try std.testing.expectError(error.InvalidData, Outline.decode(a, @embedFile("../fixtures/outline-bad-" ++ name ++ ".navm"), .{}));
    try std.testing.expectError(error.LimitExceeded, Outline.decode(a, @embedFile("../fixtures/outline-depth65.navm"), .{}));
    var deep = try Outline.decode(a, @embedFile("../fixtures/outline-depth64.navm"), .{});
    defer deep.deinit(a);
    try std.testing.expectEqual(@as(usize, 64), deep.entries.len);
    try std.testing.expectEqual(@as(u32, 64), deep.entries[0].subtree_end);
    var wide = try Outline.decode(a, @embedFile("../fixtures/outline-wide.navm"), .{});
    defer wide.deinit(a);
    try std.testing.expectEqual(@as(usize, 257), wide.entries.len);
    try std.testing.expectEqual(@as(u32, 256), wide.entries[0].subtree_end);
    try std.testing.expectEqual(@as(?u32, null), wide.entries[256].parent);
    var max = try Outline.decode(a, @embedFile("../fixtures/outline-max.navm"), .{});
    defer max.deinit(a);
    try std.testing.expectEqual(@as(usize, 65535), max.entries.len);
    for ([_]Limits{ .{ .max_outline_bytes = 5 }, .{ .max_outline_entries = 5 }, .{ .max_outline_depth = 2 }, .{ .max_bzz_bytes = 5 } }) |limits| {
        var doc = try Document.open(a, @embedFile("../fixtures/outline-single.djvu"), limits);
        defer doc.deinit();
        try std.testing.expectError(error.LimitExceeded, doc.outline());
    }
}

test "DjVu page references follow ID relative title number and unique name precedence" {
    var budget: Budget = .{ .parent = a, .limit = 128 * 1024 };
    var doc = try Document.open(budget.allocator(), @embedFile("../fixtures/outline-indirect/index.djvu"), .{});
    defer doc.deinit();
    const before = budget.live;
    const Case = struct { href: []const u8, from: ?usize = null, result: Link };
    const cases = [_]Case{
        .{ .href = "", .result = .{ .kind = .none } },
        .{ .href = "#", .result = .{ .kind = .unresolved } },
        .{ .href = "#1", .result = .{ .kind = .page, .page = 0 } },
        .{ .href = "#2", .result = .{ .kind = .page, .page = 2 } },
        .{ .href = "#3", .result = .{ .kind = .page, .page = 1 } },
        .{ .href = "#003", .result = .{ .kind = .page, .page = 2 } },
        .{ .href = "#7", .result = .{ .kind = .page, .page = 6 } },
        .{ .href = "#0", .result = .{ .kind = .unresolved } },
        .{ .href = "#8", .result = .{ .kind = .unresolved } },
        .{ .href = "#+1", .result = .{ .kind = .page, .page = 3 } },
        .{ .href = "#+1", .from = 6, .result = .{ .kind = .page, .page = 3 } },
        .{ .href = "#+2", .result = .{ .kind = .unresolved } },
        .{ .href = "#+2", .from = 4, .result = .{ .kind = .page, .page = 6 } },
        .{ .href = "#+2", .from = 5, .result = .{ .kind = .unresolved } },
        .{ .href = "#-1", .from = 3, .result = .{ .kind = .page, .page = 2 } },
        .{ .href = "#-1", .from = 0, .result = .{ .kind = .unresolved } },
        .{ .href = "#-0", .from = 2, .result = .{ .kind = .page, .page = 2 } },
        .{ .href = "#+0002", .from = 0, .result = .{ .kind = .page, .page = 2 } },
        .{ .href = "#999999999999999999999999999999999999", .result = .{ .kind = .unresolved } },
        .{ .href = "#+999999999999999999999999999999999999", .from = 1, .result = .{ .kind = .unresolved } },
        .{ .href = "#Repeat", .result = .{ .kind = .page, .page = 0 } },
        .{ .href = "#Repeat", .from = 2, .result = .{ .kind = .page, .page = 2 } },
        .{ .href = "#Repeat", .from = 3, .result = .{ .kind = .page, .page = 5 } },
        .{ .href = "#Repeat", .from = 6, .result = .{ .kind = .page, .page = 0 } },
        .{ .href = "#repeat", .result = .{ .kind = .unresolved } },
        .{ .href = "#Приложение α", .result = .{ .kind = .page, .page = 4 } },
        .{ .href = "#sheet b.djvu", .result = .{ .kind = .page, .page = 1 } },
        .{ .href = "#dup.djvu", .result = .{ .kind = .unresolved } },
        .{ .href = "#shared", .result = .{ .kind = .unresolved } },
        .{ .href = "#page e", .result = .{ .kind = .page, .page = 4 } },
        .{ .href = "#page%20e", .result = .{ .kind = .page, .page = 5 } },
        .{ .href = "#file%20e.djvu", .result = .{ .kind = .unresolved } },
        .{ .href = "#2_0", .result = .{ .kind = .unresolved } },
        .{ .href = "#1\x00", .result = .{ .kind = .unresolved } },
        .{ .href = "?page=2&zoom=width", .result = .{ .kind = .options } },
        .{ .href = "https://example.invalid/α#2", .result = .{ .kind = .url } },
        .{ .href = "javascript:alert(1)", .result = .{ .kind = .url } },
        .{ .href = "other.djvu#3", .result = .{ .kind = .url } },
    };
    for (cases) |case| try std.testing.expectEqual(case.result, try doc.resolveLink(case.href, case.from));
    try std.testing.expectError(error.InvalidArgument, doc.resolveLink("#1", 7));
    try std.testing.expectError(error.InvalidArgument, doc.resolveLink("#\xff", null));
    try std.testing.expectEqual(before, budget.live);
    try doc.dropComponents();
    try std.testing.expectEqual(Link{ .kind = .page, .page = 4 }, try doc.resolveLink("#page e", null));
    try std.testing.expectEqual(@as(usize, 0), doc.suppliedBytes());
}

test "annotation hrefs use the same resolver without changing either snapshot" {
    var doc = try Document.open(a, @embedFile("../fixtures/outline.djvu"), .{});
    defer doc.deinit();
    var annotations = (try doc.annotations(0)).?;
    defer annotations.deinit();
    try std.testing.expectEqualStrings("#+2", annotations.areas[0].href);
    try std.testing.expectEqual(Link{ .kind = .page, .page = 2 }, try doc.resolveLink(annotations.areas[0].href, 0));
}

test "outline allocation failures and bounded corruptions release all memory" {
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var doc = try Document.open(allocator, @embedFile("../fixtures/outline.djvu"), .{});
            defer doc.deinit();
            var outline = (try doc.outline()).?;
            defer outline.deinit(allocator);
            const json = try std.json.Stringify.valueAlloc(allocator, &outline, .{});
            allocator.free(json);
        }
    }.run, .{});
    const compressed = @embedFile("../fixtures/outline-wide.navm");
    var random = std.Random.DefaultPrng.init(0x4e41564d);
    for (0..128) |_| {
        var bytes: [compressed.len]u8 = compressed.*;
        bytes[random.random().uintLessThan(usize, bytes.len)] ^= random.random().int(u8) | 1;
        var budget: Budget = .{ .parent = a, .limit = 128 * 1024 };
        if (Outline.decode(budget.allocator(), &bytes, .{ .max_outline_bytes = 4096, .max_outline_entries = 512 })) |value| {
            var outline = value;
            outline.deinit(budget.allocator());
        } else |_| {}
        try std.testing.expectEqual(@as(usize, 0), budget.live);
    }
}
