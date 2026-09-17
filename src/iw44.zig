//! Progressive IW44 decoding and resumable regional reconstruction.
const std = @import("std");
const types = @import("types.zig");
const Error = types.Error;
const Allocator = std.mem.Allocator;
const Reader = @import("iff.zig").Reader;
const Zp = @import("zp.zig").Decoder;
const Pixmap = @import("pixmap.zig").Pixmap;
const Region = @import("geometry.zig").Region;

const quant = [16]i32{
    0x4000,  0x8000,  0x8000,  0x10000,
    0x10000, 0x10000, 0x20000, 0x20000,
    0x20000, 0x40000, 0x40000, 0x40000,
    0x80000, 0x40000, 0x40000, 0x80000,
};
const bands = [10]struct { first: usize, count: usize }{
    .{ .first = 0, .count = 1 },   .{ .first = 1, .count = 1 },   .{ .first = 2, .count = 1 },  .{ .first = 3, .count = 1 },
    .{ .first = 4, .count = 4 },   .{ .first = 8, .count = 4 },   .{ .first = 12, .count = 4 }, .{ .first = 16, .count = 16 },
    .{ .first = 32, .count = 16 }, .{ .first = 48, .count = 16 },
};
const locations: [1024]u16 = blk: {
    @setEvalBranchQuota(20000);
    var result: [1024]u16 = undefined;
    for (&result, 0..) |*entry, i| {
        var n = i;
        var x: u16 = 0;
        var y: u16 = 0;
        for (0..5) |_| {
            x = (x << 1) | @as(u16, @intCast(n & 1));
            n >>= 1;
            y = (y << 1) | @as(u16, @intCast(n & 1));
            n >>= 1;
        }
        entry.* = y * 32 + x;
    }
    break :blk result;
};

pub const Header = struct {
    width: u32,
    height: u32,
    color: bool,
    half_chroma: bool,
    delay: u8,
    size: usize,

    pub fn parse(bytes: []const u8) Error!Header {
        var r: Reader = .{ .bytes = bytes };
        if (try r.byte() != 0) return error.InvalidData;
        _ = try r.byte();
        const major = try r.byte();
        const minor = try r.byte();
        if (major & 0x7f != 1 or minor > 2) return error.Unsupported;
        const width = try r.uint(2);
        const height = try r.uint(2);
        if (width == 0 or height == 0) return error.InvalidData;
        const chroma = if (minor >= 2) try r.byte() else @as(u8, 0x80);
        return .{
            .width = width,
            .height = height,
            .color = major & 0x80 == 0,
            .half_chroma = chroma & 0x80 == 0,
            .delay = chroma & 0x7f,
            .size = r.pos,
        };
    }
};

const active = 1;
const potential = 2;
const fresh = 4;

/// Two levels of indexes address groups of 16 coefficients. An absent page or
/// bucket means zero. Pages cover eight buckets: coarse coefficients need not
/// allocate directory entries for all finer bands in the same block.
/// Both pools use one-based indexes, never pointers that could outlive growth.
const Coefficients = struct {
    const page_size = 8;

    pages: []u32 = &.{},
    slots: std.ArrayList([page_size]u32) = .empty,
    values: std.ArrayList([16]i16) = .empty,

    fn init(allocator: Allocator, count: usize) Error!Coefficients {
        // Decoder dimensions are padded to complete 32 x 32 blocks.
        std.debug.assert(count % 1024 == 0);
        const pages = try allocator.alloc(u32, count / (16 * page_size));
        @memset(pages, 0);
        return .{ .pages = pages };
    }

    fn deinit(self: *Coefficients, allocator: Allocator) void {
        allocator.free(self.pages);
        self.slots.deinit(allocator);
        self.values.deinit(allocator);
        self.* = .{};
    }

    pub fn len(self: Coefficients) usize {
        return self.pages.len * page_size * 16;
    }

    pub fn bucket(self: Coefficients, index: usize) ?*[16]i16 {
        const page = self.pages[index / page_size];
        if (page == 0) return null;
        const slot = self.slots.items[page - 1][index % page_size];
        return if (slot == 0) null else &self.values.items[slot - 1];
    }

    pub fn ensureBucket(self: *Coefficients, allocator: Allocator, index: usize) Error!*[16]i16 {
        const page = &self.pages[index / page_size];
        if (page.* == 0) {
            try reserve(allocator, &self.slots, self.pages.len);
            self.slots.appendAssumeCapacity(.{0} ** page_size);
            page.* = @intCast(self.slots.items.len);
        }
        const slot = &self.slots.items[page.* - 1][index % page_size];
        if (slot.* == 0) {
            try reserve(allocator, &self.values, self.pages.len * page_size);
            self.values.appendAssumeCapacity(.{0} ** 16);
            slot.* = @intCast(self.values.items.len);
        }
        return &self.values.items[slot.* - 1];
    }

    fn reserve(allocator: Allocator, pool: anytype, limit: usize) Error!void {
        if (pool.items.len == pool.capacity) {
            // Cap both pools at the image's possible entries on dense streams.
            const capacity = @min(limit, pool.capacity + pool.capacity / 2 + 8);
            try pool.ensureTotalCapacityPrecise(allocator, capacity);
        }
    }
};

