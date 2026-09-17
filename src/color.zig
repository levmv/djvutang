const std = @import("std");
const types = @import("types.zig");
const Error = types.Error;
const Reader = @import("iff.zig").Reader;
const bzz = @import("bzz.zig");

pub const Palette = struct {
    colors: [][3]u8,
    indices: []u16,

    /// A missing correspondence table assigns no colors. With no JB2 mask,
    /// pass null: validate the data without attaching its indices to MMR pixels.
    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, blits: ?usize, limits: types.Limits) Error!Palette {
        var r: Reader = .{ .bytes = bytes };
        const version = try r.byte();
        if (version & 0x7f != 0) return error.Unsupported;
        const count = try r.uint(2);
        if (count == 0) return error.InvalidData;
        const colors = try allocator.alloc([3]u8, count);
        errdefer allocator.free(colors);
        for (colors) |*color| {
            const bgr = try r.take(3);
            color.* = .{ bgr[2], bgr[1], bgr[0] };
        }
        if (version & 0x80 == 0) {
            if (r.pos != bytes.len) return error.InvalidData;
            return .{ .colors = colors, .indices = &.{} };
        }
        const n = try r.uint(3);
        if (n > limits.max_blits) return error.LimitExceeded;
        if (blits) |expected| if (n != expected) return error.InvalidData;
        // An empty assignment table may omit its BZZ stream.
        if (n == 0 and r.pos == bytes.len) return .{ .colors = colors, .indices = &.{} };
        const raw = try bzz.decode(allocator, r.bytes[r.pos..], @min(limits.max_bzz_bytes, @as(usize, n) * 2));
        defer allocator.free(raw);
        if (raw.len != @as(usize, n) * 2) return error.InvalidData;
        const indices = try allocator.alloc(u16, n);
        errdefer allocator.free(indices);
        for (indices, 0..) |*index, i| {
            const value = @as(u16, raw[2 * i]) * 256 + raw[2 * i + 1];
            if (value >= colors.len) return error.InvalidData;
            index.* = value;
        }
        return .{ .colors = colors, .indices = indices };
    }

    pub fn deinit(self: *Palette, allocator: std.mem.Allocator) void {
        allocator.free(self.colors);
        allocator.free(self.indices);
        self.* = undefined;
    }
};

/// A single integer reduction applies to both layer dimensions. Tiny layers may
/// have several possible factors; use the smallest one consistent with both.
pub fn reduction(width: u32, height: u32, layer_width: u32, layer_height: u32) Error!u32 {
    for (1..13) |i| {
        const r: u32 = @intCast(i);
        if ((width + r - 1) / r == layer_width and (height + r - 1) / r == layer_height) return r;
    }
    return error.InvalidData;
}

/// Display gamma is 2.2. This LUT is applied to layer samples before resampling.
pub fn gamma(input_tenths: u8) [256]u8 {
    var table: [256]u8 = undefined;
    for (&table, 0..) |*value, i| {
        value.* = if (input_tenths == 22) @intCast(i) else @intFromFloat(@floor(
            255.0 * std.math.pow(f64, @as(f64, @floatFromInt(i)) / 255.0, @as(f64, @floatFromInt(input_tenths)) / 22.0) + 0.5,
        ));
    }
    return table;
}
