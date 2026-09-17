//! Hidden text (TXTa/TXTz).
const std = @import("std");
const types = @import("types.zig");
const Error = types.Error;
const Reader = @import("iff.zig").Reader;
const bzz = @import("bzz.zig");
const Bounds = @import("geometry.zig").Bounds;
const utf8 = @import("utf8.zig");

pub const Kind = enum(u32) { page = 1, column, region, paragraph, line, word, character };
pub const no_parent = std.math.maxInt(u32);
/// Preorder tree; each subtree occupies [index, subtree_end). Offsets are bytes.
/// Bounds use unrotated INFO pixels, top-left. Imperfect off-page boxes survive.
pub const Zone = extern struct {
    kind: Kind,
    parent: u32,
    bounds: Bounds,
    text_start: u32,
    text_length: u32,
    subtree_end: u32,
};

pub const Text = struct {
    storage: []u8,
    bytes: []const u8,
    has_replacements: bool,
    zones: []Zone,

    pub fn deinit(self: *Text, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        allocator.free(self.zones);
        self.* = undefined;
    }

    /// Owned display text; the source and all zone offsets remain unchanged.
    pub fn toUtf8(self: *const Text, allocator: std.mem.Allocator) Error![]u8 {
        return utf8.toUtf8(allocator, self.bytes);
    }

    pub fn zoneText(self: *const Text, allocator: std.mem.Allocator, index: usize) Error![]u8 {
        if (index >= self.zones.len) return error.InvalidArgument;
        const z = self.zones[index];
        return utf8.toUtf8(allocator, self.bytes[z.text_start..][0..z.text_length]);
    }

    pub fn decode(
        allocator: std.mem.Allocator,
        payload: []const u8,
        compressed: bool,
        page_height: u32,
        limits: types.Limits,
    ) Error!Text {
        const records = std.math.mul(usize, limits.max_text_zones, 17) catch return error.LimitExceeded;
        const content = std.math.add(usize, records, limits.max_text_bytes) catch return error.LimitExceeded;
        const max_payload = std.math.add(usize, content, 4) catch return error.LimitExceeded;
        if (!compressed and payload.len > max_payload) return error.LimitExceeded;
        const raw = if (compressed)
            try bzz.decode(allocator, payload, @min(max_payload, limits.max_bzz_bytes))
        else
            try allocator.dupe(u8, payload);
        errdefer allocator.free(raw);
        var r: Reader = .{ .bytes = raw };
        const size = try r.uint(3);
        if (size > limits.max_text_bytes) return error.LimitExceeded;
        const bytes = try r.take(size);
        var zones: std.ArrayList(Zone) = .empty;
        errdefer zones.deinit(allocator);
        if (r.pos < raw.len) {
            if (try r.byte() != 1) return error.Unsupported;
            if (r.pos < raw.len) try decodeZones(allocator, &r, bytes, page_height, limits, &zones);
        }
        // A text-only payload without the optional version/tree is unambiguous.
        return .{
            .storage = raw,
            .bytes = bytes,
            .has_replacements = !std.unicode.utf8ValidateSlice(bytes),
            .zones = try zones.toOwnedSlice(allocator),
        };
    }
};

const Frame = struct { parent: u32, previous: u32 = no_parent, remaining: u32 };

fn signed(r: *Reader) Error!i64 {
    return @as(i64, try r.uint(2)) - 32768;
}

fn decodeZones(
    allocator: std.mem.Allocator,
    r: *Reader,
    bytes: []const u8,
    height: u32,
    limits: types.Limits,
    zones: *std.ArrayList(Zone),
) Error!void {
    // No recursive calls or per-node allocation. Depth is independent of type:
    // unusual producer hierarchies remain usable within the explicit bound.
    var stack: [64]Frame = undefined;
    stack[0] = .{ .parent = no_parent, .remaining = 1 };
    var depth: usize = 1;
    if (limits.max_text_depth == 0) return error.LimitExceeded;
    while (depth != 0) {
        const frame = &stack[depth - 1];
        if (frame.remaining == 0) {
            if (frame.parent != no_parent) zones.items[frame.parent].subtree_end = @intCast(zones.items.len);
            depth -= 1;
            continue;
        }
        if (zones.items.len >= limits.max_text_zones) return error.LimitExceeded;
        const kind = std.enums.fromInt(Kind, try r.byte()) orelse return error.InvalidData;
        var x = try signed(r);
        const dy = try signed(r);
        const width = try signed(r);
        const zone_height = try signed(r);
        var start = try signed(r);
        const length = try r.uint(3);
        const children = try r.uint(3);
        if (width < 0 or zone_height < 0) return error.InvalidData;
        var y = @as(i64, height) - dy - zone_height;
        if (frame.previous != no_parent) {
            const prev = zones.items[frame.previous];
            if (kind == .page or kind == .paragraph or kind == .line) {
                x += prev.bounds.x;
                y = @as(i64, prev.bounds.y) + prev.bounds.height + dy;
            } else {
                x += @as(i64, prev.bounds.x) + prev.bounds.width;
                y = @as(i64, prev.bounds.y) + prev.bounds.height - dy - zone_height;
            }
            start += @as(i64, prev.text_start) + prev.text_length;
        } else if (frame.parent != no_parent) {
            const parent = zones.items[frame.parent];
            x += parent.bounds.x;
            y = @as(i64, parent.bounds.y) + dy;
            start += parent.text_start;
        }
        if (start < 0 or start > bytes.len or length > bytes.len - @as(usize, @intCast(start))) return error.InvalidData;
        const offset: u32 = @intCast(start);
        if (!utf8.boundary(bytes, offset) or !utf8.boundary(bytes, offset + length)) return error.InvalidData;
        const index: u32 = @intCast(zones.items.len);
        if (children > limits.max_text_zones - zones.items.len - 1) return error.LimitExceeded;
        if (children > (r.bytes.len - r.pos) / 17) return error.InvalidData;
        try zones.append(allocator, .{
            .kind = kind,
            .parent = frame.parent,
            .bounds = .{
                .x = std.math.cast(i32, x) orelse return error.LimitExceeded,
                .y = std.math.cast(i32, y) orelse return error.LimitExceeded,
                .width = @intCast(width),
                .height = @intCast(zone_height),
            },
            .text_start = offset,
            .text_length = length,
            .subtree_end = index + 1,
        });
        frame.previous = index;
        frame.remaining -= 1;
        if (children != 0) {
            if (depth >= @min(stack.len, limits.max_text_depth)) return error.LimitExceeded;
            stack[depth] = .{ .parent = index, .remaining = children };
            depth += 1;
        }
    }
    if (r.pos != r.bytes.len) return error.InvalidData;
}
