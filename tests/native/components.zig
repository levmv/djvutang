const std = @import("std");
const Document = @import("../../src/document.zig").Document;
const Job = @import("../../src/job.zig").Job;
const Budget = @import("../../src/budget.zig").Budget;
const a = std.testing.allocator;

const Fixture = enum { layers, jb2, standalone };

fn file(name: []const u8, comptime fixture: Fixture) ![]const u8 {
    if (fixture == .jb2) {
        inline for (.{ "page0.iff", "page0.djvu", "page1.djvu" }) |path|
            if (std.mem.eql(u8, name, path)) return @embedFile("../fixtures/indirect/" ++ path);
    } else if (fixture == .standalone) {
        inline for (.{ "page.djvu", "paint", "tail", "foreground", "mask", "text" }) |path|
            if (std.mem.eql(u8, name, path)) return @embedFile("../fixtures/standalone-layers/" ++ path);
    } else {
        inline for (.{
            "sheet a.djvu",
            "paint.iff",
            "tail.iff",
            "foreground.iff",
            "mask.iff",
            "text.iff",
            "sheet b.djvu",
        }) |path|
            if (std.mem.eql(u8, name, path)) return @embedFile("../fixtures/indirect-layers/" ++ path);
    }
    return error.UnexpectedFile;
}

fn prepare(doc: *Document, page: usize, scope: Document.Scope, comptime fixture: Fixture) !usize {
    var count: usize = 0;
    while (try doc.nextMissing(page, scope)) |index| {
        count += 1;
        const bytes = try doc.allocator.dupe(u8, try file(doc.components.items[index].name, fixture));
        doc.provideComponent(index, bytes) catch |err| {
            doc.allocator.free(bytes);
            return err;
        };
    }
    return count;
}

fn render(doc: *Document, page: usize) !void {
    var job = try Job.init(doc, page, .{});
    defer job.deinit();
    while (try job.step(2048) != .done) {}
    const expected = @embedFile("../fixtures/jpeg-foreground-reference.ppm");
    const rgb = expected[std.mem.indexOf(u8, expected, "\n255\n").? + 5 ..];
    const rgba = try job.pixels();
    try std.testing.expectEqual(rgb.len / 3 * 4, rgba.len);
    for (0..rgb.len / 3) |i| try std.testing.expectEqualSlices(u8, rgb[i * 3 ..][0..3], rgba[i * 4 ..][0..3]);
}

test "indirect directory opens alone and loads only the requested page and includes" {
    inline for (.{ "indirect-layers", "indirect-v0", "indirect-zero-sizes" }) |name| {
        var doc = try Document.open(a, @embedFile("../fixtures/" ++ name ++ "/index.djvu"), .{});
        defer doc.deinit();
        try std.testing.expect(doc.indirect);
        try std.testing.expectEqual(@as(usize, 2), doc.pageCount());
        const index = try doc.pageComponent(0);
        try std.testing.expectEqualStrings("page-a", doc.components.items[index].id);
        try std.testing.expectEqualStrings("sheet a.djvu", doc.components.items[index].name);
        try std.testing.expectEqualStrings("Opening", doc.components.items[index].title);
        try std.testing.expectError(error.MissingComponent, doc.info(0));
        try std.testing.expectEqual(@as(usize, 1), try prepare(&doc, 0, .page, .layers));
        try std.testing.expectEqual(@as(u32, 65), (try doc.info(0)).width);
        try std.testing.expectError(error.MissingComponent, Job.init(&doc, 0, .{}));
        try std.testing.expect(!doc.busy);
        try std.testing.expectEqual(@as(usize, 5), try prepare(&doc, 0, .includes, .layers));
        try render(&doc, 0);
        var text = (try doc.text(0)).?;
        defer text.deinit(a);
        try std.testing.expectEqualStrings("Shared α text\n", text.bytes);
        try std.testing.expectEqual(@as(usize, 1), try prepare(&doc, 1, .includes, .layers));
        try render(&doc, 1);
        try std.testing.expectEqual(@as(usize, 0), try prepare(&doc, 1, .includes, .layers));
    }
}