/// Each entropy operation covers at most 256 coefficients (one block band),
/// never a whole slice.
const Plane = struct {
    coefficients: Coefficients = .{},
    steps: [16]i32 = quant,
    band: usize = 0,
    root: u8 = 0,
    bucket: [10][8]u8 = .{.{0} ** 8} ** 10,
    start: [16]u8 = .{0} ** 16,
    mantissa: u8 = 0,

    fn stepSize(self: *const Plane, coefficient: usize) i32 {
        const index = if (self.band != 0)
            self.band + 6
        else if (coefficient < 4)
            coefficient
        else
            coefficient / 4 + 3;
        return self.steps[index];
    }

    fn emptyBand(self: *const Plane) bool {
        const n: usize = if (self.band == 0) 16 else 1;
        for (0..n) |i| {
            const s = self.stepSize(i);
            if (s > 0 and s < 0x8000) return false;
        }
        return true;
    }

    fn finishBand(self: *Plane) void {
        if (self.band == 0) {
            for (self.steps[0..7]) |*s| s.* >>= 1;
        } else self.steps[self.band + 6] >>= 1;
        self.band = (self.band + 1) % 10;
    }

    fn decodeBlock(self: *Plane, allocator: Allocator, zp: *Zp, block: usize) Error!void {
        const range = bands[self.band];
        const base = block * 64;
        var states: [256]u8 = undefined;
        var buckets: [16]u8 = .{0} ** 16;
        var combined: u8 = 0;
        for (0..range.count) |b| {
            const values = self.coefficients.bucket(base + range.first + b);
            for (0..16) |i| {
                const s = self.stepSize(b * 16 + i);
                const value = if (values) |v| v[i] else 0;
                const state: u8 = if (s == 0 or s >= 0x8000) 0 else if (value != 0) active else potential;
                states[b * 16 + i] = state;
                buckets[b] |= state;
                combined |= state;
            }
        }
        const visit = range.count < 16 or combined & active != 0 or
            (combined & potential != 0 and try zp.bit(&self.root) != 0);
        if (visit) {
            for (buckets[0..range.count], 0..) |*state, b| {
                if (state.* & potential == 0) continue;
                var context: usize = 0;
                if (self.band != 0) {
                    const parent = (range.first + b) * 4;
                    if (self.coefficients.bucket(base + parent / 16)) |values| {
                        for (values[parent % 16 ..][0..4]) |value| {
                            if (value != 0) context += 1;
                        }
                    }
                    context = @min(context, 3);
                }
                if (combined & active != 0) context |= 4;
                if (try zp.bit(&self.bucket[self.band][context]) != 0) state.* |= fresh;
            }
            for (buckets[0..range.count], 0..) |state, b| {
                if (state & fresh == 0) continue;
                var values = self.coefficients.bucket(base + range.first + b);
                var remaining: usize = 0;
                for (states[b * 16 ..][0..16]) |s| {
                    if (s & potential != 0) remaining += 1;
                }
                for (0..16) |i| {
                    const index = b * 16 + i;
                    if (states[index] & potential == 0) continue;
                    var context: usize = @min(remaining, 7);
                    if (state & active != 0) context |= 8;
                    if (try zp.bit(&self.start[context]) != 0) {
                        const s = self.stepSize(index);
                        const half = s >> 1;
                        const value = s + half - (half >> 2);
                        const decoded = try narrow(if (try zp.wavelet() != 0) -value else value);
                        if (values == null) {
                            values = try self.coefficients.ensureBucket(allocator, base + range.first + b);
                        }
                        values.?[i] = decoded;
                        remaining = 0;
                    } else if (remaining != 0) remaining -= 1;
                }
            }
        }
        if (combined & active != 0) {
            for (buckets[0..range.count], 0..) |bucket_state, b| {
                if (bucket_state & active == 0) continue;
                const values = self.coefficients.bucket(base + range.first + b).?;
                for (states[b * 16 ..][0..16], values, 0..) |state, *ptr, i| {
                    if (state & active == 0) continue;
                    var value: i32 = @intCast(@abs(@as(i32, ptr.*)));
                    const s = self.stepSize(b * 16 + i);
                    const decision = if (value <= 3 * s) blk: {
                        value += s >> 2;
                        break :blk try zp.bit(&self.mantissa);
                    } else try zp.wavelet();
                    value += (s >> 1) - (if (decision == 0) s else @as(i32, 0));
                    ptr.* = try narrow(if (ptr.* < 0) -value else value);
                }
            }
        }
    }
};

