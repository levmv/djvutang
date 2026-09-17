//! Source coordinates are unrotated INFO pixels, top-left, half-open bounds.
//! Output coordinates include reduction padding, both rotations and region origin.
const Error = @import("types.zig").Error;
const Info = @import("iff.zig").Info;

/// Integer rectangle; its owner defines the coordinate space and validity rules.
pub const Region = struct { x: u32, y: u32, width: u32, height: u32 };
pub const Size = struct { width: u32, height: u32 };
pub const Options = struct {
    /// Integer reduction factor, 1..256; 2 halves each dimension.
    subsample: u16 = 1,
    /// Fit inside this box, preserving aspect ratio. Can enlarge; excludes subsample != 1.
    /// Each IW44 layer uses 1/2/4 reconstruction selected by output size before
    /// area filtering, preserving original masks and palette assignments.
    /// Full-resolution views and integer subsample use full reconstruction.
    size: ?Size = null,
    /// Additional counterclockwise quarter turns on top of INFO rotation.
    rotation: u2 = 0,
    /// Nonempty output rectangle after reduction and rotation, top-left origin;
    /// must fit wholly inside the page.
    region: ?Region = null,
};
pub const Bounds = extern struct { x: i32, y: i32, width: i32, height: i32 };
pub const Point = struct { x: f64, y: f64 };
pub const Rect = struct { x: f64, y: f64, width: f64, height: f64 };

/// [a,b,c,d,e,f]: (x,y) -> (a*x+c*y+e, b*x+d*y+f).
pub const Matrix = [6]f64;

pub fn mapPoint(m: Matrix, p: Point) Point {
    return .{ .x = m[0] * p.x + m[2] * p.y + m[4], .y = m[1] * p.x + m[3] * p.y + m[5] };
}

pub fn mapRect(m: Matrix, r: Rect) Rect {
    const points = [_]Point{
        mapPoint(m, .{ .x = r.x, .y = r.y }),
        mapPoint(m, .{ .x = r.x + r.width, .y = r.y }),
        mapPoint(m, .{ .x = r.x, .y = r.y + r.height }),
        mapPoint(m, .{ .x = r.x + r.width, .y = r.y + r.height }),
    };
    var lo = points[0];
    var hi = lo;
    for (points[1..]) |p| {
        lo.x = @min(lo.x, p.x);
        lo.y = @min(lo.y, p.y);
        hi.x = @max(hi.x, p.x);
        hi.y = @max(hi.y, p.y);
    }
    return .{ .x = lo.x, .y = lo.y, .width = hi.x - lo.x, .height = hi.y - lo.y };
}

pub const Geometry = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    page_width: u32,
    page_height: u32,
    rotation: u2,

    pub fn init(info: Info, options: Options) Error!Geometry {
        if (options.subsample == 0 or options.subsample > 256) return error.InvalidArgument;
        const rotation = info.rotation +% options.rotation;
        const w = if (rotation & 1 != 0) info.height else info.width;
        const h = if (rotation & 1 != 0) info.width else info.height;
        var page_width = (w + options.subsample - 1) / options.subsample;
        var page_height = (h + options.subsample - 1) / options.subsample;
        if (options.size) |box| {
            if (options.subsample != 1 or box.width == 0 or box.height == 0 or w == 0 or h == 0) return error.InvalidArgument;
            if (@as(u64, box.width) * h <= @as(u64, box.height) * w) {
                page_width = box.width;
                page_height = @intCast(@max(1, @as(u64, h) * box.width / w));
            } else {
                page_height = box.height;
                page_width = @intCast(@max(1, @as(u64, w) * box.height / h));
            }
        }
        const region = options.region orelse Region{ .x = 0, .y = 0, .width = page_width, .height = page_height };
        // Check the origin before subtraction to avoid unsigned underflow.
        if (region.width == 0 or region.height == 0 or
            region.x >= page_width or region.y >= page_height or
            region.width > page_width - region.x or region.height > page_height - region.y)
        {
            return error.InvalidArgument;
        }
        return .{
            .x = region.x,
            .y = region.y,
            .width = region.width,
            .height = region.height,
            .page_width = page_width,
            .page_height = page_height,
            .rotation = rotation,
        };
    }
};