test "shared chunks expand in order once across a diamond and retain unknown payloads" {
    var doc = try Document.open(a, @embedFile("../fixtures/shared-layers.djvu"), .{});
    defer doc.deinit();
    try render(&doc, 0);
    var chunks = try doc.pageChunks(0);
    defer chunks.deinit();
    var backgrounds: usize = 0;
    var unknown: usize = 0;
    while (try chunks.next()) |entry| {
        if (std.mem.eql(u8, entry.chunk.id, "BG44")) {
            try std.testing.expectEqual(backgrounds, entry.chunk.data[0]);
            backgrounds += 1;
        }
        if (std.mem.eql(u8, entry.chunk.id, "JUNK")) {
            try std.testing.expectEqualStrings("preserved", entry.chunk.data);
            unknown += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), backgrounds);
    try std.testing.expectEqual(@as(usize, 1), unknown);
}

test "indirect shared JB2 caching survives page changes and releases supplied bytes" {
    var budget: Budget = .{ .parent = a, .limit = 1024 * 1024 };
    var doc = try Document.open(budget.allocator(), @embedFile("../fixtures/indirect/index.djvu"), .{});
    const initial = budget.live;
    for (0..2) |round| {
        for (0..2) |page| {
            _ = try prepare(&doc, page, .includes, .jb2);
            var job = try Job.init(&doc, page, .{});
            defer job.deinit();
            while (try job.step(512) != .done) {}
            try std.testing.expectEqual(round + 1, doc.dictionary_decodes);
            try std.testing.expectError(error.Busy, doc.dropComponents());
            // An unloaded component can be supplied while the earlier Job lives.
            if (page == 0) _ = try prepare(&doc, 1, .page, .jb2);
        }
        try doc.dropComponents();
        try std.testing.expectEqual(initial, budget.live);
        try std.testing.expectError(error.MissingComponent, doc.info(0));
    }
    doc.deinit();
    try std.testing.expectEqual(@as(usize, 0), budget.live);
}

test "bad include graphs fail before decoding without blocking INFO" {
    inline for (.{ "include-cycle", "include-page", "include-info", "include-missing", "include-conflict" }) |name| {
        var doc = try Document.open(a, @embedFile("../fixtures/" ++ name ++ ".djvu"), .{});
        defer doc.deinit();
        try std.testing.expectEqual(@as(u32, 65), (try doc.info(0)).width);
        try std.testing.expectError(error.InvalidData, Job.init(&doc, 0, .{}));
        try std.testing.expect(!doc.busy);
        if (comptime !std.mem.eql(u8, name, "include-conflict")) try std.testing.expectError(error.InvalidData, doc.text(0));
    }
    var doc = try Document.open(a, @embedFile("../fixtures/shared-layers.djvu"), .{ .max_include_depth = 2 });
    defer doc.deinit();
    try std.testing.expectError(error.LimitExceeded, Job.init(&doc, 0, .{}));
}

test "cache trimming retains recently rendered pages and shared dictionaries" {
    var budget: Budget = .{ .parent = a, .limit = 1024 * 1024 };
    var doc = try Document.open(budget.allocator(), @embedFile("../fixtures/indirect/index.djvu"), .{});
    defer doc.deinit();
    const initial = budget.live;
    var expected: []u8 = &.{};
    defer a.free(expected);
    for ([_]usize{ 0, 1, 0 }) |page| {
        _ = try prepare(&doc, page, .includes, .jb2);
        var job = try Job.init(&doc, page, .{});
        defer job.deinit();
        try std.testing.expectError(error.Busy, doc.trimCache(0));
        while (try job.step(2048) != .done) {}
        try std.testing.expectError(error.Busy, doc.trimCache(0));
        if (page == 1) expected = try a.dupe(u8, try job.pixels());
    }
    try std.testing.expectEqual(@as(usize, 1), doc.dictionary_decodes);
    try std.testing.expectEqual(budget.live - initial, doc.cacheBytes());
    const old_page = try doc.pageComponent(1);
    const limit = doc.cacheBytes() - doc.components.items[old_page].owned.?.len;
    try doc.trimCache(limit);
    try std.testing.expectEqual(limit, doc.cacheBytes());
    try std.testing.expectEqual(@as(?usize, old_page), try doc.nextMissing(1, .page));
    try std.testing.expectEqual(@as(?usize, null), try doc.nextMissing(0, .includes));
    {
        var job = try Job.init(&doc, 0, .{});
        defer job.deinit();
        while (try job.step(2048) != .done) {}
        try std.testing.expectEqual(@as(usize, 1), doc.dictionary_decodes);
    }
    try doc.trimCache(0);
    try std.testing.expectEqual(@as(usize, 0), doc.cacheBytes());
    try std.testing.expectEqual(initial, budget.live);
    _ = try prepare(&doc, 1, .includes, .jb2);
    var job = try Job.init(&doc, 1, .{});
    defer job.deinit();
    while (try job.step(2048) != .done) {}
    try std.testing.expectEqualSlices(u8, expected, try job.pixels());
    try std.testing.expectEqual(@as(usize, 2), doc.dictionary_decodes);
}

