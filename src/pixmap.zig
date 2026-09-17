const std = @import("std");
const Region = @import("geometry.zig").Region;

/// Owned ink mask: top-down pixels packed continuously, low bit first.
/// Rows have no padding; a set bit selects the foreground.
pub const Bitmap = struct {
    width: u32 = 0,
    height: u32 = 0,
    pixels: []u8 = &.{},

    pub fn deinit(self: *Bitmap, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = .{};
    }
};

/// Owned RGB samples, top-down, before display gamma correction.
pub const Pixmap = struct {
    width: u32,
    height: u32,
    pixels: [][3]u8,
    /// A reusable regional raster. Dimensions still describe the entire layer;
    /// pixels start at this top-left origin and may include spare capacity.
    region: ?Region = null,
    /// Internal preview grid: a sample covers this many INFO pixels on each
    /// axis, anchored at the page's bottom left. Zero keeps ordinary bilinear
    /// layer sampling. The final top/right cells may be smaller.
    sample_step: u32 = 0,

    pub fn area(self: Pixmap) Region {
        return self.region orelse .{ .x = 0, .y = 0, .width = self.width, .height = self.height };
    }

    pub fn contains(self: Pixmap, r: Region) bool {
        const a = self.area();
        return r.x >= a.x and r.y >= a.y and r.x + r.width <= a.x + a.width and r.y + r.height <= a.y + a.height;
    }

    pub fn row(self: Pixmap, y: u32) []const [3]u8 {
        const a = self.area();
        return self.pixels[@as(usize, y - a.y) * a.width ..][0..a.width];
    }

    pub fn deinit(self: *Pixmap, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};