pub const Transform = struct {
    geometry: Geometry,
    matrix: Matrix,
    inverse: Matrix,
    subsample: u32,
    /// Whole output grid before rotation or cropping, including integer padding.
    base_width: u32,
    base_height: u32,
    padding_top: u32,

    pub fn init(info: Info, options: Options) Error!Transform {
        const g = try Geometry.init(info, options);
        const ss: u32 = options.subsample;
        const bw = if (g.rotation & 1 == 0) g.page_width else g.page_height;
        const bh = if (g.rotation & 1 == 0) g.page_height else g.page_width;
        const padding = if (options.size == null) bh * ss - info.height else 0;
        const sx = if (options.size != null)
            @as(f64, @floatFromInt(bw)) / @as(f64, @floatFromInt(info.width))
        else
            1.0 / @as(f64, @floatFromInt(ss));
        const sy = if (options.size != null)
            @as(f64, @floatFromInt(bh)) / @as(f64, @floatFromInt(info.height))
        else
            sx;
        const w: f64 = @floatFromInt(bw);
        const h: f64 = @floatFromInt(bh);
        const p = @as(f64, @floatFromInt(padding)) * sy;
        var m: Matrix = switch (g.rotation) {
            0 => .{ sx, 0, 0, sy, 0, p },
            1 => .{ 0, -sx, sy, 0, p, w },
            2 => .{ -sx, 0, 0, -sy, w, h - p },
            3 => .{ 0, sx, -sy, 0, h - p, 0 },
        };
        m[4] -= @floatFromInt(g.x);
        m[5] -= @floatFromInt(g.y);
        const det = m[0] * m[3] - m[1] * m[2];
        const inverse: Matrix = .{
            m[3] / det,
            -m[1] / det,
            -m[2] / det,
            m[0] / det,
            (m[2] * m[5] - m[3] * m[4]) / det,
            (m[1] * m[4] - m[0] * m[5]) / det,
        };
        return .{
            .geometry = g,
            .matrix = m,
            .inverse = inverse,
            .subsample = ss,
            .base_width = bw,
            .base_height = bh,
            .padding_top = padding,
        };
    }

    /// Requested output rectangle in the unrotated output grid.
    pub fn unrotatedRegion(self: Transform) Region {
        const g = self.geometry;
        return switch (g.rotation) {
            0 => .{ .x = g.x, .y = g.y, .width = g.width, .height = g.height },
            1 => .{ .x = self.base_width - g.y - g.height, .y = g.x, .width = g.height, .height = g.width },
            2 => .{ .x = self.base_width - g.x - g.width, .y = self.base_height - g.y - g.height, .width = g.width, .height = g.height },
            3 => .{ .x = g.y, .y = self.base_height - g.x - g.width, .width = g.height, .height = g.width },
        };
    }

    /// Destination pixel index and stride for increasing unrotated output x.
    /// The caller supplies a span contained in unrotatedRegion().
    pub inline fn outputRow(self: Transform, x: u32, y: u32) struct { index: isize, stride: isize } {
        const g = self.geometry;
        const pos: [2]u32 = switch (g.rotation) {
            0 => .{ x, y },
            1 => .{ y, self.base_width - 1 - x },
            2 => .{ self.base_width - 1 - x, self.base_height - 1 - y },
            3 => .{ self.base_height - 1 - y, x },
        };
        return .{
            .index = @intCast(@as(usize, pos[1] - g.y) * g.width + pos[0] - g.x),
            .stride = switch (g.rotation) {
                0 => 1,
                1 => -@as(isize, @intCast(g.width)),
                2 => -1,
                3 => @intCast(g.width),
            },
        };
    }

    pub fn point(self: Transform, p: Point) Point {
        return mapPoint(self.matrix, p);
    }

    pub fn unmap(self: Transform, p: Point) Point {
        return mapPoint(self.inverse, p);
    }

    pub fn bounds(self: Transform, b: Bounds) Rect {
        return self.rect(.{
            .x = @floatFromInt(b.x),
            .y = @floatFromInt(b.y),
            .width = @floatFromInt(b.width),
            .height = @floatFromInt(b.height),
        });
    }

    pub fn rect(self: Transform, r: Rect) Rect {
        return mapRect(self.matrix, r);
    }

    /// Integer sample order for the compositor. x/y are region-local pixels.
    /// The same padded grid defines the continuous boundary transform above.
    pub fn sample(self: Transform, x: u32, y: u32, index: u32) [2]i64 {
        const base = self.basePixel(x, y);
        return .{
            base[0] * self.subsample + index % self.subsample,
            @as(i64, base[1] * self.subsample + index / self.subsample) - self.padding_top,
        };
    }

    fn basePixel(self: Transform, x: u32, y: u32) [2]u32 {
        const ax = x + self.geometry.x;
        const ay = y + self.geometry.y;
        return switch (self.geometry.rotation) {
            0 => .{ ax, ay },
            1 => .{ self.base_width - 1 - ay, ax },
            2 => .{ self.base_width - 1 - ax, self.base_height - 1 - ay },
            3 => .{ ay, self.base_height - 1 - ax },
        };
    }

    pub fn window(self: Transform, info: Info, x: u32, y: u32) Window {
        const base = self.basePixel(x, y);
        return .{
            .x = Axis.init(base[0], info.width, self.base_width),
            .y = Axis.init(base[1], info.height, self.base_height),
        };
    }

    /// Clamped source samples for one region-local output pixel.
    pub fn sampleRegion(self: Transform, info: Info, sized: bool, x: u32, y: u32) Region {
        const first, const last = if (sized) blk: {
            const w = self.window(info, x, y);
            break :blk .{
                [2]i64{ w.x.coordinate(0), w.y.coordinate(0) },
                [2]i64{ w.x.coordinate(w.x.count - 1), w.y.coordinate(w.y.count - 1) },
            };
        } else .{ self.sample(x, y, 0), self.sample(x, y, self.subsample * self.subsample - 1) };
        const left = @max(0, @min(info.width - 1, first[0]));
        const top = @max(0, @min(info.height - 1, first[1]));
        const right = @max(0, @min(info.width - 1, last[0]));
        const bottom = @max(0, @min(info.height - 1, last[1]));
        return .{
            .x = @intCast(left),
            .y = @intCast(top),
            .width = @intCast(right - left + 1),
            .height = @intCast(bottom - top + 1),
        };
    }

    /// All clamped source samples used by this output rectangle, including
    /// interpolation neighbours and integer-reduction padding.
    pub fn sourceRegion(self: Transform, info: Info, sized: bool) Region {
        var left: i64 = info.width;
        var top: i64 = info.height;
        var right: i64 = 0;
        var bottom: i64 = 0;
        for ([_]u32{ 0, self.geometry.width - 1 }) |x| {
            for ([_]u32{ 0, self.geometry.height - 1 }) |y| {
                const r = self.sampleRegion(info, sized, x, y);
                left = @min(left, r.x);
                top = @min(top, r.y);
                right = @max(right, r.x + r.width - 1);
                bottom = @max(bottom, r.y + r.height - 1);
            }
        }
        return .{
            .x = @intCast(left),
            .y = @intCast(top),
            .width = @intCast(right - left + 1),
            .height = @intCast(bottom - top + 1),
        };
    }
};