test "eviction preserves symbols borrowed by another cached dictionary" {
    const component = @import("../../src/component.zig");
    const jb2 = @import("../../src/jb2.zig");
    var budget: Budget = .{ .parent = a, .limit = 1024 * 1024 };
    const allocator = budget.allocator();
    var entries: [3]component.Component = @splat(.{ .id = "", .name = "", .title = "", .kind = .shared });
    var cache: component.Cache = .{};
    defer cache.clear(allocator, &entries);
    const parent = blk: {
        const image = try allocator.create(jb2.Image);
        errdefer allocator.destroy(image);
        image.* = .{};
        errdefer image.deinit(allocator);
        try image.shapes.ensureTotalCapacity(allocator, 1);
        image.shapes.appendAssumeCapacity(.{ .width = 1, .height = 1, .pixels = try allocator.dupe(u8, &.{1}) });
        break :blk image;
    };
    cache.storeDictionary(&entries, 0, null, parent);
    for (1..3) |index| {
        const child = try allocator.create(jb2.Image);
        child.* = .{ .inherited = parent, .inherited_count = 1 };
        cache.storeDictionary(&entries, index, 0, child);
    }
    try std.testing.expectEqual(budget.live, cache.bytes());
    const limit = cache.bytes() - @sizeOf(jb2.Image);
    cache.trim(allocator, &entries, limit);
    try std.testing.expect(entries[0].dictionary != null and entries[1].dictionary == null);
    try std.testing.expectEqualSlices(u8, &.{1}, entries[2].dictionary.?.shape(0).pixels);
    cache.trim(allocator, &entries, 0);
    try std.testing.expectEqual(@as(usize, 0), budget.live);
}

test "component supply validates entry type length and input budget before ownership transfer" {
    var doc = try Document.open(a, @embedFile("../fixtures/indirect-layers/index.djvu"), .{});
    defer doc.deinit();
    const index = (try doc.nextMissing(0, .page)).?;
    const good = try a.dupe(u8, try file("sheet a.djvu", .layers));
    errdefer a.free(good);
    const wrong = try a.dupe(u8, try file("mask.iff", .layers));
    defer a.free(wrong);
    try std.testing.expectError(error.InvalidData, doc.provideComponent(index, wrong));
    try std.testing.expectError(error.InvalidData, doc.provideComponent(index, good[0 .. good.len - 1]));
    try std.testing.expectEqual(index, (try doc.nextMissing(0, .page)).?);
    const old_limit = doc.limits.max_input_bytes;
    doc.limits.max_input_bytes = doc.bytes.len + good.len - 1;
    try std.testing.expectError(error.LimitExceeded, doc.provideComponent(index, good));
    doc.limits.max_input_bytes = old_limit;
    try doc.provideComponent(index, good);
    try std.testing.expectError(error.InvalidArgument, doc.provideComponent(index, wrong));
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var doc = try Document.open(allocator, @embedFile("../fixtures/indirect-layers/index.djvu"), .{});
    defer doc.deinit();
    _ = try prepare(&doc, 0, .includes, .layers);
    try render(&doc, 0);
    try doc.trimCache(0);
    _ = try prepare(&doc, 0, .includes, .layers);
    try render(&doc, 0);
    var text = (try doc.text(0)).?;
    defer text.deinit(allocator);
}

test "indirect loading traversal rendering and text release every failed allocation" {
    try std.testing.checkAllAllocationFailures(a, allocationScenario, .{});
}