fn narrow(value: i32) Error!i16 {
    return std.math.cast(i16, value) orelse error.InvalidData;
}

const Phase = enum { header, entropy, scatter, filter, extract, color, done };

pub const Decoder = struct {
    allocator: Allocator,
    chunks: []const []const u8,
    limits: types.Limits,
    header: Header,
    stride: u32,
    padded_height: u32,
    /// Keep entropy results for repeated regional reconstruction. Set before step.
    retain_coefficients: bool = false,
    /// Power-of-two spacing of reconstructed samples in the original layer.
    reduction: u32 = 1,
    /// Reconstruction bounds on the selected bottom-left sample grid.
    area: Region,
    planes: [3]Plane = .{Plane{}} ** 3,
    phase: Phase = .header,
    chunk: usize = 0,
    slices: usize = 0,
    remaining: u8 = 0,
    channel: usize = 0,
    block: usize = 0,
    zp: ?Zp = null,
    scratch: []i16 = &.{},
    image: ?Pixmap = null,
    position: usize = 0,
    scale: u32 = 16,
    horizontal: bool = false,
    odd: bool = false,
    filter_x: u32 = 0,
    filter_y: u32 = 0,
    odd_neighbors: [4]i32 = .{0} ** 4,
    even_neighbors: [4]i32 = .{0} ** 4,

    pub fn init(allocator: Allocator, chunks: []const []const u8, limits: types.Limits) Error!Decoder {
        if (chunks.len == 0) return error.InvalidArgument;
        if (chunks.len > 256) return error.LimitExceeded;
        const header = try Header.parse(chunks[0]);
        const stride = (header.width + 31) & ~@as(u32, 31);
        const height = (header.height + 31) & ~@as(u32, 31);
        const pixels = std.math.mul(usize, stride, height) catch return error.LimitExceeded;
        if (pixels > limits.max_page_pixels) return error.LimitExceeded;
        return .{
            .allocator = allocator,
            .chunks = chunks,
            .limits = limits,
            .header = header,
            .stride = stride,
            .padded_height = height,
            .area = .{ .x = 0, .y = 0, .width = header.width, .height = header.height },
        };
    }

    pub fn deinit(self: *Decoder) void {
        for (&self.planes) |*plane| plane.coefficients.deinit(self.allocator);
        self.allocator.free(self.scratch);
        if (self.image) |*image| image.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn takeImage(self: *Decoder) Pixmap {
        std.debug.assert(self.phase == .done and !self.retain_coefficients);
        const image = self.image.?;
        self.image = null;
        return image;
    }

    fn planeCount(self: *const Decoder) usize {
        return if (self.header.color) 3 else 1;
    }

    fn startChunk(self: *Decoder) Error!void {
        if (self.chunk == self.chunks.len) {
            if (self.retain_coefficients) {
                self.image = .{
                    .width = self.header.width,
                    .height = self.header.height,
                    .pixels = &.{},
                    .region = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                };
                self.phase = .done;
            } else try self.beginReconstruction(1, .{
                .x = 0,
                .y = 0,
                .width = self.header.width,
                .height = self.header.height,
            });
            return;
        }
        const bytes = self.chunks[self.chunk];
        var r: Reader = .{ .bytes = bytes };
        if (try r.byte() != self.chunk) return error.InvalidData;
        self.remaining = try r.byte();
        if (self.remaining > self.limits.max_iw_slices -| self.slices) return error.LimitExceeded;
        if (self.chunk == 0) {
            r.pos = self.header.size;
            const count = @as(usize, self.stride) * self.padded_height;
            for (self.planes[0..self.planeCount()]) |*plane| {
                plane.coefficients = try Coefficients.init(self.allocator, count);
            }
        }
        self.zp = if (self.remaining > 0) try Zp.init(bytes[r.pos..]) else null;
        self.chunk += 1;
        self.channel = 0;
        self.block = 0;
        self.phase = .entropy;
    }

    /// Reconstruct exact full-resolution samples, retaining the coefficient maps.
    /// The previous raster is borrowed and becomes invalid on a successful call.
    pub fn reconstruct(self: *Decoder, region: Region) Error!void {
        try self.reconstructReduced(1, region);
    }

    /// Reconstruct on a compact grid at reduction 1, 2, 4, 8, 16 or 32.
    /// Samples are anchored at the layer's bottom left; region coordinates use
    /// the resulting grid's top-left origin. This omits finer lifting stages,
    /// not entropy refinements, and differs from resizing full-resolution RGB.
    pub fn reconstructReduced(self: *Decoder, reduction: u32, region: Region) Error!void {
        if (!self.retain_coefficients or self.phase != .done) return error.Busy;
        switch (reduction) {
            1, 2, 4, 8, 16, 32 => {},
            else => return error.InvalidArgument,
        }
        const width = (self.header.width + reduction - 1) / reduction;
        const height = (self.header.height + reduction - 1) / reduction;
        if (region.width == 0 or region.height == 0 or
            region.x >= width or region.y >= height or
            region.width > width - region.x or region.height > height - region.y)
        {
            return error.InvalidArgument;
        }
        try self.beginReconstruction(reduction, region);
    }

    fn beginReconstruction(self: *Decoder, reduction: u32, region: Region) Error!void {
        // Each lifting level reaches six samples, including the even samples
        // needed by the odd update. For block side b, the remaining levels reach
        // 6*(b/2+...+1)=6*(b-1); round this halo to whole blocks.
        const side = 32 / reduction;
        const mask = side - 1;
        const halo = (6 * mask + mask) & ~mask;
        const width = (self.header.width + reduction - 1) / reduction;
        const height = (self.header.height + reduction - 1) / reduction;
        const left = (region.x -| halo) & ~mask;
        const bottom = (height - region.y - region.height -| halo) & ~mask;
        const right = @min(width, (region.x + region.width + halo + mask) & ~mask);
        const top = @min(height, (height - region.y + halo + mask) & ~mask);
        const count = @as(usize, region.width) * region.height;
        if (self.image) |*image| {
            if (image.pixels.len < count) image.pixels = try self.allocator.realloc(image.pixels, count);
            image.width = width;
            image.height = height;
            image.region = region;
        } else {
            self.image = .{
                .width = width,
                .height = height,
                .pixels = try self.allocator.alloc([3]u8, count),
                .region = if (self.retain_coefficients) region else null,
            };
        }
        self.reduction = reduction;
        self.area = .{ .x = left, .y = bottom, .width = right - left, .height = top - bottom };
        self.stride = (self.area.width + mask) & ~mask;
        self.position = 0;
        self.channel = 0;
        self.phase = .scatter;
    }

    fn entropy(self: *Decoder) Error!void {
        if (self.remaining == 0) {
            self.phase = .header;
            return;
        }
        const plane = &self.planes[self.channel];
        if (!plane.emptyBand()) {
            try plane.decodeBlock(self.allocator, &self.zp.?, self.block);
            self.block += 1;
            if (self.block < plane.coefficients.len() / 1024) return;
        }
        plane.finishBand();
        self.block = 0;
        self.channel += 1;
        const channels = if (self.slices >= self.header.delay) self.planeCount() else 1;
        if (self.channel == channels) {
            self.channel = 0;
            self.slices += 1;
            self.remaining -= 1;
        }
    }

    fn scatter(self: *Decoder, comptime reduced: bool) Error!usize {
        const plane = &self.planes[self.channel];
        const reduction: u32 = if (reduced) self.reduction else 1;
        const side: u32 = 32 / reduction;
        const per_block = side * side;
        const count = if (self.retain_coefficients)
            @as(usize, self.stride) * ((self.area.height + side - 1) & ~(side - 1))
        else
            plane.coefficients.len();
        if (self.scratch.len < count) self.scratch = try self.allocator.realloc(self.scratch, count);
        const i = self.position;
        const block = i / per_block;
        const bx = block % (self.stride / side) * side;
        const by = block / (self.stride / side) * side;
        const bucket = if (self.retain_coefficients) blk: {
            const source_block = (by + self.area.y) / side * ((self.header.width + 31) / 32) + (bx + self.area.x) / side;
            break :blk source_block * 64 + i % per_block / 16;
        } else i / 16;
        const values = plane.coefficients.bucket(bucket);
        // The first (32/r)^2 locations are exactly those divisible by r in
        // both coordinates. Only this prefix belongs to the compact grid.
        const done = @min(16, per_block);
        for (locations[i % per_block ..][0..done], 0..) |loc, j| {
            self.scratch[(by + loc / 32 / reduction) * self.stride + bx + loc % 32 / reduction] = if (values) |v| v[j] else 0;
        }
        self.position += done;
        if (self.position == count) {
            if (!self.retain_coefficients) plane.coefficients.deinit(self.allocator);
            self.position = 0;
            self.scale = 16 / reduction;
            self.horizontal = false;
            self.odd = false;
            self.filter_x = 0;
            self.filter_y = 0;
            self.phase = if (self.scale == 0) .extract else .filter;
        }
        return done;
    }

    fn row(self: *const Decoder, y: i64) ?[]const i16 {
        if (y < 0 or y >= self.area.height) return null;
        const start = @as(usize, @intCast(y)) * self.stride;
        return self.scratch[start..][0..self.area.width];
    }

    fn verticalFilter(self: *Decoder, work: usize) usize {
        // Columns are independent within each lifting phase. Visit neighbours
        // in storage order, retaining the even-before-odd dependency and pausing
        // within a row when the caller's remaining budget runs out.
        const p: i64 = self.filter_y;
        const s: i64 = self.scale;
        const count = @min(work, (self.area.width - self.filter_x + self.scale - 1) / self.scale);
        const before = self.row(p - s);
        const after = self.row(p + s);
        const far_before = self.row(p - 3 * s);
        const far_after = self.row(p + 3 * s);
        const start = @as(usize, self.filter_y) * self.stride;
        const current = self.scratch[start..][0..self.area.width];
        var x = self.filter_x;
        var done: usize = 0;
        if (comptime (std.simd.suggestVectorLength(i32) orelse 1) >= 4) {
            // The finest level has contiguous samples. Coarser levels, short
            // budgets and the final partial vector retain scalar access.
            if (self.scale == 1) {
                // Widen before lifting; only the final signed 16-bit stores wrap.
                const V = @Vector(4, i32);
                const nine: V = @splat(9);
                while (count - done >= 4) {
                    const left = vectorSample(before, x);
                    const right = vectorSample(after, x);
                    const outer_left = vectorSample(far_before, x);
                    const outer_right = vectorSample(far_after, x);
                    const value: V = @intCast(@as(@Vector(4, i16), current[x..][0..4].*));
                    const next = if (!self.odd)
                        value - ((nine * (left + right) - outer_left - outer_right + @as(V, @splat(16))) >> @splat(5))
                    else if (far_before != null and far_after != null)
                        value + ((nine * (left + right) - outer_left - outer_right + @as(V, @splat(8))) >> @splat(4))
                    else if (after != null)
                        value + ((left + right + @as(V, @splat(1))) >> @splat(1))
                    else
                        value + left;
                    const stored: @Vector(4, i16) = @truncate(next);
                    current[x..][0..4].* = stored;
                    x += 4;
                    done += 4;
                }
            }
        }
        for (done..count) |_| {
            const left: i32 = if (before) |r| r[x] else 0;
            const right: i32 = if (after) |r| r[x] else 0;
            const outer_left: i32 = if (far_before) |r| r[x] else 0;
            const outer_right: i32 = if (far_after) |r| r[x] else 0;
            const value: i32 = current[x];
            const next = if (!self.odd)
                value - ((9 * (left + right) - outer_left - outer_right + 16) >> 5)
            else if (far_before != null and far_after != null)
                value + ((9 * (left + right) - outer_left - outer_right + 8) >> 4)
            else if (after != null)
                value + ((left + right + 1) >> 1)
            else
                value + left;
            // Reconstruction stores signed 16-bit samples. Lifting can cross
            // that range even for an ordinary encoded image; stores wrap.
            current[x] = @truncate(next);
            x += self.scale;
        }
        self.filter_x = x;
        if (self.filter_x >= self.area.width) {
            self.filter_x = 0;
            self.filter_y += 2 * self.scale;
            if (self.filter_y >= self.area.height) {
                if (!self.odd and self.scale < self.area.height) {
                    self.odd = true;
                    self.filter_y = self.scale;
                } else {
                    self.odd = false;
                    self.filter_y = 0;
                    self.horizontal = true;
                }
            }
        }
        return count;
    }

    inline fn vectorSample(samples: ?[]const i16, x: usize) @Vector(4, i32) {
        return if (samples) |r| @intCast(@as(@Vector(4, i16), r[x..][0..4].*)) else @splat(0);
    }

    fn horizontalSample(self: *const Decoder, position: i64) i32 {
        if (position < 0 or position >= self.area.width) return 0;
        return self.scratch[@as(usize, self.filter_y) * self.stride + @as(usize, @intCast(position))];
    }

    fn horizontalFilter(self: *Decoder) void {
        // In the image's first three pairs, missing lookahead keeps its previous
        // value. Apply this at the image edge, not at a regional crop's origin,
        // so short crops use the same filter as the full image.
        const p: i64 = self.filter_x;
        const s: i64 = self.scale;
        const a = &self.odd_neighbors;
        const b = &self.even_neighbors;
        const width = self.area.width;
        if (p < width) {
            if (p == 0) {
                a[2] = self.horizontalSample(s);
                a[3] = self.horizontalSample(3 * s);
            } else {
                const lookahead = if (p + 3 * s < width)
                    self.horizontalSample(p + 3 * s)
                else if (p + self.area.x < 6 * s)
                    a[3]
                else
                    0;
                a.* = .{ a[1], a[2], a[3], lookahead };
                if (p >= 4 * s) b.* = .{ b[1], b[2], b[3], b[3] };
            }
            b[3] = self.horizontalSample(p) - ((9 * (a[1] + a[2]) - a[0] - a[3] + 16) >> 5);
            if (p == 0) b[2] = b[3];
            self.scratch[self.filter_y * self.stride + self.filter_x] = @truncate(b[3]);
            if (p >= 4 * s) {
                const index = self.filter_y * self.stride + self.filter_x - 3 * self.scale;
                const delta = if (p == 4 * s)
                    (b[1] + b[2] + 1) >> 1
                else
                    (9 * (b[1] + b[2]) - b[0] - b[3] + 8) >> 4;
                self.scratch[index] = @truncate(@as(i32, self.scratch[index]) + delta);
            }
        } else {
            b.* = .{ b[1], b[2], b[3], b[3] };
            if (p >= 3 * s and p - 3 * s < width) {
                const index = self.filter_y * self.stride + self.filter_x - 3 * self.scale;
                self.scratch[index] = @truncate(@as(i32, self.scratch[index]) + ((b[1] + b[2] + 1) >> 1));
            }
        }
        self.filter_x += 2 * self.scale;
        if (self.filter_x >= 3 * self.scale and self.filter_x - 3 * self.scale >= width) {
            self.filter_x = 0;
            self.filter_y += self.scale;
            a.* = .{0} ** 4;
            b.* = .{0} ** 4;
            if (self.filter_y >= self.area.height) {
                self.filter_y = 0;
                self.horizontal = false;
                const end: u32 = if (self.channel != 0 and self.header.half_chroma and self.reduction == 1) 2 else 1;
                if (self.scale == end) self.phase = .extract else self.scale >>= 1;
            }
        }
    }

    fn extract(self: *Decoder, work: usize) usize {
        const region = self.image.?.area();
        const x = self.position % region.width;
        const y = self.position / region.width;
        const count = @min(work, region.width - x);
        const half = self.channel != 0 and self.header.half_chroma and self.reduction == 1;
        const bottom = self.image.?.height - region.y - 1 - y;
        const sy = (if (half) bottom & ~@as(usize, 1) else bottom) - self.area.y;
        const samples = self.scratch[sy * self.stride ..][0..self.area.width];
        const pixels = self.image.?.pixels[self.position..][0..count];
        for (pixels, region.x + x..) |*pixel, px| {
            const sx = (if (half) px & ~@as(usize, 1) else px) - self.area.x;
            const sample_value: i32 = (@as(i32, samples[sx]) + 32) >> 6;
            const reduced: i8 = @intCast(std.math.clamp(sample_value, -128, 127));
            pixel[self.channel] = @bitCast(reduced);
        }
        self.position += count;
        if (self.position == @as(usize, region.width) * region.height) {
            if (!self.retain_coefficients) {
                self.allocator.free(self.scratch);
                self.scratch = &.{};
            }
            self.position = 0;
            self.channel += 1;
            self.phase = if (self.channel < self.planeCount()) .scatter else .color;
        }
        return count;
    }

    fn color(self: *Decoder, work: usize) usize {
        const region = self.image.?.area();
        const pixels = self.image.?.pixels[0 .. @as(usize, region.width) * region.height];
        const count = @min(work, pixels.len - self.position);
        const pending = pixels[self.position..][0..count];
        if (self.header.color) {
            for (pending) |*pixel| {
                const y: i32 = @as(i8, @bitCast(pixel[0]));
                const cb: i32 = @as(i8, @bitCast(pixel[1]));
                const cr: i32 = @as(i8, @bitCast(pixel[2]));
                const red = cr + (cr >> 1);
                const base = y + 128 - (cb >> 2);
                pixel.* = .{ clamp(y + 128 + red), clamp(base - (red >> 1)), clamp(base + 2 * cb) };
            }
        } else {
            for (pending) |*pixel| {
                const y: i32 = @as(i8, @bitCast(pixel[0]));
                pixel.* = .{clamp(127 - y)} ** 3;
            }
        }
        self.position += count;
        if (self.position == pixels.len) self.phase = .done;
        return count;
    }

    pub fn step(self: *Decoder, work: usize) Error!bool {
        if (work == 0) return error.InvalidArgument;
        var left = work;
        while (left > 0) {
            switch (self.phase) {
                .header => {
                    try self.startChunk();
                    left -= 1;
                },
                .entropy => {
                    try self.entropy();
                    left -|= 256;
                },
                .scatter => {
                    left -|= if (self.reduction == 1) try self.scatter(false) else try self.scatter(true);
                },
                .filter => if (self.horizontal) {
                    while (left != 0 and self.phase == .filter and self.horizontal) : (left -= 1) {
                        self.horizontalFilter();
                    }
                } else {
                    left -= self.verticalFilter(left);
                },
                .extract => {
                    left -= self.extract(left);
                },
                .color => {
                    left -= self.color(left);
                },
                .done => return true,
            }
        }
        return self.phase == .done;
    }
};

fn clamp(value: i32) u8 {
    return @intCast(std.math.clamp(value, 0, 255));
}
