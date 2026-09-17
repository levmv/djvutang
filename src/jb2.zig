//! Resumable JB2 records and symbol pixels.
const std = @import("std");
const types = @import("types.zig");
const Error = types.Error;
const Zp = @import("zp.zig").Decoder;
const Allocator = std.mem.Allocator;

pub const Box = struct {
    left: i32 = 0,
    bottom: i32 = 0,
    right: i32 = -1,
    top: i32 = -1,

    pub fn width(self: Box) i32 {
        return self.right - self.left + 1;
    }

    pub fn height(self: Box) i32 {
        return self.top - self.bottom + 1;
    }

    fn include(self: *Box, x: i32, y: i32) void {
        if (self.right < self.left) {
            self.* = .{ .left = x, .right = x, .bottom = y, .top = y };
        } else {
            self.left = @min(self.left, x);
            self.right = @max(self.right, x);
            self.bottom = @min(self.bottom, y);
            self.top = @max(self.top, y);
        }
    }
};

pub const Shape = struct {
    width: u32,
    height: u32,
    /// Bottom-up rows of ceil(width / 8) bytes, least-significant bit first.
    /// Padding bits are zero; decoding writes directly into the packed storage.
    pixels: []u8,
    box: Box = .{},

    pub fn pixelCount(self: *const Shape) usize {
        return @as(usize, self.width) * self.height;
    }

    /// Symbol rows use the format's bottom-up coordinates. Outside is white.
    pub fn get(self: *const Shape, x: i32, y: i32) u1 {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return 0;
        return rowPixel(self.row(y), x);
    }

    pub fn row(self: *const Shape, y: i32) Row {
        if (y < 0 or y >= self.height) return .{ .pixels = &.{}, .width = 0 };
        const stride = (self.width + 7) / 8;
        return .{ .pixels = self.pixels[@as(usize, @intCast(y)) * stride ..][0..stride], .width = self.width };
    }
};

const Row = struct { pixels: []u8, width: u32 };

inline fn rowPixel(row: Row, x: i32) u1 {
    if (x < 0 or x >= row.width) return 0;
    const ux: u32 = @intCast(x);
    return @truncate(row.pixels[ux / 8] >> @intCast(ux % 8));
}
pub const Blit = struct { shape: u32, left: i64, bottom: i64 };
pub const Image = struct {
    width: u32 = 0,
    height: u32 = 0,
    inherited: ?*const Image = null,
    inherited_count: u32 = 0,
    shapes: std.ArrayList(Shape) = .empty,
    library: std.ArrayList(u32) = .empty,
    blits: std.ArrayList(Blit) = .empty,

    pub fn shapeCount(self: *const Image) usize {
        return self.inherited_count + self.shapes.items.len;
    }

    pub fn shape(self: *const Image, index: u32) *const Shape {
        if (index < self.inherited_count) return self.inherited.?.shape(index);
        return &self.shapes.items[index - self.inherited_count];
    }

    /// Allocation sizes owned by this image; inherited symbols are counted by
    /// their dictionary, and spare ArrayList capacity still consumes memory.
    pub fn ownedBytes(self: *const Image) usize {
        var bytes = self.shapes.capacity * @sizeOf(Shape) +
            self.library.capacity * @sizeOf(u32) +
            self.blits.capacity * @sizeOf(Blit);
        for (self.shapes.items) |s| bytes += s.pixels.len;
        return bytes;
    }

    pub fn deinit(self: *Image, allocator: Allocator) void {
        for (self.shapes.items) |s| allocator.free(s.pixels);
        self.shapes.deinit(allocator);
        self.library.deinit(allocator);
        self.blits.deinit(allocator);
        self.* = .{};
    }
};

const Cell = struct { state: u8 = 0, child: [2]u32 = .{ 0, 0 } };
const Number = enum {
    record,
    width,
    height,
    image,
    inherited,
    match,
    dx,
    dy,
    row_x,
    row_y,
    current_x,
    current_y,
    abs_x,
    abs_y,
    comment_length,
    comment_byte,
};
const State = enum { record, inherit, pixels, location, comment, done };
const Pending = struct {
    record: u4,
    shape: Shape,
    reference: ?u32 = null,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    pixel: usize = 0,
};