test "standalone INCL discovers nested shared layers and keeps IDs across cache drops" {
    var budget: Budget = .{ .parent = a, .limit = 1024 * 1024 };
    var doc = try Document.open(budget.allocator(), try file("page.djvu", .standalone), .{});
    try std.testing.expect(!doc.indirect);
    try std.testing.expectEqual(@as(usize, 1), doc.pageCount());
    try std.testing.expectEqual(@as(usize, 5), doc.components.items.len);
    try std.testing.expectEqual(@as(?usize, null), try doc.nextMissing(0, .page));
    try std.testing.expectEqual(@as(u32, 65), (try doc.info(0)).width);
    var retained: usize = 0;
    for (0..2) |round| {
        // Supplying files while an iterator lives can grow the ID registry.
        var chunks = try doc.pageChunks(0);
        {
            defer chunks.deinit();
            try std.testing.expectEqual(@as(usize, 5), try prepare(&doc, 0, .includes, .standalone));
            var backgrounds: usize = 0;
            while (try chunks.next()) |entry| {
                if (std.mem.eql(u8, entry.chunk.id, "BG44")) backgrounds += 1;
            }
            try std.testing.expectEqual(@as(usize, 3), backgrounds);
        }
        try render(&doc, 0);
        {
            var text = (try doc.text(0)).?;
            defer text.deinit(doc.allocator);
            try std.testing.expectEqualStrings("Shared α text\n", text.bytes);
            var annotations = (try doc.annotations(0)).?;
            defer annotations.deinit();
            try std.testing.expectEqualStrings("(background #123456)", annotations.source);
        }
        try std.testing.expectEqual(@as(usize, 6), doc.components.items.len);
        try std.testing.expectEqual(@as(usize, 5), try doc.resolve("tail\r\n\x00"));
        try doc.dropComponents();
        try std.testing.expectEqual(@as(usize, 0), doc.suppliedBytes());
        try std.testing.expectEqual(@as(u32, 65), (try doc.info(0)).width);
        for (doc.components.items[1..], 1..) |component, index| {
            try std.testing.expectEqual(index, try doc.resolve(component.id));
            try std.testing.expectEqualStrings(component.id, component.name);
            try std.testing.expectEqualStrings(component.id, component.title);
            try std.testing.expect(component.form == null);
        }
        if (round == 0) retained = budget.live else try std.testing.expectEqual(retained, budget.live);
    }
    doc.deinit();
    try std.testing.expectEqual(@as(usize, 0), budget.live);
}

test "standalone JB2 uses the same dictionary and pixels as its bundled page" {
    var bundled = try Document.open(a, @embedFile("../fixtures/shared.djvu"), .{});
    defer bundled.deinit();
    var reference = try Job.init(&bundled, 0, .{});
    defer reference.deinit();
    while (try reference.step(2048) != .done) {}
    var doc = try Document.open(a, try file("page0.djvu", .jb2), .{});
    defer doc.deinit();
    for (0..2) |round| {
        try std.testing.expectEqual(@as(usize, 1), try prepare(&doc, 0, .includes, .jb2));
        {
            var job = try Job.init(&doc, 0, .{});
            defer job.deinit();
            while (try job.step(2048) != .done) {}
            try std.testing.expectEqualSlices(u8, try reference.pixels(), try job.pixels());
            try std.testing.expectEqual(round + 1, doc.dictionary_decodes);
            try std.testing.expectError(error.Busy, doc.dropComponents());
        }
        try doc.dropComponents();
    }
}

fn includeFile(allocator: std.mem.Allocator, kind: *const [4]u8, ids: []const []const u8) ![]u8 {
    var length: usize = 16;
    for (ids) |id| length += 8 + id.len + id.len % 2;
    const bytes = try allocator.alloc(u8, length);
    @memset(bytes, 0);
    @memcpy(bytes[0..8], "AT&TFORM");
    std.mem.writeInt(u32, bytes[8..12], @intCast(length - 12), .big);
    @memcpy(bytes[12..16], kind);
    var pos: usize = 16;
    for (ids) |id| {
        @memcpy(bytes[pos..][0..4], "INCL");
        std.mem.writeInt(u32, bytes[pos + 4 ..][0..4], @intCast(id.len), .big);
        @memcpy(bytes[pos + 8 ..][0..id.len], id);
        pos += 8 + id.len + id.len % 2;
    }
    return bytes;
}

