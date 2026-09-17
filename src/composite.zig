//! Resumable mask rasterization, layer sampling and RGBA composition.
//! Sampling uses the unrotated page grid; geometry owns output size and rotation.
const std = @import("std");
const Error = @import("types.zig").Error;
const Info = @import("iff.zig").Info;
const Image = @import("jb2.zig").Image;
const Pixmap = @import("pixmap.zig").Pixmap;
const Bitmap = @import("pixmap.zig").Bitmap;
const color = @import("color.zig");
const row_filter = @import("composite_rows.zig");
const mask_filter = @import("mask_rows.zig");

pub const Layers = struct {
    mask: ?union(enum) { symbols: *const Image, bitmap: *const Bitmap } = null,
    background: ?*const Pixmap = null,
    foreground: ?*const Pixmap = null,
    palette: ?*const color.Palette = null,
};

const ColorIndices = union(enum) {
    constant,
    compact: struct { bytes: []u8, bits: u3 },
    byte: []u8,
    word: []u16,

    fn init(allocator: std.mem.Allocator, pixels: usize, colors: usize) Error!ColorIndices {
        if (colors <= 1) return .constant;
        // The union mask already records whether a pixel has ink. No sentinel
        // color is needed, so all 256 byte values remain available to a palette.
        if (colors <= 16) {
            const bits: u3 = if (colors <= 2) 1 else if (colors <= 4) 2 else 4;
            const per_byte = @as(usize, 8) / bits;
            const bytes = try allocator.alloc(u8, (pixels + per_byte - 1) / per_byte);
            @memset(bytes, 0);
            return .{ .compact = .{ .bytes = bytes, .bits = bits } };
        }
        return if (colors <= 256)
            .{ .byte = try allocator.alloc(u8, pixels) }
        else
            .{ .word = try allocator.alloc(u16, pixels) };
    }

    fn deinit(self: ColorIndices, allocator: std.mem.Allocator) void {
        switch (self) {
            .constant => {},
            .compact => |p| allocator.free(p.bytes),
            .byte => |bytes| allocator.free(bytes),
            .word => |words| allocator.free(words),
        }
    }

    fn set(self: ColorIndices, pixel: usize, index: u16) void {
        switch (self) {
            .constant => {},
            .compact => |p| {
                const per_byte = @as(usize, 8) / p.bits;
                const shift: u3 = @intCast((pixel % per_byte) * p.bits);
                const mask = ((@as(u8, 1) << p.bits) - 1) << shift;
                p.bytes[pixel / per_byte] = (p.bytes[pixel / per_byte] & ~mask) | (@as(u8, @intCast(index)) << shift);
            },
            .byte => |bytes| bytes[pixel] = @intCast(index),
            .word => |words| words[pixel] = index,
        }
    }

    fn get(self: ColorIndices, pixel: usize) u16 {
        return switch (self) {
            .constant => 0,
            .compact => |p| blk: {
                const per_byte = @as(usize, 8) / p.bits;
                const shift: u3 = @intCast((pixel % per_byte) * p.bits);
                break :blk (p.bytes[pixel / per_byte] >> shift) & ((@as(u8, 1) << p.bits) - 1);
            },
            .byte => |bytes| bytes[pixel],
            .word => |words| words[pixel],
        };
    }
};

const geometry_module = @import("geometry.zig");
pub const Region = geometry_module.Region;
pub const Options = geometry_module.Options;
pub const Geometry = geometry_module.Geometry;

/// Layer samples touched by a rectangle of clamped, top-down page pixels.
pub fn layerRegion(info: Info, layer: *const Pixmap, reduction: u32, source: Region) Region {
    if (layer.sample_step != 0) {
        const s = layer.sample_step;
        const left = source.x / s;
        const bottom = (info.height - source.y - source.height) / s;
        const top = (info.height - source.y - 1) / s + 1;
        return .{ .x = left, .y = layer.height - top, .width = (source.x + source.width - 1) / s + 1 - left, .height = top - bottom };
    }
    const x = layerSamples(source.x, source.width, layer.width, reduction);
    const y = layerSamples(info.height - source.y - source.height, source.height, layer.height, reduction);
    return .{
        .x = x[0],
        .y = layer.height - y[1],
        .width = x[1] - x[0],
        .height = y[1] - y[0],
    };
}

fn layerSamples(first: u32, count: u32, limit: u32, reduction: u32) [2]u32 {
    const d: i64 = 2 * reduction;
    const neighbour: i64 = if (reduction == 1) 0 else 1;
    const lo = @divFloor(2 * @as(i64, first) + 1 - reduction, d);
    const hi = @divFloor(2 * @as(i64, first + count - 1) + 1 - reduction, d) + neighbour;
    return .{ @intCast(std.math.clamp(lo, 0, limit - 1)), @intCast(std.math.clamp(hi, 0, limit - 1) + 1) };
}

const LayerColor = union(enum) {
    checking: usize,
    solid: [3]u8,
    sampled: *const Pixmap,
    palette,

    fn init(layer: ?*const Pixmap, fallback: u8) LayerColor {
        const image = layer orelse return .{ .solid = .{fallback} ** 3 };
        return if (image.contains(.{ .x = 0, .y = 0, .width = image.width, .height = image.height }))
            .{ .checking = 0 }
        else
            .{ .sampled = image };
    }

    fn check(self: *LayerColor, layer: *const Pixmap, gamma: *const [256]u8) void {
        // A regional buffer may hold a complete compact grid plus spare capacity.
        const count = @as(usize, layer.width) * layer.height;
        const end = @min(self.checking + 64, count);
        const first = layer.pixels[0];
        for (layer.pixels[self.checking..end]) |rgb| {
            if (!std.mem.eql(u8, &first, &rgb)) {
                self.* = .{ .sampled = layer };
                return;
            }
        }
        self.* = if (end == count)
            .{ .solid = .{ gamma[first[0]], gamma[first[1]], gamma[first[2]] } }
        else
            .{ .checking = end };
    }
};

