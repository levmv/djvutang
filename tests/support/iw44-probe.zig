//! Test/benchmark input: little-endian chunk count, then length and bytes for
//! each IW44 chunk. Hosts unpack the container; this harness only exercises IW44.
const std = @import("std");
const iw44 = @import("iw44");
pub const Budget = @import("budget").Budget;

pub const Source = struct {
    allocator: std.mem.Allocator,
    chunks: [][]const u8,
    decoder: iw44.Decoder,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) !Source {
        if (bytes.len < 4) return error.InvalidData;
        const count = std.mem.readInt(u32, bytes[0..4], .little);
        if (count == 0 or count > 256) return error.InvalidData;
        const chunks = try allocator.alloc([]const u8, count);
        errdefer allocator.free(chunks);
        var position: usize = 4;
        for (chunks) |*chunk| {
            if (bytes.len - position < 4) return error.InvalidData;
            const length = std.mem.readInt(u32, bytes[position..][0..4], .little);
            position += 4;
            if (length > bytes.len - position) return error.InvalidData;
            chunk.* = bytes[position..][0..length];
            position += length;
        }
        if (position != bytes.len) return error.InvalidData;
        var decoder = try iw44.Decoder.init(allocator, chunks, .{});
        decoder.retain_coefficients = true;
        return .{ .allocator = allocator, .chunks = chunks, .decoder = decoder };
    }

    pub fn deinit(self: *Source) void {
        self.decoder.deinit();
        self.allocator.free(self.chunks);
        self.* = undefined;
    }

    pub fn reconstruct(self: *Source, reduction: u32) !void {
        switch (reduction) {
            1, 2, 4, 8, 16, 32 => {},
            else => return error.InvalidArgument,
        }
        try self.decoder.reconstructReduced(reduction, .{
            .x = 0,
            .y = 0,
            .width = (self.decoder.header.width + reduction - 1) / reduction,
            .height = (self.decoder.header.height + reduction - 1) / reduction,
        });
    }
};
