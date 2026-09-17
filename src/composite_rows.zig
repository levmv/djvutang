//! Bounded row storage for exact color sampling and separable area filtering.
const std = @import("std");
const Pixmap = @import("pixmap.zig").Pixmap;
const Info = @import("iff.zig").Info;
const Region = @import("geometry.zig").Region;
const Transform = @import("geometry.zig").Transform;

/// Exact box intersections on the page-wide grid. Dimensions and weights fit
/// in 16 bits for shrinking INFO pixels; enlargement uses the scalar path.
pub const Column = struct {
    /// Source column offset relative to the requested span.
    first: u16,
    count: u16,
    first_weight: u16,
    last_weight: u16,

    pub fn weight(self: Column, index: u32, interior: u32) u32 {
        if (index == 0) return self.first_weight;
        if (index + 1 == self.count) return self.last_weight;
        return interior;
    }
};

pub const Layer = struct {
    // Unrounded vertical numerators; round only after horizontal interpolation.
    values: [][3]u16 = &.{},
    /// First stored column in the full layer's coordinate space.
    first: u32 = 0,
    reduction: u4 = 1,
    /// Current left neighbour relative to values; may be negative at the edge.
    cursor: i32 = 0,
    /// Horizontal weight on the integer 2 * reduction grid.
    fraction: u5 = 0,
    reciprocal: u16 = 0,
    reciprocal_shift: u5 = 0,

    /// The caller validates an exact layer reduction in 1..12 and a nonempty
    /// source rectangle within the INFO grid. Compact preview grids use another path.
    pub fn init(allocator: std.mem.Allocator, image: *const Pixmap, reduction: u32, source: Region) std.mem.Allocator.Error!Layer {
        const d: i64 = 2 * reduction;
        const left: u32 = @intCast(@max(0, @divFloor(2 * @as(i64, source.x) + 1 - reduction, d)));
        // Include the right bilinear neighbour, except on a one-to-one grid.
        // Match composite.layerRegion's support so regional reads stay in bounds.
        const neighbour: i64 = if (reduction == 1) 0 else 1;
        const last = source.x + source.width - 1;
        const right_index = @divFloor(2 * @as(i64, last) + 1 - reduction, d) + neighbour;
        const right: u32 = @intCast(@min(image.width - 1, right_index));
        // Divide the rounded numerator by four first: floor(N/(4r²)) is
        // floor(floor(N/4)/r²). For Q=floor(N/4), d=r² and Qmax=255d+floor(d/2),
        // choose 2^k>Qmax*d and M=ceil(2^k/d). The error over Q/d is less than
        // 1/d, too little to cross an integer boundary.
        const divisor = reduction * reduction;
        const max_numerator = 255 * divisor + divisor / 2;
        const shift: u5 = @intCast(32 - @clz(max_numerator * divisor));
        return .{
            .values = try allocator.alloc([3]u16, right - left + 1),
            .first = left,
            .reduction = @intCast(reduction),
            .reciprocal_shift = shift,
            .reciprocal = @intCast(((@as(u32, 1) << shift) + divisor - 1) / divisor),
        };
    }

    pub fn deinit(self: *Layer, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
        self.* = .{};
    }

    pub fn start(self: *Layer, x: u32) void {
        const n = 2 * @as(i64, x) + 1 - self.reduction;
        const d: u5 = 2 * @as(u5, self.reduction);
        self.cursor = @intCast(@divFloor(n, d) - self.first);
        self.fraction = @intCast(@mod(n, d));
    }

    /// y is a top-down INFO row; first/count select entries within values.
    /// Layer interpolation itself is anchored to the page's bottom-left grid.
    pub fn prepare(self: *Layer, image: *const Pixmap, info: Info, y: u32, gamma: *const [256]u8, first: usize, count: usize) void {
        const d: u5 = 2 * @as(u5, self.reduction);
        const n = 2 * @as(i64, info.height - 1 - y) + 1 - self.reduction;
        const iy = @divFloor(n, d);
        const fy: u5 = @intCast(@mod(n, d));
        const y0: u32 = @intCast(std.math.clamp(iy, 0, image.height - 1));
        const y1: u32 = if (self.reduction == 1) y0 else @intCast(std.math.clamp(iy + 1, 0, image.height - 1));
        const offset = self.first - image.area().x;
        const bottom = image.row(image.height - 1 - y0)[offset..];
        const top = image.row(image.height - 1 - y1)[offset..];
        if (comptime (std.simd.suggestVectorLength(u16) orelse 1) >= 8) {
            if (info.gamma_tenths == 22) {
                blendIdentity(self.values[first..][0..count], bottom[first..][0..count], top[first..][0..count], d - fy, fy);
                return;
            }
        }
        for (self.values[first..][0..count], bottom[first..][0..count], top[first..][0..count]) |*out, b, t| {
            for (out, b, t) |*v, lo, hi| v.* = @as(u16, gamma[lo]) * (d - fy) + @as(u16, gamma[hi]) * fy;
        }
    }

    fn blendIdentity(values: [][3]u16, bottom: []const [3]u8, top: []const [3]u8, lo_weight: u5, hi_weight: u5) void {
        // Lanes are consecutive color components, crossing RGB pixel boundaries.
        const out = std.mem.bytesAsSlice(u16, std.mem.sliceAsBytes(values));
        const lo = std.mem.sliceAsBytes(bottom);
        const hi = std.mem.sliceAsBytes(top);
        var i: usize = 0;
        const V = @Vector(8, u16);
        const wl: V = @splat(lo_weight);
        const wh: V = @splat(hi_weight);
        while (i + 8 <= out.len) : (i += 8) {
            const l: V = @intCast(@as(@Vector(8, u8), lo[i..][0..8].*));
            const h: V = @intCast(@as(@Vector(8, u8), hi[i..][0..8].*));
            out[i..][0..8].* = l * wl + h * wh;
        }
        for (out[i..], lo[i..], hi[i..]) |*v, l, h| v.* = @as(u16, l) * lo_weight + @as(u16, h) * hi_weight;
    }

    /// Reuse each pair of layer columns until the horizontal phase crosses it.
    /// Numerators advance exactly; rounding still occurs once per output sample.
    pub fn fill(self: *Layer, output: [][3]u8) void {
        if (self.reduction == 1) {
            // The two grids coincide. Vertical preparation is exactly twice
            // the gamma-corrected sample; no horizontal neighbour is needed.
            const first: usize = @intCast(self.cursor);
            for (output, self.values[first..][0..output.len]) |*out, value| {
                for (out, value) |*channel, c| channel.* = @intCast(c >> 1);
            }
            self.cursor += @intCast(output.len);
            return;
        }
        if (std.math.isPowerOfTwo(self.reduction)) self.fillGroups(output, true) else self.fillGroups(output, false);
    }

    fn fillGroups(self: *Layer, output: [][3]u8, comptime power_of_two: bool) void {
        const d: i32 = 2 * @as(i32, self.reduction);
        const rounding = @divTrunc(d * d, 2);
        const normalization_shift: u5 = @intCast(2 * (@ctz(@as(u32, self.reduction)) + 1));
        const last: i32 = @intCast(self.values.len - 1);
        var cursor = self.cursor;
        var fraction: i32 = self.fraction;
        var i: usize = 0;
        while (i != output.len) {
            const left = self.values[@intCast(std.math.clamp(cursor, 0, last))];
            const right = self.values[@intCast(std.math.clamp(cursor + 1, 0, last))];
            const n = @min(output.len - i, @as(usize, @intCast(@divTrunc(d - fraction + 1, 2))));
            var values: [3]i32 = undefined;
            var deltas: [3]i32 = undefined;
            // Signed arithmetic supports descending channels and the unused
            // one-past numerator. Even that value stays between -12240 and 160000.
            for (&values, &deltas, left, right) |*value, *delta, l, r| {
                const difference = @as(i32, r) - l;
                value.* = @as(i32, l) * d + difference * fraction + rounding;
                delta.* = 2 * difference;
            }
            for (output[i..][0..n]) |*out| {
                for (out, &values, deltas) |*channel, *value, delta| {
                    const positive: u32 = @intCast(value.*);
                    channel.* = if (power_of_two) @intCast(positive >> normalization_shift) else self.normalize(positive);
                    value.* += delta;
                }
            }
            fraction += 2 * @as(i32, @intCast(n));
            if (fraction >= d) {
                fraction -= d;
                cursor += 1;
            }
            i += n;
        }
        self.cursor = cursor;
        self.fraction = @intCast(fraction);
    }

    pub inline fn pixel(self: *const Layer) [3]u8 {
        const last: i32 = @intCast(self.values.len - 1);
        const x0: usize = @intCast(std.math.clamp(self.cursor, 0, last));
        const x1: usize = @intCast(std.math.clamp(self.cursor + 1, 0, last));
        const d: u5 = 2 * @as(u5, self.reduction);
        const divisor = @as(u32, d) * d;
        var rgb: [3]u8 = undefined;
        for (&rgb, self.values[x0], self.values[x1]) |*c, left, right| {
            const value = @as(u32, left) * (d - self.fraction) + @as(u32, right) * self.fraction + divisor / 2;
            c.* = self.normalize(value);
        }
        return rgb;
    }

    pub inline fn normalize(self: *const Layer, value: u32) u8 {
        // For r in 1..12, Q <= 36792 and M <= 58255; their product fits in u32.
        const numerator: u16 = @intCast(value >> 2);
        return @intCast((@as(u32, numerator) * self.reciprocal) >> self.reciprocal_shift);
    }

    /// Advance over a bounded hidden span without sampling its colors.
    pub fn skip(self: *Layer, count: u32) void {
        const fraction = @as(u32, self.fraction) + 2 * count;
        const d: u32 = 2 * @as(u32, self.reduction);
        self.cursor += @intCast(fraction / d);
        self.fraction = @intCast(fraction % d);
    }

    pub fn advance(self: *Layer) void {
        self.fraction += 2;
        if (self.fraction >= 2 * @as(u5, self.reduction)) {
            self.fraction -= 2 * @as(u5, self.reduction);
            self.cursor += 1;
        }
    }
};