/// Consecutive source pixels share their layer rows and vertical weights.
/// Advance the horizontal interpolation phase without division per pixel.
/// Spans stay within shrinking windows; padding and enlargement remain scalar.
const LayerSpan = struct {
    rows: [2][]const [3]u8,
    reduction: u32,
    x: i64,
    fx: u32,
    fy: u32,

    fn init(info: Info, layer: *const Pixmap, reduction: u32, x: i64, y: i64, comptime regional: bool) LayerSpan {
        const px = std.math.clamp(x, 0, info.width - 1);
        const py = info.height - 1 - std.math.clamp(y, 0, info.height - 1);
        const den: i64 = 2 * reduction;
        const nx = 2 * px + 1 - reduction;
        const ny = 2 * py + 1 - reduction;
        const iy = @divFloor(ny, den);
        const bottom: u32 = @intCast(std.math.clamp(iy, 0, layer.height - 1));
        const top: u32 = if (regional and reduction == 1) bottom else @intCast(std.math.clamp(iy + 1, 0, layer.height - 1));
        const bottom_y = layer.height - 1 - bottom;
        const top_y = layer.height - 1 - top;
        return .{
            .rows = if (regional) .{
                layer.row(bottom_y),
                layer.row(top_y),
            } else .{
                layer.pixels[@as(usize, bottom_y) * layer.width ..][0..layer.width],
                layer.pixels[@as(usize, top_y) * layer.width ..][0..layer.width],
            },
            .reduction = reduction,
            .x = @divFloor(nx, den) - (if (regional) layer.area().x else 0),
            .fx = @intCast(@mod(nx, den)),
            .fy = @intCast(@mod(ny, den)),
        };
    }

    fn pixel(self: *const LayerSpan, gamma: *const [256]u8) [3]u8 {
        if (self.reduction == 1) {
            const rgb = self.rows[0][@intCast(self.x)];
            return .{ gamma[rgb[0]], gamma[rgb[1]], gamma[rgb[2]] };
        }
        const x0: usize = @intCast(std.math.clamp(self.x, 0, self.rows[0].len - 1));
        const x1: usize = @intCast(std.math.clamp(self.x + 1, 0, self.rows[0].len - 1));
        const d = 2 * self.reduction;
        const samples = [4][3]u8{ self.rows[0][x0], self.rows[0][x1], self.rows[1][x0], self.rows[1][x1] };
        const weights = [4]u32{
            (d - self.fx) * (d - self.fy),
            self.fx * (d - self.fy),
            (d - self.fx) * self.fy,
            self.fx * self.fy,
        };
        var result: [3]u8 = undefined;
        for (&result, 0..) |*channel, c| {
            var value: u32 = 0;
            for (samples, weights) |rgb, weight| value += gamma[rgb[c]] * weight;
            channel.* = @intCast((value + d * d / 2) / (d * d));
        }
        return result;
    }

    fn advance(self: *LayerSpan) void {
        self.fx += 2;
        if (self.fx >= 2 * self.reduction) {
            self.fx -= 2 * self.reduction;
            self.x += 1;
        }
    }
};

const ColorSpan = struct { background: ?LayerSpan, foreground: ?LayerSpan };