test "standalone discovery rejects invalid IDs transactionally and bounds the include graph" {
    const root = try includeFile(a, "DJVU", &.{"a"});
    defer a.free(root);
    var doc = try Document.open(a, root, .{});
    defer doc.deinit();
    for ([_][]const u8{ "", "\r\n\x00", "bad\x00id", "\xff" }) |bad| {
        const bytes = try includeFile(a, "DJVI", &.{ "b", bad });
        defer a.free(bytes);
        try std.testing.expectError(error.InvalidData, doc.provideComponent(1, bytes));
        try std.testing.expectEqual(@as(usize, 2), doc.components.items.len);
        try std.testing.expectError(error.InvalidData, doc.resolve("b"));
        try std.testing.expectEqual(@as(?usize, 1), try doc.nextMissing(0, .includes));
    }
    const over = try includeFile(a, "DJVI", &.{ "b", "c" });
    defer a.free(over);
    doc.limits.max_components = 3;
    try std.testing.expectError(error.LimitExceeded, doc.provideComponent(1, over));
    try std.testing.expectEqual(@as(usize, 2), doc.components.items.len);
    try std.testing.expectEqual(@as(usize, 1), doc.include_name_bytes);
    try std.testing.expectEqual(@as(usize, 0), doc.suppliedBytes());
    // Fail framing after the first new ID, too.
    over[over.len - 6] = 0xff;
    try std.testing.expectError(error.InvalidData, doc.provideComponent(1, over));
    try std.testing.expectError(error.InvalidData, doc.resolve("b"));
    try std.testing.expectError(error.InvalidData, doc.provideComponent(1, root));

    const good = try includeFile(a, "DJVI", &.{ "b\r\n\x00", "b" });
    doc.provideComponent(1, good) catch |err| {
        a.free(good);
        return err;
    };
    try std.testing.expectEqual(@as(usize, 3), doc.components.items.len);
    try std.testing.expectEqual(@as(?usize, 2), try doc.nextMissing(0, .includes));
    doc.limits.max_include_depth = 2;
    try std.testing.expectError(error.LimitExceeded, doc.nextMissing(0, .includes));
    doc.limits.max_include_depth = 64;
    const cycle = try includeFile(a, "DJVI", &.{"a"});
    doc.provideComponent(2, cycle) catch |err| {
        a.free(cycle);
        return err;
    };
    try std.testing.expectError(error.InvalidData, doc.nextMissing(0, .includes));
}

test "retained standalone IDs stay bounded across replacement of supplied files" {
    const root = try includeFile(a, "DJVU", &.{"a"});
    defer a.free(root);
    var doc = try Document.open(a, root, .{ .max_input_bytes = 150 });
    defer doc.deinit();
    const first = try includeFile(a, "DJVI", &.{"b" ** 100});
    doc.provideComponent(1, first) catch |err| {
        a.free(first);
        return err;
    };
    try doc.dropComponents();
    const second = try includeFile(a, "DJVI", &.{"c" ** 100});
    defer a.free(second);
    try std.testing.expectError(error.LimitExceeded, doc.provideComponent(1, second));
    try std.testing.expectEqual(@as(usize, 101), doc.include_name_bytes);
    try std.testing.expectEqual(@as(usize, 3), doc.components.items.len);
    try std.testing.expectEqualStrings("b" ** 100, doc.components.items[2].id);
    try std.testing.expectEqual(@as(?usize, 1), try doc.nextMissing(0, .includes));
}

fn standaloneAllocationScenario(allocator: std.mem.Allocator) !void {
    var doc = try Document.open(allocator, try file("page.djvu", .standalone), .{});
    defer doc.deinit();
    var chunks = try doc.pageChunks(0);
    defer chunks.deinit();
    _ = try prepare(&doc, 0, .includes, .standalone);
    while (try chunks.next()) |_| {}
    try doc.dropComponents();
    _ = try prepare(&doc, 0, .includes, .standalone);
    var text = (try doc.text(0)).?;
    defer text.deinit(allocator);
}

test "standalone registration and reloading release every failed allocation" {
    try std.testing.checkAllAllocationFailures(a, standaloneAllocationScenario, .{});
}