pub const Rows = struct {
    /// Requested output rectangle with rotation undone; still in output pixels.
    area: Region,
    /// Full-size sampling skips the RGB row and both area-filter buffers.
    identity: bool,
    bg: Layer = .{},
    fg: Layer = .{},
    rgb: [][3]u8,
    horizontal: [][3]u32,
    sums: [][3]u64,
    columns: []Column,
    // Prepare the columns once. Each source row then passes through layer
    // preparation, composition and horizontal filtering before accumulation.
    // Emit only when all source rows contributing to one output row are ready.
    phase: enum { columns, begin, background, foreground, compose, horizontal, accumulate, emit } = .columns,
    /// Position within the buffer processed by the current phase.
    cursor: usize = 0,
    source_y: u32 = 0,
    /// Source row represented by horizontal; adjacent output rows may share it.
    cached_y: ?u32 = null,
    /// Output row relative to area.y, independent of rotated destination order.
    output_y: u32 = 0,
    /// Index in the current vertical sampling window, not a page coordinate.
    source_row_index: u32 = 0,
    weight_y: u32 = 0,
    /// Product of the page-wide axis weight totals, unchanged by cropping.
    total_weight: u64 = 0,
    /// Partial horizontal column survives work-budget exhaustion within a span.
    horizontal_sum: [3]u32 = .{0} ** 3,
    horizontal_sample: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, source: Region, transform: Transform, identity: bool) std.mem.Allocator.Error!Rows {
        const area = transform.unrotatedRegion();
        const width = if (identity) 0 else area.width;
        const rgb = try allocator.alloc([3]u8, if (identity) 0 else source.width);
        errdefer allocator.free(rgb);
        const horizontal = try allocator.alloc([3]u32, width);
        errdefer allocator.free(horizontal);
        const sums = try allocator.alloc([3]u64, width);
        errdefer allocator.free(sums);
        const columns = try allocator.alloc(Column, width);
        return .{
            .area = area,
            .identity = identity,
            .phase = if (identity) .begin else .columns,
            .rgb = rgb,
            .horizontal = horizontal,
            .sums = sums,
            .columns = columns,
        };
    }

    /// Charge one unit per source contribution, including fractional edges.
    /// Complete windows handle their two edges outside the uniform-weight loop;
    /// partial windows preserve the accumulator across small work budgets.
    /// Return consumed work; cursor remains at the next unfinished column.
    pub fn filterHorizontal(self: *Rows, interior: u16, work: usize) usize {
        var remaining = work;
        while (remaining != 0 and self.cursor != self.horizontal.len) {
            const axis = self.columns[self.cursor];
            if (self.horizontal_sample == 0 and remaining >= axis.count) {
                const pixels = self.rgb[axis.first..][0..axis.count];
                var sum: [3]u32 = undefined;
                for (&sum, pixels[0]) |*s, c| s.* = @as(u32, c) * axis.first_weight;
                if (pixels.len != 1) {
                    for (pixels[1 .. pixels.len - 1]) |rgb| {
                        for (&sum, rgb) |*s, c| s.* += @as(u32, c) * interior;
                    }
                    for (&sum, pixels[pixels.len - 1]) |*s, c| s.* += @as(u32, c) * axis.last_weight;
                }
                self.horizontal[self.cursor] = sum;
                self.cursor += 1;
                remaining -= axis.count;
            } else {
                const count: u32 = @intCast(@min(remaining, axis.count - self.horizontal_sample));
                const first = @as(usize, axis.first) + self.horizontal_sample;
                for (self.rgb[first..][0..count], self.horizontal_sample..) |rgb, index| {
                    const weight = axis.weight(@intCast(index), interior);
                    for (&self.horizontal_sum, rgb) |*sum, c| sum.* += @as(u32, c) * weight;
                }
                self.horizontal_sample += count;
                remaining -= count;
                if (self.horizontal_sample == axis.count) {
                    self.horizontal[self.cursor] = self.horizontal_sum;
                    self.horizontal_sum = .{0} ** 3;
                    self.horizontal_sample = 0;
                    self.cursor += 1;
                }
            }
        }
        return work - remaining;
    }

    pub fn deinit(self: *Rows, allocator: std.mem.Allocator) void {
        self.bg.deinit(allocator);
        self.fg.deinit(allocator);
        allocator.free(self.rgb);
        allocator.free(self.horizontal);
        allocator.free(self.sums);
        allocator.free(self.columns);
        self.* = undefined;
    }
};