/// Union mask prevents overlapping symbols from counting the same pixel twice.
/// Each work unit visits one source pixel or a bounded group of uniform samples.
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    info: Info,
    options: Options,
    geometry: Geometry,
    transform: geometry_module.Transform,
    layers: Layers,
    gamma: [256]u8,
    bg_reduction: u32 = 1,
    fg_reduction: u32 = 1,
    bg_color: LayerColor,
    fg_color: LayerColor,
    plan: enum { classify, bilevel, solid, general },
    mask: []u8,
    owns_mask: bool,
    color_indices: ColorIndices,
    rgba: []u8,
    blit: usize = 0,
    shape_pixel: usize = 0,
    rasterized: bool = false,
    /// Completed pixel count. The row plan can write in rotated order, so this
    /// is a destination position only on the ordinary output-window paths.
    output_pixel: usize = 0,
    sample: u32 = 0,
    ink: u64 = 0,
    sum: [3]u32 = .{0} ** 3,
    window: ?geometry_module.Window = null,
    weighted: [3]u64 = .{0} ** 3,
    regional: bool,
    reduced: bool,
    source_area: Region,
    /// Suspend before sampling an absent regional raster. The job fills its
    /// layers, then resumes without discarding a partially accumulated pixel.
    needed: ?Region = null,
    prepared_pixel: ?usize = null,
    /// Select once per render; only the chosen row plan owns workspace.
    /// Completion, restart and reclassification return to unselected.
    rows: union(enum) { unselected, scalar, color: *row_filter.Rows, mask: *mask_filter.Rows } = .unselected,

    pub fn init(allocator: std.mem.Allocator, info: Info, options: Options, layers: Layers) Error!Renderer {
        const transform = try geometry_module.Transform.init(info, options);
        const geometry = transform.geometry;
        const bg_reduction = if (layers.background) |bg|
            if (bg.sample_step != 0) bg.sample_step else try color.reduction(info.width, info.height, bg.width, bg.height)
        else
            1;
        const fg_reduction = if (layers.foreground) |fg|
            if (fg.sample_step != 0) fg.sample_step else try color.reduction(info.width, info.height, fg.width, fg.height)
        else
            1;
        const reduced = hasReduced(layers);
        if (reduced and options.size == null) return error.InvalidArgument;
        const page_pixels = std.math.mul(usize, info.width, info.height) catch return error.LimitExceeded;
        const output_pixels = std.math.mul(usize, geometry.width, geometry.height) catch return error.LimitExceeded;
        const bytes = std.math.mul(usize, output_pixels, 4) catch return error.LimitExceeded;
        const bitmap = if (layers.mask) |m| switch (m) {
            .bitmap => |b| b,
            .symbols => null,
        } else null;
        const mask = if (bitmap) |b|
            b.pixels
        else
            try allocator.alloc(u8, if (layers.mask != null) (page_pixels + 7) / 8 else 0);
        errdefer if (bitmap == null) allocator.free(mask);
        if (bitmap == null) @memset(mask, 0);
        const indices = try ColorIndices.init(allocator, page_pixels, if (layers.palette) |p| p.colors.len else 0);
        errdefer indices.deinit(allocator);
        const rgba = try allocator.alloc(u8, bytes);
        const gamma = color.gamma(info.gamma_tenths);
        var fg_color = LayerColor.init(layers.foreground, 0);
        if (layers.palette) |p| {
            fg_color = if (p.colors.len == 1)
                .{ .solid = .{ gamma[p.colors[0][0]], gamma[p.colors[0][1]], gamma[p.colors[0][2]] } }
            else
                .palette;
        }
        const bilevel = layers.background == null and layers.foreground == null and layers.palette == null;
        return .{
            .allocator = allocator,
            .info = info,
            .options = options,
            .geometry = geometry,
            .transform = transform,
            .layers = layers,
            .gamma = gamma,
            .bg_reduction = bg_reduction,
            .fg_reduction = fg_reduction,
            .bg_color = LayerColor.init(layers.background, 255),
            .fg_color = fg_color,
            .plan = if (bilevel) .bilevel else .classify,
            .mask = mask,
            .owns_mask = bitmap == null,
            .color_indices = indices,
            .rgba = rgba,
            .rasterized = bitmap != null or layers.mask == null,
            .regional = (if (layers.background) |bg| bg.region != null else false) or
                (if (layers.foreground) |fg| fg.region != null else false),
            .reduced = reduced,
            .source_area = transform.sourceRegion(info, options.size != null),
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.clearRows();
        if (self.owns_mask) self.allocator.free(self.mask);
        self.color_indices.deinit(self.allocator);
        self.allocator.free(self.rgba);
        self.* = undefined;
    }

    pub fn restart(self: *Renderer, options: Options) Error!void {
        if (!self.rasterized) return error.Busy;
        const transform = try geometry_module.Transform.init(self.info, options);
        const geometry = transform.geometry;
        const pixels = std.math.mul(usize, geometry.width, geometry.height) catch return error.LimitExceeded;
        const bytes = std.math.mul(usize, pixels, 4) catch return error.LimitExceeded;
        // Failure preserves completed pixels. After success the owner may change
        // layer grids before stepping; restart must reselect the sampling plan.
        const rgba = try self.allocator.realloc(self.rgba, bytes);
        self.clearRows();
        self.rgba = rgba;
        self.geometry = geometry;
        self.transform = transform;
        self.options = options;
        self.output_pixel = 0;
        self.sample = 0;
        self.ink = 0;
        self.sum = .{0} ** 3;
        self.window = null;
        self.weighted = .{0} ** 3;
        self.source_area = transform.sourceRegion(self.info, options.size != null);
        self.needed = null;
        self.prepared_pixel = null;
    }

    pub fn canClassifyLayer(self: *const Renderer) bool {
        // A filtered row can already contain contributions before the first
        // output pixel. Refilling another source strip must not discard them.
        return self.output_pixel == 0 and self.sample == 0 and
            switch (self.rows) {
                .color => |rows| rows.cached_y == null,
                .mask => |rows| rows.cached_y == null,
                else => true,
            };
    }

    /// Reconsider uniform color after changing or filling a layer's grid, only
    /// before accumulating output. A complete raster can use the solid-mask path;
    /// a uniform strip cannot establish the color of the rest of the layer.
    pub fn classifyLayer(self: *Renderer, index: usize) void {
        std.debug.assert(self.canClassifyLayer());
        self.clearRows();
        if (index == 0) {
            self.bg_color = .init(self.layers.background, 255);
        } else {
            self.fg_color = .init(self.layers.foreground, 0);
        }
        self.plan = .classify;
    }

    fn raster(self: *Renderer, work: usize) usize {
        const image = self.layers.mask.?.symbols;
        if (self.blit == image.blits.items.len) {
            self.rasterized = true;
            return 1;
        }
        const blit = image.blits.items[self.blit];
        const shape = image.shape(blit.shape);
        if (self.shape_pixel == shape.pixelCount()) {
            self.blit += 1;
            self.shape_pixel = 0;
            return 1;
        }
        const p = self.shape_pixel;
        const column = p % shape.width;
        const count = @min(work, shape.width - column);
        self.shape_pixel += count;
        const x = blit.left + @as(i64, @intCast(column));
        const y = blit.bottom + @as(i64, @intCast(p / shape.width));
        // Clip once for this part of the row. Skipped pixels still consume their
        // usual work units, preserving cancellation and record boundaries.
        const left = @max(x, 0);
        const right = @min(x + @as(i64, @intCast(count)), self.info.width);
        if (y < 0 or y >= self.info.height or left >= right) return count;
        const row = shape.row(@intCast(p / shape.width));
        var source = column + @as(usize, @intCast(left - x));
        var index = (self.info.height - 1 - @as(usize, @intCast(y))) * self.info.width + @as(usize, @intCast(left));
        var remaining: usize = @intCast(right - left);
        const palette_index = if (self.layers.palette) |palette| palette.indices[self.blit] else null;
        // Align each write to a destination byte. A source span may cross two
        // bytes; mask its tail so row padding and clipped ink cannot leak out.
        while (remaining != 0) {
            const shift: u3 = @intCast(index % 8);
            const source_shift: u3 = @intCast(source % 8);
            const n = @min(remaining, 8 - @as(usize, shift));
            var bits = row.pixels[source / 8] >> source_shift;
            if (n > 8 - @as(usize, source_shift))
                bits |= row.pixels[source / 8 + 1] << @intCast(8 - @as(u4, source_shift));
            bits &= @as(u8, 255) >> @intCast(8 - n);
            self.mask[index / 8] |= bits << shift;
            if (palette_index) |color_index| {
                var ink = bits;
                while (ink != 0) {
                    self.color_indices.set(index + @ctz(ink), color_index);
                    ink &= ink - 1;
                }
            }
            source += n;
            index += n;
            remaining -= n;
        }
        return count;
    }

    fn read(self: *const Renderer, x: i64, y: i64) u1 {
        const w = self.info.width;
        const h = self.info.height;
        if (self.mask.len == 0 or x < 0 or y < 0 or x >= w or y >= h) return 0;
        const index = @as(usize, @intCast(y)) * w + @as(usize, @intCast(x));
        return @truncate(self.mask[index / 8] >> @intCast(index % 8));
    }

    /// At most 64 consecutive pixels in a row, clipped before reading the packed
    /// mask. Rows have no byte padding; bits beyond the requested span never count.
    inline fn countInk(self: *const Renderer, x: i64, y: i64, count: u32) u32 {
        // Fractional window edges often need one bit. Keep their read inline
        // even when the larger grouped reader is compiled as a shared call.
        if (count == 1) return self.read(x, y);
        return self.countInkSpan(x, y, count);
    }

    fn countInkSpan(self: *const Renderer, x: i64, y: i64, count: u32) u32 {
        if (self.mask.len == 0 or y < 0 or y >= self.info.height) return 0;
        const left = @max(x, 0);
        const right = @min(x + count, self.info.width);
        if (left >= right) return 0;
        var index = @as(usize, @intCast(y)) * self.info.width + @as(usize, @intCast(left));
        var remaining: u32 = @intCast(right - left);
        var ink: u32 = 0;
        const byte = index / 8;
        if (self.mask.len - byte >= 8) {
            const shift: u6 = @intCast(index % 8);
            const bits = @min(remaining, 64 - @as(u32, shift));
            const word = std.mem.readInt(u64, self.mask[byte..][0..8], .little) >> shift;
            ink = @popCount(word & (@as(u64, std.math.maxInt(u64)) >> @as(u6, @intCast(64 - bits))));
            index += bits;
            remaining -= bits;
        }
        // A short tail, or the end of the allocation: never overread a word.
        while (remaining != 0) {
            const shift: u3 = @intCast(index % 8);
            const bits = @min(remaining, 8 - @as(u32, shift));
            const value = self.mask[index / 8] >> shift;
            ink += @popCount(value & (@as(u8, 255) >> @as(u3, @intCast(8 - bits))));
            index += bits;
            remaining -= bits;
        }
        return ink;
    }

    fn layerPixel(self: *const Renderer, pixmap: *const Pixmap, x: i64, bottom: i64, comptime regional: bool) [3]u8 {
        const sx: u32 = @intCast(std.math.clamp(x, 0, pixmap.width - 1));
        const sy: u32 = @intCast(std.math.clamp(bottom, 0, pixmap.height - 1));
        const rgb = if (regional)
            pixmap.row(pixmap.height - 1 - sy)[sx - pixmap.area().x]
        else
            pixmap.pixels[@as(usize, pixmap.height - 1 - sy) * pixmap.width + sx];
        return .{ self.gamma[rgb[0]], self.gamma[rgb[1]], self.gamma[rgb[2]] };
    }

    fn sampleLayer(self: *const Renderer, pixmap: *const Pixmap, reduction: u32, x: i64, y: i64, comptime regional: bool) [3]u8 {
        // Pixel centres on the layer's integer grid, anchored at the bottom left.
        // Clamping full-page edges keeps partial reduction cells free of white rims.
        const px = std.math.clamp(x, 0, self.info.width - 1);
        const py = self.info.height - 1 - std.math.clamp(y, 0, self.info.height - 1);
        if (reduction == 1) return self.layerPixel(pixmap, px, py, regional);
        const den: i64 = 2 * reduction;
        const nx = 2 * px + 1 - reduction;
        const ny = 2 * py + 1 - reduction;
        const ix = @divFloor(nx, den);
        const iy = @divFloor(ny, den);
        const fx: u32 = @intCast(@mod(nx, den));
        const fy: u32 = @intCast(@mod(ny, den));
        const d: u32 = @intCast(den);
        const samples = [4][3]u8{
            self.layerPixel(pixmap, ix, iy, regional),
            self.layerPixel(pixmap, ix + 1, iy, regional),
            self.layerPixel(pixmap, ix, iy + 1, regional),
            self.layerPixel(pixmap, ix + 1, iy + 1, regional),
        };
        const weights = [4]u32{ (d - fx) * (d - fy), fx * (d - fy), (d - fx) * fy, fx * fy };
        var result: [3]u8 = undefined;
        for (&result, 0..) |*channel, c| {
            var value: u32 = 0;
            for (samples, weights) |rgb, weight| value += rgb[c] * weight;
            channel.* = @intCast((value + d * d / 2) / (d * d));
        }
        return result;
    }

    fn pixel(self: *const Renderer, x: i64, y: i64, comptime regional: bool) [3]u8 {
        if (self.read(x, y) != 0) return switch (self.fg_color) {
            .solid => |rgb| rgb,
            .sampled => |fg| self.sampleLayer(fg, self.fg_reduction, x, y, regional),
            .palette => self.palettePixel(x, y),
            .checking => unreachable,
        };
        return switch (self.bg_color) {
            .solid => |rgb| rgb,
            .sampled => |bg| self.sampleLayer(bg, self.bg_reduction, x, y, regional),
            else => unreachable,
        };
    }

    fn palettePixel(self: *const Renderer, x: i64, y: i64) [3]u8 {
        const palette = self.layers.palette.?;
        const index = @as(usize, @intCast(y)) * self.info.width + @as(usize, @intCast(x));
        const rgb = palette.colors[self.color_indices.get(index)];
        return .{ self.gamma[rgb[0]], self.gamma[rgb[1]], self.gamma[rgb[2]] };
    }

    fn span(self: *const Renderer, x: i64, y: i64, comptime regional: bool) ColorSpan {
        return .{
            .background = if (self.bg_color == .sampled)
                LayerSpan.init(self.info, self.bg_color.sampled, self.bg_reduction, x, y, regional)
            else
                null,
            .foreground = if (self.fg_color == .sampled)
                LayerSpan.init(self.info, self.fg_color.sampled, self.fg_reduction, x, y, regional)
            else
                null,
        };
    }

    inline fn spanPixel(self: *const Renderer, samples: *ColorSpan, x: i64, y: i64) [3]u8 {
        const rgb = if (self.read(x, y) != 0) switch (self.fg_color) {
            .solid => |rgb| rgb,
            .sampled => samples.foreground.?.pixel(&self.gamma),
            .palette => self.palettePixel(x, y),
            .checking => unreachable,
        } else switch (self.bg_color) {
            .solid => |rgb| rgb,
            .sampled => samples.background.?.pixel(&self.gamma),
            else => unreachable,
        };
        if (samples.background) |*s| s.advance();
        if (samples.foreground) |*s| s.advance();
        return rgb;
    }

    // Avoid expanding the codec and mask loops with the full color-row engine.
    pub noinline fn step(self: *Renderer, work: usize) Error!bool {
        if (work == 0) return error.InvalidArgument;
        if (self.reduced and self.options.size == null) return error.InvalidArgument;
        const total = self.rgba.len / 4;
        if (self.output_pixel == total) return true;
        var remaining = work;
        while (remaining != 0 and !self.rasterized) remaining -= self.raster(remaining);
        if (!self.rasterized) return false;
        // Scan only complete rasters for uniform color, including compact grids.
        // Keep the scan cancellable; never classify a uniform strip as solid.
        while (remaining != 0 and self.plan == .classify) : (remaining -= 1) {
            if (self.bg_color == .checking) {
                self.bg_color.check(self.layers.background.?, &self.gamma);
            } else if (self.fg_color == .checking) {
                self.fg_color.check(self.layers.foreground.?, &self.gamma);
            } else {
                self.plan = if (self.bg_color == .solid and self.fg_color == .solid) .solid else .general;
            }
        }
        // Select the color path outside the per-pixel loops.
        switch (self.plan) {
            .classify => {},
            .bilevel, .solid => {
                const identity = self.options.subsample == 1 and
                    self.transform.base_width == self.info.width and self.transform.base_height == self.info.height;
                if (identity) {
                    // At 1:1, expand mask bits directly without filter buffers.
                    while (remaining != 0 and self.output_pixel != total) : (remaining -= 1) self.solidSpan();
                } else {
                    if (self.rows == .unselected) try self.initMaskRows();
                    if (self.rows == .mask) {
                        self.output_pixel += self.rows.mask.step(self.info, self.transform, self.mask, self.bg_color.solid, self.fg_color.solid, self.rgba, remaining);
                    } else {
                        while (remaining != 0 and self.output_pixel != total) : (remaining -= 1) self.solidPixel();
                    }
                }
            },
            .general => {
                if (self.rows == .unselected) try self.initRows();
                if (self.rows == .color) {
                    self.rowStep(remaining);
                } else if (self.regional) self.general(remaining, true) else self.general(remaining, false);
            },
        }
        if (self.output_pixel != total) return false;
        self.clearRows();
        return true;
    }

    fn clearRows(self: *Renderer) void {
        switch (self.rows) {
            .color => |rows| {
                rows.deinit(self.allocator);
                self.allocator.destroy(rows);
            },
            .mask => |rows| {
                rows.deinit(self.allocator);
                self.allocator.destroy(rows);
            },
            else => {},
        }
        self.rows = .unselected;
    }

    noinline fn initMaskRows(self: *Renderer) Error!void {
        self.rows = .scalar;
        const width = if (self.geometry.rotation & 1 == 0) self.geometry.width else self.geometry.height;
        // Integer reduction has distinct bilevel rounding and possible padding.
        // Enlargement and narrow crops use direct sampling.
        if (self.options.size == null or self.options.subsample != 1 or
            self.transform.base_width > self.info.width or self.transform.base_height > self.info.height or
            self.source_area.width < 64 or width < 16) return;
        var rows = try mask_filter.Rows.init(self.allocator, self.source_area, self.transform);
        errdefer rows.deinit(self.allocator);
        const owned = try self.allocator.create(mask_filter.Rows);
        owned.* = rows;
        self.rows = .{ .mask = owned };
    }

    /// Allocate width-sized workspace for exact color rows, released on completion.
    noinline fn initRows(self: *Renderer) Error!void {
        self.rows = .scalar;
        const output_width = if (self.geometry.rotation & 1 == 0) self.geometry.width else self.geometry.height;
        // Row setup does not pay off for narrow requests.
        if (self.reduced or self.options.subsample != 1 or
            self.transform.base_width > self.info.width or self.transform.base_height > self.info.height or
            self.source_area.width < 64 or output_width < 16) return;
        const identity = self.transform.base_width == self.info.width and self.transform.base_height == self.info.height;
        var rows = try row_filter.Rows.init(self.allocator, self.source_area, self.transform, identity);
        errdefer rows.deinit(self.allocator);
        rows.total_weight = @as(u64, self.info.width) * self.info.height;
        if (self.bg_color == .sampled) {
            rows.bg = try row_filter.Layer.init(self.allocator, self.bg_color.sampled, self.bg_reduction, self.source_area);
        }
        if (self.fg_color == .sampled) {
            rows.fg = try row_filter.Layer.init(self.allocator, self.fg_color.sampled, self.fg_reduction, self.source_area);
        }
        const owned = try self.allocator.create(row_filter.Rows);
        owned.* = rows;
        self.rows = .{ .color = owned };
    }

    /// Compose each source row once, horizontally filter it without rounding,
    /// then accumulate it into one output row. Adjacent output rows share at
    /// most one source row when shrinking; retain its horizontal sums. Every
    /// phase can stop within a row, and rotations only change destination writes.
    noinline fn rowStep(self: *Renderer, work: usize) void {
        const rows = self.rows.color;
        var remaining = work;
        while (remaining != 0 and self.output_pixel != self.rgba.len / 4) {
            switch (rows.phase) {
                .columns => {
                    const count = @min(remaining, rows.columns.len - rows.cursor);
                    for (rows.columns[rows.cursor..][0..count], rows.cursor..) |*column, x| {
                        const axis = geometry_module.Axis.init(@intCast(x + rows.area.x), self.info.width, self.transform.base_width);
                        column.* = .{
                            .first = @intCast(axis.first - self.source_area.x),
                            .count = @intCast(axis.count),
                            .first_weight = @intCast(axis.first_weight),
                            .last_weight = @intCast(axis.last_weight),
                        };
                    }
                    rows.cursor += count;
                    remaining -= count;
                    if (rows.cursor == rows.columns.len) rows.phase = .begin;
                },
                .begin => {
                    const axis = geometry_module.Axis.init(rows.area.y + rows.output_y, self.info.height, self.transform.base_height);
                    rows.source_y = @intCast(axis.coordinate(rows.source_row_index));
                    rows.weight_y = axis.weight(rows.source_row_index);
                    rows.cursor = 0;
                    if (rows.cached_y == rows.source_y) {
                        rows.phase = .accumulate;
                    } else {
                        const region: Region = .{
                            .x = self.source_area.x,
                            .y = rows.source_y,
                            .width = self.source_area.width,
                            .height = 1,
                        };
                        if (!self.hasSamples(region)) {
                            self.needed = region;
                            return;
                        }
                        self.needed = null;
                        rows.phase = .background;
                    }
                    remaining -= 1;
                },
                .background, .foreground => {
                    const background = rows.phase == .background;
                    const layer = if (background) &rows.bg else &rows.fg;
                    const count = @min(remaining, layer.values.len - rows.cursor);
                    if (count != 0) layer.prepare(
                        if (background) self.bg_color.sampled else self.fg_color.sampled,
                        self.info,
                        rows.source_y,
                        &self.gamma,
                        rows.cursor,
                        count,
                    );
                    rows.cursor += count;
                    remaining -= count;
                    if (rows.cursor == layer.values.len) {
                        rows.phase = if (background) .foreground else if (rows.identity) .emit else .compose;
                        rows.cursor = 0;
                        layer.start(self.source_area.x);
                    }
                },
                .compose => {
                    const count = @min(remaining, rows.rgb.len - rows.cursor);
                    self.composeRow(rows, rows.cursor, rows.rgb[rows.cursor..][0..count]);
                    remaining -= count;
                    rows.cursor += count;
                    if (rows.cursor == rows.rgb.len) {
                        rows.phase = .horizontal;
                        rows.cursor = 0;
                    }
                },
                .horizontal => {
                    remaining -= rows.filterHorizontal(@intCast(self.transform.base_width), remaining);
                    if (rows.cursor == rows.horizontal.len) {
                        rows.cursor = 0;
                        rows.cached_y = rows.source_y;
                        rows.phase = .accumulate;
                    }
                },
                .accumulate => {
                    const count = @min(remaining, rows.sums.len - rows.cursor);
                    for (rows.sums[rows.cursor..][0..count], rows.horizontal[rows.cursor..][0..count]) |*sums, rgb| {
                        for (sums, rgb) |*sum, c| {
                            const value = @as(u64, c) * rows.weight_y;
                            sum.* = if (rows.source_row_index == 0) value else sum.* + value;
                        }
                    }
                    rows.cursor += count;
                    remaining -= count;
                    if (rows.cursor == rows.sums.len) {
                        rows.source_row_index += 1;
                        const axis = geometry_module.Axis.init(rows.area.y + rows.output_y, self.info.height, self.transform.base_height);
                        rows.phase = if (rows.source_row_index == axis.count) .emit else .begin;
                        rows.cursor = 0;
                    }
                },
                .emit => {
                    const count = @min(remaining, rows.area.width - rows.cursor);
                    if (rows.identity and self.bg_color == .sampled) {
                        self.emitColorSpan(rows, count);
                    } else {
                        const x: u32 = rows.area.x + @as(u32, @intCast(rows.cursor));
                        const y = rows.area.y + rows.output_y;
                        const row = self.transform.outputRow(x, y);
                        var destination = row.index;
                        for (rows.cursor..rows.cursor + count) |column| {
                            const offset = @as(usize, @intCast(destination)) * 4;
                            const out = self.rgba[offset..][0..4];
                            if (rows.identity) {
                                out[0..3].* = self.rowPixel(rows, column);
                            } else {
                                for (out[0..3], rows.sums[column]) |*c, sum|
                                    c.* = @intCast((sum + rows.total_weight / 2) / rows.total_weight);
                            }
                            out[3] = 255;
                            destination += row.stride;
                        }
                    }
                    self.output_pixel += count;
                    remaining -= count;
                    rows.cursor += count;
                    if (rows.cursor == rows.area.width) {
                        rows.output_y += 1;
                        rows.source_row_index = 0;
                        rows.phase = .begin;
                    }
                },
            }
        }
    }

    // Keep the fixed scratch block in the grouped full-size path. Direct and
    // filtered output need neither this storage nor a per-pixel path selection.
    noinline fn emitColorSpan(self: *Renderer, rows: *row_filter.Rows, count: usize) void {
        var pixels: [64][3]u8 = undefined;
        const x: u32 = rows.area.x + @as(u32, @intCast(rows.cursor));
        const row = self.transform.outputRow(x, rows.area.y + rows.output_y);
        var destination = row.index;
        var offset: usize = 0;
        while (offset != count) {
            const n = @min(count - offset, pixels.len);
            self.composeRow(rows, rows.cursor + offset, pixels[0..n]);
            for (pixels[0..n]) |rgb| {
                const out = self.rgba[@as(usize, @intCast(destination)) * 4 ..][0..4];
                out[0..3].* = rgb;
                out[3] = 255;
                destination += row.stride;
            }
            offset += n;
        }
    }

    // Share source-color traversal between filtered rows and bounded full-size
    // output blocks; rotation affects only the later destination writes.
    // first is relative to source_area.x; sampled-layer cursors already select
    // that column. The one-quarter cutoffs below choose only the work strategy.
    fn composeRow(self: *const Renderer, rows: *row_filter.Rows, first: usize, pixels: [][3]u8) void {
        if (self.bg_color == .sampled and self.fg_color != .sampled) {
            self.composeMaskedSpan(rows, first, pixels);
        } else if (self.bg_color == .sampled and self.fg_color == .sampled) {
            self.composeLayerRuns(rows, first, pixels);
        } else {
            for (pixels, first..) |*out, column| out.* = self.rowPixel(rows, column);
        }
    }

    /// Both layers vary. Reuse interpolation along runs selecting one layer and
    /// advance the hidden layer without sampling it. Fragmented groups retain
    /// direct selection to avoid setting up an interpolator for every bit.
    fn composeLayerRuns(self: *const Renderer, rows: *row_filter.Rows, first: usize, pixels: [][3]u8) void {
        const row_start = @as(usize, rows.source_y) * self.info.width + self.source_area.x;
        var cursor = first;
        const end = first + pixels.len;
        while (cursor != end) {
            const n = @min(64, end - cursor);
            var bits = mask_filter.readBits(self.mask, row_start + cursor, @intCast(n));
            // A transition estimate includes the final ink-to-padding edge;
            // that can only choose the direct loop slightly earlier.
            if (@popCount(bits ^ (bits >> 1)) > n / 4) {
                for (pixels[cursor - first ..][0..n]) |*out| {
                    out.* = if (bits & 1 != 0) rows.fg.pixel() else rows.bg.pixel();
                    rows.bg.advance();
                    rows.fg.advance();
                    bits >>= 1;
                }
                cursor += n;
                continue;
            }
            var offset: usize = 0;
            while (offset != n) {
                const ink = bits & 1 != 0;
                const run = @min(n - offset, @ctz(if (ink) ~bits else bits));
                const out = pixels[cursor - first + offset ..][0..run];
                if (ink) {
                    rows.fg.fill(out);
                    rows.bg.skip(@intCast(run));
                } else {
                    rows.bg.fill(out);
                    rows.fg.skip(@intCast(run));
                }
                offset += run;
                if (offset != n) bits >>= @intCast(run);
            }
            cursor += n;
        }
    }

    /// The background varies; foreground colors are constant or palette-based.
    /// Decide from a packed group before entering its pixel loop. Sparse groups
    /// share background interpolation; dense groups avoid sampling covered paper.
    fn composeMaskedSpan(self: *const Renderer, rows: *row_filter.Rows, first: usize, pixels: [][3]u8) void {
        const row_start = @as(usize, rows.source_y) * self.info.width + self.source_area.x;
        var cursor = first;
        const end = first + pixels.len;
        while (cursor != end) {
            const n = @min(64, end - cursor);
            const word = mask_filter.readBits(self.mask, row_start + cursor, @intCast(n));
            const ink = @popCount(word);
            const output = pixels[cursor - first ..][0..n];
            if (ink == n) {
                switch (self.fg_color) {
                    .solid => |rgb| @memset(output, rgb),
                    .palette => for (output, cursor..) |*out, column| {
                        out.* = self.palettePixel(self.source_area.x + @as(u32, @intCast(column)), rows.source_y);
                    },
                    else => unreachable,
                }
                rows.bg.skip(@intCast(n));
            } else if (ink <= n / 4) {
                rows.bg.fill(output);
                var bits = word;
                while (bits != 0) {
                    const offset = cursor + @ctz(bits);
                    pixels[offset - first] = switch (self.fg_color) {
                        .solid => |rgb| rgb,
                        .palette => self.palettePixel(self.source_area.x + @as(u32, @intCast(offset)), rows.source_y),
                        else => unreachable,
                    };
                    bits &= bits - 1;
                }
            } else {
                var bits = word;
                for (output, cursor..) |*out, column| {
                    out.* = if (bits & 1 == 0) rows.bg.pixel() else switch (self.fg_color) {
                        .solid => |rgb| rgb,
                        .palette => self.palettePixel(self.source_area.x + @as(u32, @intCast(column)), rows.source_y),
                        else => unreachable,
                    };
                    rows.bg.advance();
                    bits >>= 1;
                }
            }
            cursor += n;
        }
    }

    inline fn rowPixel(self: *const Renderer, rows: *row_filter.Rows, column: usize) [3]u8 {
        const x = self.source_area.x + @as(u32, @intCast(column));
        const out = if (self.read(x, rows.source_y) != 0) switch (self.fg_color) {
            .solid => |rgb| rgb,
            .sampled => rows.fg.pixel(),
            .palette => self.palettePixel(x, rows.source_y),
            .checking => unreachable,
        } else switch (self.bg_color) {
            .solid => |rgb| rgb,
            .sampled => rows.bg.pixel(),
            else => unreachable,
        };
        // Both interpolation cursors follow source x, including masked-out
        // samples; the next pixel may select the other layer.
        rows.bg.advance();
        rows.fg.advance();
        return out;
    }

    fn general(self: *Renderer, work: usize, comptime regional: bool) void {
        // These paths also handle compact preview cells, enlargement, integer
        // subsampling and narrow regions excluded from the exact row plan.
        // Specialize both cache checks and raster addressing: ordinary full
        // layers keep direct reads without regional metadata in their hot loops.
        var remaining = work;
        const total = self.rgba.len / 4;
        if (self.reduced) {
            // An exact background (including JPEG) still needs per-pixel
            // interpolation. Share its row setup just as in ordinary sizing.
            if (self.bg_color == .sampled and self.bg_color.sampled.sample_step == 0 and
                self.transform.base_width <= self.info.width and self.transform.base_height <= self.info.height)
            {
                while (remaining != 0 and self.output_pixel != total) {
                    const used = self.mixedRow(remaining, regional, true);
                    if (used == 0) return;
                    remaining -= used;
                }
                return;
            }
            if (self.mask.len == 0 and self.bg_color == .sampled and self.bg_color.sampled.sample_step != 0 and
                self.transform.base_width <= self.info.width and self.transform.base_height <= self.info.height)
            {
                while (remaining != 0 and self.output_pixel != total) : (remaining -= 1) {
                    if (!self.reducedCell(regional)) return;
                }
                return;
            }
            if (self.fg_color == .sampled and self.fg_color.sampled.sample_step == 0 and
                self.transform.base_width <= self.info.width and self.transform.base_height <= self.info.height)
            {
                while (remaining != 0 and self.output_pixel != total) {
                    const used = self.mixedRow(remaining, regional, false);
                    if (used == 0) return;
                    remaining -= used;
                }
                return;
            }
            while (remaining != 0 and self.output_pixel != total) : (remaining -= 1) {
                if (!self.reducedRun(regional)) return;
            }
            return;
        }
        if (self.options.size != null) {
            if (self.transform.base_width <= self.info.width / 3) {
                while (remaining != 0 and self.output_pixel != total) {
                    const used = self.sizedRow(remaining, regional);
                    if (used == 0) return;
                    remaining -= used;
                }
            } else {
                while (remaining != 0 and self.output_pixel != total) : (remaining -= 1) {
                    if (!self.sizedPixel(regional)) return;
                }
            }
        } else {
            const ss: u32 = self.options.subsample;
            const area = ss * ss;
            while (remaining != 0 and self.output_pixel != total) : (remaining -= 1) {
                const source = self.transform.sample(
                    @intCast(self.output_pixel % self.geometry.width),
                    @intCast(self.output_pixel / self.geometry.width),
                    self.sample,
                );
                if (regional and !self.prepare(source[0], source[1], 1)) return;
                const rgb = self.pixel(source[0], source[1], regional);
                for (&self.sum, rgb) |*sum, value| sum.* += value;
                self.sample += 1;
                if (self.sample == area) {
                    const out = self.rgba[self.output_pixel * 4 ..][0..4];
                    for (out[0..3], self.sum) |*value, sum| value.* = @intCast((sum + area / 2) / area);
                    out[3] = 255;
                    self.output_pixel += 1;
                    self.sample = 0;
                    self.sum = .{0} ** 3;
                }
            }
        }
    }

    fn prepare(self: *Renderer, x: i64, y: i64, count: u32) bool {
        // Usually an entire output pixel's sampling window fits the strip.
        // Validate it once, keeping the inner source-sample loops cheap. A huge
        // window (including a 1x1 preview) instead advances one source row at a time.
        if (self.prepared_pixel == self.output_pixel) return true;
        const window = self.transform.sampleRegion(
            self.info,
            self.options.size != null,
            @intCast(self.output_pixel % self.geometry.width),
            @intCast(self.output_pixel / self.geometry.width),
        );
        if (self.hasSamples(window)) {
            self.prepared_pixel = self.output_pixel;
            self.needed = null;
            return true;
        }
        const left = std.math.clamp(x, 0, self.info.width - 1);
        const right = std.math.clamp(x + count - 1, 0, self.info.width - 1);
        const source: Region = .{
            .x = @intCast(left),
            .y = @intCast(std.math.clamp(y, 0, self.info.height - 1)),
            .width = @intCast(right - left + 1),
            .height = 1,
        };
        self.needed = if (self.hasSamples(source)) null else source;
        return self.needed == null;
    }

    fn hasSamples(self: *const Renderer, source: Region) bool {
        const layers = [_]?*const Pixmap{ self.layers.background, self.layers.foreground };
        for (layers, [_]u32{ self.bg_reduction, self.fg_reduction }) |layer, reduction| {
            if (layer) |image| {
                if (image.region != null and !image.contains(layerRegion(self.info, image, reduction, source))) {
                    return false;
                }
            }
        }
        return true;
    }

    // Called for every source sample; keep the lookup inside the sampling loops.
    inline fn sampleWindow(self: *Renderer) geometry_module.Window {
        if (self.window == null) {
            self.window = self.transform.window(
                self.info,
                @intCast(self.output_pixel % self.geometry.width),
                @intCast(self.output_pixel / self.geometry.width),
            );
        }
        return self.window.?;
    }

    fn solidPixel(self: *Renderer) void {
        if (self.options.size == null) {
            const ss: u32 = self.options.subsample;
            const source = self.transform.sample(
                @intCast(self.output_pixel % self.geometry.width),
                @intCast(self.output_pixel / self.geometry.width),
                self.sample,
            );
            const count = @min(64, ss - self.sample % ss);
            self.ink += self.countInk(source[0], source[1], count);
            self.sample += count;
            if (self.sample == ss * ss) self.finishSolid(ss * ss);
            return;
        }
        const window = self.sampleWindow();
        const x = self.sample % window.x.count;
        const y = self.sample / window.x.count;
        var count: u32 = 1;
        var weight = window.x.weight(x);
        // Only interior shrink samples have equal weights. Fractional edges and
        // the two clamped enlargement samples keep their individual weights.
        if (window.x.output <= window.x.source and x > 0 and x + 1 < window.x.count) {
            count = @min(64, window.x.count - 1 - x);
            weight = window.x.output;
        }
        // This row segment's covered weight cannot exceed the axis total.
        const ink = self.countInk(window.x.coordinate(x), window.y.coordinate(y), count);
        const horizontal: u32 = @intCast(@as(u64, ink) * weight);
        self.ink += @as(u64, horizontal) * window.y.weight(y);
        self.sample += count;
        if (self.sample == @as(u64, window.x.count) * window.y.count) self.finishSolid(window.total());
    }

    fn solidSpan(self: *Renderer) void {
        const x: u32 = @intCast(self.output_pixel % self.geometry.width);
        const y: u32 = @intCast(self.output_pixel / self.geometry.width);
        const count = @min(64, self.geometry.width - x);
        const source = self.transform.sample(x, y, 0);
        // At scale 1 the validated output rectangle has no padding. Rotation
        // changes the bit stride, but all samples stay within the source page.
        var bit = source[1] * self.info.width + source[0];
        const stride: i64 = switch (self.geometry.rotation) {
            0 => 1,
            1 => self.info.width,
            2 => -1,
            3 => -@as(i64, self.info.width),
        };
        for (0..count) |i| {
            const index: usize = @intCast(bit);
            const ink = self.mask.len != 0 and ((self.mask[index / 8] >> @as(u3, @intCast(index % 8))) & 1) != 0;
            const rgb = if (ink) self.fg_color.solid else self.bg_color.solid;
            self.rgba[(self.output_pixel + i) * 4 ..][0..4].* = .{ rgb[0], rgb[1], rgb[2], 255 };
            bit += stride;
        }
        self.output_pixel += count;
    }

    fn finishSolid(self: *Renderer, total: geometry_module.Coverage) void {
        // Narrow completed coverage once, before multiplying by channel values.
        const ink: geometry_module.Coverage = @intCast(self.ink);
        const bg = self.bg_color.solid;
        const fg = self.fg_color.solid;
        const out = self.rgba[self.output_pixel * 4 ..][0..4];
        if (ink == 0 or ink == total) {
            out[0..3].* = if (ink == 0) bg else fg;
        } else if (self.plan == .bilevel and self.options.size == null) {
            // Integer bilevel reduction rounds ink, then inverts it.
            @memset(out[0..3], @intCast(255 - (@as(u64, ink) * 255 + total / 2) / total));
        } else {
            const uncovered = total - ink;
            for (out[0..3], bg, fg) |*value, b, f| {
                value.* = @intCast((@as(u64, uncovered) * b + @as(u64, ink) * f + total / 2) / total);
            }
        }
        out[3] = 255;
        self.output_pixel += 1;
        self.sample = 0;
        self.ink = 0;
        self.window = null;
    }

    // Keep the scalar fallback inside its loops, including one-unit row tails.
    inline fn sizedPixel(self: *Renderer, comptime regional: bool) bool {
        const window = self.sampleWindow();
        const x = self.sample % window.x.count;
        const y = self.sample / window.x.count;
        const weight = window.weight(x, y);
        if (regional and !self.prepare(window.x.coordinate(x), window.y.coordinate(y), 1)) return false;
        const rgb = self.pixel(window.x.coordinate(x), window.y.coordinate(y), regional);
        for (&self.weighted, rgb) |*sum, value| sum.* += @as(u64, weight) * value;
        self.sample += 1;
        self.finishSized(window);
        return true;
    }

    inline fn finishSized(self: *Renderer, window: geometry_module.Window) void {
        if (self.sample == @as(u64, window.x.count) * window.y.count) {
            const total = window.total();
            const out = self.rgba[self.output_pixel * 4 ..][0..4];
            for (out[0..3], self.weighted) |*value, sum| value.* = @intCast((sum + total / 2) / total);
            out[3] = 255;
            self.output_pixel += 1;
            self.sample = 0;
            self.window = null;
            self.weighted = .{0} ** 3;
        }
    }

    fn sizedRow(self: *Renderer, work: usize, comptime regional: bool) usize {
        const window = self.sampleWindow();
        const x = self.sample % window.x.count;
        const y = self.sample / window.x.count;
        const count: u32 = @intCast(@min(work, window.x.count - x));
        if (count == 1) {
            return if (self.sizedPixel(regional)) 1 else 0;
        }
        const sx = window.x.coordinate(x);
        const sy = window.y.coordinate(y);
        const wy = window.y.weight(y);
        if (regional and !self.prepare(sx, sy, count)) return 0;
        var samples = self.span(sx, sy, regional);
        for (0..count) |i| {
            const rgb = self.spanPixel(&samples, sx + @as(i64, @intCast(i)), sy);
            const wx = window.x.weight(x + @as(u32, @intCast(i)));
            const weight: geometry_module.Coverage = @intCast(@as(u64, wx) * wy);
            for (&self.weighted, rgb) |*sum, value| sum.* += @as(u64, weight) * value;
        }
        self.sample += count;
        self.finishSized(window);
        return count;
    }

    pub fn hasReduced(layers: Layers) bool {
        return (if (layers.background) |bg| bg.sample_step != 0 else false) or
            (if (layers.foreground) |fg| fg.sample_step != 0 else false);
    }

    fn previewColor(self: *const Renderer, layer: LayerColor, reduction: u32, x: i64, y: i64, comptime regional: bool) [3]u8 {
        return switch (layer) {
            .solid => |rgb| rgb,
            .palette => self.palettePixel(x, y),
            .sampled => |image| if (image.sample_step == 0)
                self.sampleLayer(image, reduction, x, y, regional)
            else blk: {
                const px: u32 = @intCast(std.math.clamp(x, 0, self.info.width - 1));
                const py: u32 = @intCast(self.info.height - 1 - std.math.clamp(y, 0, self.info.height - 1));
                break :blk self.layerPixel(image, px / image.sample_step, py / image.sample_step, regional);
            },
            .checking => unreachable,
        };
    }

    fn constantRun(layer: LayerColor, x: i64) u32 {
        return switch (layer) {
            .solid => 64,
            .sampled => |image| if (image.sample_step == 0) 1 else image.sample_step - @as(u32, @intCast(x)) % image.sample_step,
            .palette => 1,
            .checking => unreachable,
        };
    }

    fn cellWeight(axis: geometry_module.Axis, first: i64, end: i64) u32 {
        const lo: u32 = @intCast(@max(first, axis.first) - axis.first);
        const hi: u32 = @intCast(@min(end, axis.first + axis.count) - axis.first);
        if (axis.count == 1) return axis.total;
        var weight = (hi - lo) * axis.output;
        if (lo == 0) weight -= axis.output - axis.first_weight;
        if (hi == axis.count) weight -= axis.output - axis.last_weight;
        return weight;
    }

    /// With no mask, visit one compact cell rather than its covered page rows.
    /// Intersect it with the original area window, including partial INFO cells.
    fn reducedCell(self: *Renderer, comptime regional: bool) bool {
        const window = self.sampleWindow();
        const image = self.bg_color.sampled;
        const s = image.sample_step;
        const left: u32 = @intCast(@divFloor(window.x.first, s));
        const top: u32 = @intCast(@divFloor(self.info.height - 1 - window.y.first, s));
        const columns: u32 = @intCast(@divFloor(window.x.first + window.x.count - 1, s) + 1 - left);
        const rows: u32 = @intCast(top + 1 - @divFloor(self.info.height - window.y.first - window.y.count, s));
        const cx = left + self.sample % columns;
        const cy = top - self.sample / columns;
        const sx = cx * s;
        const sy = @as(i64, self.info.height) - (cy + 1) * s;
        if (regional and !self.prepare(sx, sy, 1)) return false;
        const rgb = self.layerPixel(image, cx, cy, regional);
        const weight = @as(u64, cellWeight(window.x, sx, sx + s)) * cellWeight(window.y, sy, sy + s);
        for (&self.weighted, rgb) |*sum, value| sum.* += weight * value;
        self.sample += 1;
        if (self.sample == columns * rows) {
            self.sample = window.x.count * window.y.count;
            self.finishSized(window);
        }
        return true;
    }

    /// Average colors over the original page geometry, retaining every mask
    /// pixel and palette assignment. Only interior samples with identical layer
    /// colors and area weights are grouped; fractional edges remain individual.
    /// A work unit reads at most 64 mask bits, so cancellation stays bounded.
    fn reducedRun(self: *Renderer, comptime regional: bool) bool {
        const window = self.sampleWindow();
        const x = self.sample % window.x.count;
        const y = self.sample / window.x.count;
        const sx = window.x.coordinate(x);
        const sy = window.y.coordinate(y);
        var count: u32 = 1;
        if (window.x.output <= window.x.source and x > 0 and x + 1 < window.x.count) {
            count = @min(64, window.x.count - 1 - x);
            count = @min(count, constantRun(self.bg_color, sx));
        }
        var ink = self.countInk(sx, sy, count);
        // Compact foreground cells bound the run. Palettes instead accumulate
        // individual ink colors inside the background run, skipping paper.
        if (ink != 0 and self.fg_color != .palette) {
            const foreground_count = @min(count, constantRun(self.fg_color, sx));
            if (foreground_count != count) {
                count = foreground_count;
                ink = self.countInk(sx, sy, count);
            }
        }
        if (regional and !self.prepare(sx, sy, count)) return false;
        const bg = if (ink != count) self.previewColor(self.bg_color, self.bg_reduction, sx, sy, regional) else .{0} ** 3;
        var fg_sum: [3]u32 = .{0} ** 3;
        if (ink != 0) {
            if (self.fg_color == .palette and count > 1) {
                for (0..count) |i| {
                    const px = sx + @as(i64, @intCast(i));
                    if (self.read(px, sy) != 0) {
                        const rgb = self.palettePixel(px, sy);
                        for (&fg_sum, rgb) |*sum, value| sum.* += value;
                    }
                }
            } else {
                const fg = self.previewColor(self.fg_color, self.fg_reduction, sx, sy, regional);
                for (&fg_sum, fg) |*sum, value| sum.* = ink * value;
            }
        }
        const weight = window.weight(x, y);
        for (&self.weighted, bg, fg_sum) |*sum, b, f| {
            sum.* += @as(u64, weight) * ((count - ink) * b + f);
        }
        self.sample += count;
        self.finishSized(window);
        return true;
    }

    /// Exactly one layer needs bilinear interpolation. Reuse its rows across a
    /// source span; the other supplies compact cells or a constant/palette color.
    fn mixedRow(self: *Renderer, work: usize, comptime regional: bool, comptime exact_background: bool) usize {
        const window = self.sampleWindow();
        const x = self.sample % window.x.count;
        const y = self.sample / window.x.count;
        const count: u32 = @intCast(@min(work, 64, window.x.count - x));
        if (count == 1) return if (self.reducedRun(regional)) 1 else 0;
        const sx = window.x.coordinate(x);
        const sy = window.y.coordinate(y);
        if (regional and !self.prepare(sx, sy, count)) return 0;
        const layer = if (exact_background) self.bg_color.sampled else self.fg_color.sampled;
        const reduction = if (exact_background) self.bg_reduction else self.fg_reduction;
        const other = if (exact_background) self.fg_color else self.bg_color;
        const other_reduction = if (exact_background) self.fg_reduction else self.bg_reduction;
        var exact = LayerSpan.init(self.info, layer, reduction, sx, sy, regional);
        for (0..count) |i| {
            const px = sx + @as(i64, @intCast(i));
            const ink = self.read(px, sy) != 0;
            const rgb = if (ink != exact_background)
                exact.pixel(&self.gamma)
            else
                self.previewColor(other, other_reduction, px, sy, regional);
            const weight = window.weight(x + @as(u32, @intCast(i)), y);
            for (&self.weighted, rgb) |*sum, value| sum.* += @as(u64, weight) * value;
            exact.advance();
        }
        self.sample += count;
        self.finishSized(window);
        return count;
    }
};