pub const Decoder = struct {
    allocator: Allocator,
    limits: types.Limits,
    zp: Zp,
    image: Image = .{},
    is_dictionary: bool,
    legacy_placement: bool = false,
    started: bool = false,
    state: State = .record,
    pending: ?Pending = null,
    cells: std.ArrayList(Cell) = .empty,
    roots: [16]u32 = .{0} ** 16,
    direct: [1024]u8 = .{0} ** 1024,
    refinement: [2048]u8 = .{0} ** 2048,
    refinement_flag: u8 = 0,
    row_flag: u8 = 0,
    row_left: i64 = 0,
    row_bottom: i64 = 0,
    last_right: i64 = 0,
    last_bottom: i64 = 0,
    bottoms: [3]i64 = .{ 0, 0, 0 },
    bottom_index: usize = 0,
    comment_left: usize = 0,
    records: usize = 0,

    pub fn init(
        allocator: Allocator,
        bytes: []const u8,
        dictionary: ?*const Image,
        is_dictionary: bool,
        limits: types.Limits,
    ) Error!Decoder {
        if (bytes.len == 0) return error.InvalidData;
        return .{
            .allocator = allocator,
            .limits = limits,
            .zp = try Zp.init(bytes),
            .image = .{ .inherited = dictionary },
            .is_dictionary = is_dictionary,
        };
    }

    pub fn deinit(self: *Decoder) void {
        if (self.pending) |pending| self.allocator.free(pending.shape.pixels);
        self.image.deinit(self.allocator);
        self.cells.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn takeImage(self: *Decoder) Image {
        std.debug.assert(self.state == .done);
        const image = self.image;
        self.image = .{};
        return image;
    }

    fn cell(self: *Decoder) Error!u32 {
        if (self.cells.items.len >= self.limits.max_cells) return error.LimitExceeded;
        try self.cells.append(self.allocator, .{});
        return @intCast(self.cells.items.len - 1);
    }

    fn number(self: *Decoder, context: Number, lo: i32, hi: i32) Error!i32 {
        if (lo > hi) return error.InvalidData;
        if (self.cells.items.len == 0) _ = try self.cell();
        const root = &self.roots[@intFromEnum(context)];
        if (root.* == 0) root.* = try self.cell();
        var node = root.*;
        var low = lo;
        var high = hi;
        var cutoff: i32 = 0;
        var negative = false;
        // Fold negative values as -n-1, find a power-of-two interval, then
        // bisect it. cutoff is the split point; range is the remaining width.
        var phase: enum(u2) { sign = 1, expand = 2, bisect = 3 } = .sign;
        var range: i32 = -1;
        var iterations: usize = 0;
        while (range != 1) {
            iterations += 1;
            if (iterations > 64) return error.InvalidData;
            // Bounds can force a branch without consuming a coded bit.
            const decision: u1 = if (low >= cutoff)
                1
            else if (high < cutoff)
                0
            else
                try self.zp.bit(&self.cells.items[node].state);
            const parent = node;
            node = self.cells.items[parent].child[decision];
            if (node == 0) {
                node = try self.cell();
                self.cells.items[parent].child[decision] = node;
            }
            switch (phase) {
                .sign => {
                    negative = decision == 0;
                    if (negative) {
                        const old_low = low;
                        low = -high - 1;
                        high = -old_low - 1;
                    }
                    phase = .expand;
                    cutoff = 1;
                },
                .expand => if (decision == 0) {
                    phase = .bisect;
                    range = @divTrunc(cutoff + 1, 2);
                    cutoff = if (range == 1) 0 else cutoff - @divTrunc(range, 2);
                } else {
                    cutoff = std.math.mul(i32, cutoff, 2) catch return error.InvalidData;
                    cutoff = std.math.add(i32, cutoff, 1) catch return error.InvalidData;
                },
                .bisect => {
                    range = @divTrunc(range, 2);
                    if (range != 1) {
                        cutoff += if (decision == 0) -@divTrunc(range, 2) else @divTrunc(range, 2);
                    } else if (decision == 0) {
                        cutoff -= 1;
                    }
                },
            }
        }
        const result = if (negative) -cutoff - 1 else cutoff;
        if (result < lo or result > hi) return error.InvalidData;
        return result;
    }

    fn diff(self: *Decoder, context: Number) Error!i32 {
        return self.number(context, -262143, 262142);
    }

    fn match(self: *Decoder) Error!u32 {
        if (self.image.library.items.len == 0) return error.InvalidData;
        const i: usize = @intCast(try self.number(.match, 0, @intCast(self.image.library.items.len - 1)));
        return self.image.library.items[i];
    }

    fn newShape(self: *Decoder, kind: u4) Error!void {
        var reference: ?u32 = null;
        var width: i32 = undefined;
        var height: i32 = undefined;
        if (kind >= 4 and kind <= 6) {
            reference = try self.match();
            const box = self.image.shape(reference.?).box;
            width = box.width() + try self.diff(.dx);
            height = box.height() + try self.diff(.dy);
        } else {
            width = try self.number(.width, 0, 262142);
            height = try self.number(.height, 0, 262142);
        }
        if (width < 0 or height < 0 or width > 65535 or height > 65535) return error.InvalidData;
        const area = std.math.mul(usize, @intCast(width), @intCast(height)) catch return error.LimitExceeded;
        if (area > self.limits.max_shape_pixels or self.image.shapeCount() >= self.limits.max_shapes) return error.LimitExceeded;
        const stride: usize = @intCast(@divTrunc(width + 7, 8));
        const pixels = try self.allocator.alloc(u8, stride * @as(usize, @intCast(height)));
        @memset(pixels, 0);
        self.pending = .{
            .record = kind,
            .reference = reference,
            .shape = .{
                .width = @intCast(width),
                .height = @intCast(height),
                .pixels = pixels,
            },
        };
        if (reference) |index| {
            const box = self.image.shape(index).box;
            self.pending.?.offset_x = @divTrunc(width, 2) - width + 1 - (@divTrunc(box.width(), 2) - box.right);
            self.pending.?.offset_y = @divTrunc(height, 2) - height + 1 - (@divTrunc(box.height(), 2) - box.top);
        }
        self.state = .pixels;
    }

    fn relative(self: *Decoder, width: i32, height: i32, index: u32) Error!Blit {
        var left: i64 = undefined;
        var bottom: i64 = undefined;
        if (try self.zp.bit(&self.row_flag) != 0) {
            left = self.row_left + try self.diff(.row_x);
            const top = self.row_bottom + try self.diff(.row_y);
            bottom = top - height + 1;
            self.row_left = left;
            self.row_bottom = bottom;
            self.last_bottom = bottom;
            self.bottoms = .{ bottom, bottom, bottom };
            self.bottom_index = 0;
        } else {
            left = self.last_right + try self.diff(.current_x);
            bottom = self.last_bottom + try self.diff(.current_y);
            self.bottom_index = (self.bottom_index + 1) % 3;
            self.bottoms[self.bottom_index] = bottom;
            const a = self.bottoms;
            // The next relative position uses the median of these three bottoms.
            self.last_bottom = @max(@min(a[0], a[1]), @min(@max(a[0], a[1]), a[2]));
        }
        self.last_right = left + width - 1;
        return .{ .shape = index, .left = left - 1, .bottom = bottom - 1 };
    }

    fn appendBlit(self: *Decoder, blit: Blit) Error!void {
        if (self.image.blits.items.len >= self.limits.max_blits) return error.LimitExceeded;
        try self.image.blits.append(self.allocator, blit);
    }

    fn finishShape(self: *Decoder) Error!void {
        const p = &self.pending.?;
        const index: u32 = @intCast(self.image.shapeCount());
        var blit: ?Blit = null;
        if (p.record == 8) {
            const x = try self.number(.abs_x, 1, @intCast(self.image.width));
            const top = try self.number(.abs_y, 1, @intCast(self.image.height));
            blit = .{ .shape = index, .left = @as(i64, x) - 1, .bottom = @as(i64, top) - p.shape.height };
        } else if (p.record != 2 and p.record != 5) {
            blit = try self.relative(@intCast(p.shape.width), @intCast(p.shape.height), index);
        }
        // Reserve everything before ownership transfer; allocation failure leaves
        // the pending shape owned by this decoder and never publishes half a record.
        try self.image.shapes.ensureUnusedCapacity(self.allocator, 1);
        if (p.record == 1 or p.record == 2 or p.record == 4 or p.record == 5)
            try self.image.library.append(self.allocator, index);
        if (blit) |b| try self.appendBlit(b);
        self.image.shapes.appendAssumeCapacity(p.shape);
        self.pending = null;
        self.state = .record;
    }

    fn pixelSpan(self: *Decoder, work: usize) Error!usize {
        const p = &self.pending.?;
        if (p.pixel == p.shape.pixelCount()) {
            self.state = .location;
            return 1;
        }
        var x: i32 = @intCast(p.pixel % p.shape.width);
        const y: i32 = @intCast(p.shape.height - 1 - p.pixel / p.shape.width);
        const shape = &p.shape;
        const count = @min(work, shape.width - @as(u32, @intCast(x)));
        const row = shape.row(y);
        const above = shape.row(y + 1);
        var ctx: usize = 0;
        if (p.reference) |reference| {
            const ref = self.image.shape(reference);
            var cx = x + p.offset_x;
            const cy = y + p.offset_y;
            const ref_above = ref.row(cy + 1);
            const ref_row = ref.row(cy);
            const ref_below = ref.row(cy - 1);
            const bits = [_]u1{
                rowPixel(above, x - 1),
                rowPixel(above, x),
                rowPixel(above, x + 1),
                rowPixel(row, x - 1),

                rowPixel(ref_above, cx),
                rowPixel(ref_row, cx - 1),
                rowPixel(ref_row, cx),
                rowPixel(ref_row, cx + 1),
                rowPixel(ref_below, cx - 1),
                rowPixel(ref_below, cx),
                rowPixel(ref_below, cx + 1),
            };
            for (bits) |b| ctx = (ctx << 1) | b;
            for (0..count) |_| {
                const bit = try self.zp.bit(&self.refinement[ctx]);
                if (bit != 0) {
                    row.pixels[@as(u32, @intCast(x)) / 8] |= @as(u8, 1) << @intCast(@as(u32, @intCast(x)) % 8);
                    shape.box.include(x, y);
                }
                // Retain the overlapping neighbours, then add the four that
                // enter from the right and the pixel just decoded.
                ctx = ((ctx << 1) & 0x636) | (@as(usize, rowPixel(above, x + 2)) << 8) |
                    (@as(usize, bit) << 7) | (@as(usize, rowPixel(ref_above, cx + 1)) << 6) |
                    (@as(usize, rowPixel(ref_row, cx + 2)) << 3) | rowPixel(ref_below, cx + 2);
                x += 1;
                cx += 1;
            }
        } else {
            const above2 = shape.row(y + 2);
            const bits = [_]u1{
                rowPixel(above2, x - 1),
                rowPixel(above2, x),
                rowPixel(above2, x + 1),

                rowPixel(above, x - 2),
                rowPixel(above, x - 1),
                rowPixel(above, x),
                rowPixel(above, x + 1),
                rowPixel(above, x + 2),

                rowPixel(row, x - 2),
                rowPixel(row, x - 1),
            };
            for (bits) |b| ctx = (ctx << 1) | b;
            for (0..count) |_| {
                const bit = try self.zp.bit(&self.direct[ctx]);
                if (bit != 0) {
                    row.pixels[@as(u32, @intCast(x)) / 8] |= @as(u8, 1) << @intCast(@as(u32, @intCast(x)) % 8);
                    shape.box.include(x, y);
                }
                // Three bits two rows above, five above, two to the left.
                // Shifting preserves seven neighbours; only two new reads.
                ctx = ((ctx << 1) & 0x37a) | (@as(usize, rowPixel(above2, x + 2)) << 7) |
                    (@as(usize, rowPixel(above, x + 3)) << 2) | bit;
                x += 1;
            }
        }
        p.pixel += count;
        return count;
    }

    fn record(self: *Decoder) Error!void {
        self.records += 1;
        if (self.records > self.limits.max_records) return error.LimitExceeded;
        const kind: u4 = @intCast(try self.number(.record, 0, 11));
        if (!self.started and kind != 0 and kind != 9 and kind != 10) return error.InvalidData;
        if (self.is_dictionary and kind != 0 and kind != 2 and kind != 5 and
            kind != 9 and kind != 10 and kind != 11)
        {
            return error.InvalidData;
        }
        switch (kind) {
            0 => {
                if (self.started) return error.InvalidData;
                self.image.width = @intCast(try self.number(.image, 0, 262142));
                self.image.height = @intCast(try self.number(.image, 0, 262142));
                if (self.is_dictionary) {
                    if (self.image.width != 0 or self.image.height != 0) return error.InvalidData;
                } else {
                    if (self.image.width == 0 or self.image.height == 0) return error.InvalidData;
                    const area = std.math.mul(usize, self.image.width, self.image.height) catch return error.LimitExceeded;
                    if (area > self.limits.max_page_pixels) return error.LimitExceeded;
                }
                // The reserved eventual-image-refinement flag is not supported.
                if (try self.zp.bit(&self.refinement_flag) != 0) return error.Unsupported;
                self.started = true;
                self.row_bottom = self.image.height;
                self.bottoms = .{ self.row_bottom, self.row_bottom, self.row_bottom };
                self.state = .inherit;
            },
            1...6, 8 => try self.newShape(kind),
            7 => {
                const index = try self.match();
                const shape = self.image.shape(index);
                const box = shape.box;
                // DjVu <= 18 predicts copy locations with the stored dimensions,
                // including blank borders, but still offsets from the ink box.
                const width: i32 = if (self.legacy_placement) @intCast(shape.width) else box.width();
                const height: i32 = if (self.legacy_placement) @intCast(shape.height) else box.height();
                var blit = try self.relative(width, height, index);
                blit.left -= box.left;
                blit.bottom -= box.bottom;
                try self.appendBlit(blit);
            },
            9 => if (!self.started) {
                const count: u32 = @intCast(try self.number(.inherited, 0, 262142));
                if (count != 0 and (self.image.inherited == null or self.image.inherited.?.shapeCount() != count)) {
                    return error.InvalidData;
                }
                if (count > self.limits.max_shapes) return error.LimitExceeded;
                self.image.inherited_count = count;
            } else {
                self.roots = .{0} ** 16;
                self.cells.clearRetainingCapacity();
            },
            10 => {
                self.comment_left = @intCast(try self.number(.comment_length, 0, 262142));
                self.state = .comment;
            },
            11 => self.state = .done,
            else => unreachable,
        }
    }

    /// Each unit is a bounded record header, one symbol pixel, or a comment byte.
    /// Caller must discard the decoder after an error; deinit remains safe.
    pub fn step(self: *Decoder, work: usize) Error!bool {
        if (work == 0) return error.InvalidArgument;
        var remaining = work;
        while (remaining != 0) {
            switch (self.state) {
                .record => try self.record(),
                .inherit => {
                    const n = self.image.library.items.len;
                    if (n == self.image.inherited_count) {
                        self.state = .record;
                    } else {
                        try self.image.library.append(self.allocator, @intCast(n));
                    }
                },
                .pixels => {
                    remaining -= try self.pixelSpan(remaining);
                    continue;
                },
                .location => try self.finishShape(),
                .comment => if (self.comment_left == 0) {
                    self.state = .record;
                } else {
                    _ = try self.number(.comment_byte, 0, 255);
                    self.comment_left -= 1;
                },
                .done => return true,
            }
            remaining -= 1;
        }
        return self.state == .done;
    }
};
