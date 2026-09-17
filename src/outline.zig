//! NAVM: BZZ-compressed preorder forest, DjVu 3 section 8.3.3.
const std = @import("std");
const types = @import("types.zig");
const Error = types.Error;
const Reader = @import("iff.zig").Reader;
const bzz = @import("bzz.zig");

pub const Entry = struct {
    title: []const u8,
    href: []const u8,
    parent: ?u32,
    /// Exclusive end of this entry's subtree in the preorder array.
    subtree_end: u32,

    pub fn jsonStringify(self: *const Entry, stream: *std.json.Stringify) std.Io.Writer.Error!void {
        try stream.write(.{
            .title = self.title,
            .href = self.href,
            .parent = self.parent,
            .subtreeEnd = self.subtree_end,
        });
    }
};

pub const Outline = struct {
    storage: []u8,
    entries: []Entry,

    pub fn deinit(self: *Outline, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.storage);
        self.* = undefined;
    }

    pub fn jsonStringify(self: *const Outline, stream: *std.json.Stringify) std.Io.Writer.Error!void {
        try stream.write(.{ .entries = self.entries });
    }

    pub fn decode(allocator: std.mem.Allocator, payload: []const u8, limits: types.Limits) Error!Outline {
        const raw = try bzz.decode(allocator, payload, @min(limits.max_outline_bytes, limits.max_bzz_bytes));
        errdefer allocator.free(raw);
        var r: Reader = .{ .bytes = raw };
        const count = try r.uint(2);
        if (count > limits.max_outline_entries) return error.LimitExceeded;
        if (count > (raw.len - r.pos) / 7) return error.InvalidData;
        const entries = try allocator.alloc(Entry, count);
        errdefer allocator.free(entries);
        var stack: [64]struct { index: u32, remaining: u8 } = undefined;
        var depth: usize = 0;
        for (entries, 0..) |*entry, i| {
            while (depth != 0 and stack[depth - 1].remaining == 0) {
                depth -= 1;
                entries[stack[depth].index].subtree_end = @intCast(i);
            }
            if (depth >= @min(limits.max_outline_depth, stack.len)) return error.LimitExceeded;
            const children = try r.byte();
            if (children > count - i - 1) return error.InvalidData;
            const title = try r.take(try r.uint(3));
            const href = try r.take(try r.uint(3));
            if (!std.unicode.utf8ValidateSlice(title) or !std.unicode.utf8ValidateSlice(href)) return error.InvalidData;
            entry.* = .{
                .title = title,
                .href = href,
                .parent = if (depth == 0) null else stack[depth - 1].index,
                .subtree_end = @intCast(i + 1),
            };
            if (depth != 0) stack[depth - 1].remaining -= 1;
            if (children != 0) {
                stack[depth] = .{ .index = @intCast(i), .remaining = children };
                depth += 1;
            }
        }
        while (depth != 0) {
            depth -= 1;
            if (stack[depth].remaining != 0) return error.InvalidData;
            entries[stack[depth].index].subtree_end = count;
        }
        if (r.pos != raw.len) return error.InvalidData;
        return .{ .storage = raw, .entries = entries };
    }
};