/// Exact area weights when shrinking; 16-bit bilinear weights when enlarging.
/// Anchored to the entire page, so tiles use the same samples as a full render.
pub const Axis = struct {
    first: i64,
    count: u32,
    source: u32,
    output: u32,
    first_weight: u32,
    last_weight: u32,
    total: u32,

    pub fn init(pixel: u32, source: u32, output: u32) Axis {
        if (output <= source) {
            const left = @as(u64, pixel) * source;
            const right = @as(u64, pixel + 1) * source;
            const first: u32 = @intCast(left / output);
            const end: u32 = @intCast((right + output - 1) / output);
            // Interior cells have full weight. Only the two edges intersect
            // fractional cells; compute those intersections once per window.
            return .{
                .first = first,
                .count = end - first,
                .source = source,
                .output = output,
                .first_weight = @intCast(@min(right, @as(u64, first + 1) * output) - left),
                .last_weight = @intCast(right - @max(left, @as(u64, end - 1) * output)),
                .total = source,
            };
        }
        const denominator = @as(i64, output) * 2;
        const centre = (2 * @as(i64, pixel) + 1) * source - output;
        const fraction: u64 = @intCast(@mod(centre, denominator));
        const last_weight: u32 = @intCast(fraction * 65536 / @as(u64, @intCast(denominator)));
        return .{
            .first = @divFloor(centre, denominator),
            .count = 2,
            .source = source,
            .output = output,
            .first_weight = 65536 - last_weight,
            .last_weight = last_weight,
            .total = 65536,
        };
    }

    pub fn coordinate(self: Axis, index: u32) i64 {
        return @max(0, @min(self.source - 1, self.first + index));
    }

    pub fn weight(self: Axis, index: u32) u32 {
        if (index == 0) return self.first_weight;
        if (index == self.count - 1) return self.last_weight;
        return self.output;
    }
};
// Format dimensions fit in 16 bits. Each axis sums to the source dimension
// when shrinking, or 65536 when enlarging. A two-axis weight can equal 2^32.
// Keeping that bound in the type lets checked RGB multiplication fit in u64.
pub const Coverage = u33;
pub const Window = struct {
    x: Axis,
    y: Axis,

    pub fn total(self: Window) Coverage {
        return @intCast(@as(u64, self.x.total) * self.y.total);
    }

    pub fn weight(self: Window, x: u32, y: u32) Coverage {
        return @intCast(@as(u64, self.x.weight(x)) * self.y.weight(y));
    }
};
