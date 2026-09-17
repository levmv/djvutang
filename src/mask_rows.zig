//! Exact area coverage for a packed mask between two constant colors.
//! Scan source rows once, retaining only width-sized weights and accumulators.
const std = @import("std");
const geometry = @import("geometry.zig");
const Info = @import("iff.zig").Info;
const Column = @import("composite_rows.zig").Column;

pub const Rows = struct {
    /// Requested rectangle in unrotated output coordinates.
    area: geometry.Region,
    /// Horizontal mask support in the top-down INFO grid.
    source_x: u32,
    source_width: u32,
    /// Output columns touched by ink in the cached source row, end exclusive.
    active_first: u32 = 0,
    active_end: u32 = 0,
    /// Source offset: next left endpoint or exclusive right endpoint to scan.
    scan: u32 = 0,
    columns: []Column,
    // A horizontal coverage is at most INFO width (65535); the complete area
    // coverage is at most width * height (< 2^32). No RGB sums are needed.
    horizontal: []u16,
    /// Zeroed during column setup and after emission; blank rows add nothing.
    sums: []u32,
    phase: enum { columns, begin, scan_left, scan_right, horizontal, accumulate, emit } = .columns,
    cursor: usize = 0,
    output_y: u32 = 0,
    source_row_index: u32 = 0,
    source_y: u32 = 0,
    /// Adjacent output rows may reuse this row's coverage and active bounds.
    cached_y: ?u32 = null,
    weight_y: u32 = 0,
    /// Progress and weighted coverage within a window processed in bounded groups.
    sample: u32 = 0,
    partial: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, source: geometry.Region, transform: geometry.Transform) std.mem.Allocator.Error!Rows {
        const area = transform.unrotatedRegion();
        const columns = try allocator.alloc(Column, area.width);
        errdefer allocator.free(columns);
        const horizontal = try allocator.alloc(u16, area.width);
        errdefer allocator.free(horizontal);
        const sums = try allocator.alloc(u32, area.width);
        return .{
            .area = area,
            .source_x = source.x,
            .source_width = source.width,
            .columns = columns,
            .horizontal = horizontal,
            .sums = sums,
        };
    }

    pub fn deinit(self: *Rows, allocator: std.mem.Allocator) void {
        allocator.free(self.columns);
        allocator.free(self.horizontal);
        allocator.free(self.sums);
        self.* = undefined;
    }

    fn count(mask: []const u8, first: usize, length: u32) u32 {
        return @popCount(readBits(mask, first, length));
    }

    /// Each unit scans at most 64 mask bits or processes one output column.
    /// Return the number of emitted pixels, independent of rotated write order.
    pub noinline fn step(
        self: *Rows,
        info: Info,
        transform: geometry.Transform,
        mask: []const u8,
        bg: [3]u8,
        fg: [3]u8,
        rgba: []u8,
        work: usize,
    ) usize {
        var remaining = work;
        var emitted: usize = 0;
        while (remaining != 0 and self.output_y != self.area.height) {
            switch (self.phase) {
                .columns => {
                    const n = @min(remaining, self.columns.len - self.cursor);
                    for (self.columns[self.cursor..][0..n], self.cursor..) |*column, x| {
                        const axis = geometry.Axis.init(@intCast(x + self.area.x), info.width, transform.base_width);
                        self.sums[x] = 0;
                        column.* = .{
                            .first = @intCast(axis.first - self.source_x),
                            .count = @intCast(axis.count),
                            .first_weight = @intCast(axis.first_weight),
                            .last_weight = @intCast(axis.last_weight),
                        };
                    }
                    self.cursor += n;
                    remaining -= n;
                    if (self.cursor == self.columns.len) self.phase = .begin;
                },
                .begin => {
                    const axis = geometry.Axis.init(self.area.y + self.output_y, info.height, transform.base_height);
                    self.source_y = @intCast(axis.coordinate(self.source_row_index));
                    self.weight_y = axis.weight(self.source_row_index);
                    self.cursor = self.active_first;
                    self.scan = 0;
                    self.phase = if (self.cached_y == self.source_y) .accumulate else .scan_left;
                    remaining -= 1;
                },
                .scan_left => {
                    // Find ink only within the requested support. Page margins
                    // and blank rows need neither horizontal nor vertical sums.
                    const n = @min(64, self.source_width - self.scan);
                    const index = @as(usize, self.source_y) * info.width + self.source_x + self.scan;
                    const word = readBits(mask, index, n);
                    remaining -= 1;
                    if (word != 0) {
                        const first = self.source_x + self.scan + @as(u32, @intCast(@ctz(word)));
                        const output = @as(u64, first) * transform.base_width / info.width;
                        self.active_first = @intCast(@min(self.area.width, @max(self.area.x, output) - self.area.x));
                        self.scan = self.source_width;
                        self.phase = .scan_right;
                    } else {
                        self.scan += n;
                        if (self.scan == self.source_width) {
                            self.active_first = 0;
                            self.active_end = 0;
                            self.cursor = 0;
                            self.cached_y = self.source_y;
                            self.phase = .accumulate;
                        }
                    }
                },
                .scan_right => {
                    const n = @min(64, self.scan);
                    self.scan -= n;
                    const index = @as(usize, self.source_y) * info.width + self.source_x + self.scan;
                    const word = readBits(mask, index, n);
                    remaining -= 1;
                    if (word != 0) {
                        const end = self.source_x + self.scan + 64 - @as(u32, @intCast(@clz(word)));
                        // Map the exclusive source endpoint with ceil, keeping
                        // every output window with a nonzero intersection.
                        const output = (@as(u64, end) * transform.base_width + info.width - 1) / info.width;
                        self.active_end = @intCast(@min(self.area.width, @max(self.area.x, output) - self.area.x));
                        self.cursor = self.active_first;
                        self.phase = .horizontal;
                    }
                },
                .horizontal => {
                    // A short window is one popcount with fractional endpoint
                    // corrections. Wider windows keep bounded resumable groups.
                    if (info.width / transform.base_width + 2 <= 64) {
                        const n = @min(remaining, self.active_end - self.cursor);
                        const row_start = @as(usize, self.source_y) * info.width + self.source_x;
                        for (self.horizontal[self.cursor..][0..n], self.columns[self.cursor..][0..n]) |*value, axis| {
                            const index = row_start + axis.first;
                            const interior = transform.base_width;
                            const word = readBits(mask, index, axis.count);
                            const covered = @as(u32, @popCount(word)) * interior;
                            const first = @as(u32, @truncate(word & 1)) * (interior - axis.first_weight);
                            const last = @as(u32, @intCast(word >> @as(u6, @intCast(axis.count - 1)))) * (interior - axis.last_weight);
                            value.* = @intCast(covered - first - last);
                        }
                        self.cursor += n;
                        remaining -= n;
                        if (self.cursor == self.active_end) {
                            self.cursor = self.active_first;
                            self.cached_y = self.source_y;
                            self.phase = .accumulate;
                        }
                        continue;
                    }
                    const axis = self.columns[self.cursor];
                    const interior = self.sample != 0 and self.sample + 1 < axis.count;
                    const n: u32 = if (interior) @intCast(@min(remaining, 64, axis.count - self.sample - 1)) else 1;
                    const index = @as(usize, self.source_y) * info.width + self.source_x + axis.first + self.sample;
                    const weight = if (interior) transform.base_width else axis.weight(self.sample, transform.base_width);
                    self.partial += count(mask, index, n) * weight;
                    remaining -= 1;
                    self.sample += n;
                    if (self.sample == axis.count) {
                        self.horizontal[self.cursor] = @intCast(self.partial);
                        self.partial = 0;
                        self.sample = 0;
                        self.cursor += 1;
                        if (self.cursor == self.active_end) {
                            self.cursor = self.active_first;
                            self.cached_y = self.source_y;
                            self.phase = .accumulate;
                        }
                    }
                },
                .accumulate => {
                    const n = @min(remaining, self.active_end - self.cursor);
                    for (self.sums[self.cursor..][0..n], self.horizontal[self.cursor..][0..n]) |*sum, value| {
                        const weighted = @as(u32, value) * self.weight_y;
                        sum.* += weighted;
                    }
                    self.cursor += n;
                    remaining -= n;
                    if (self.cursor == self.active_end) {
                        self.source_row_index += 1;
                        const axis = geometry.Axis.init(self.area.y + self.output_y, info.height, transform.base_height);
                        self.phase = if (self.source_row_index == axis.count) .emit else .begin;
                        self.cursor = 0;
                    }
                },
                .emit => {
                    const n = @min(remaining, self.area.width - self.cursor);
                    const x = self.area.x + @as(u32, @intCast(self.cursor));
                    const y = self.area.y + self.output_y;
                    const row = transform.outputRow(x, y);
                    var destination = row.index;
                    const total = info.width * info.height;
                    for (self.sums[self.cursor..][0..n]) |*sum| {
                        const ink = sum.*;
                        sum.* = 0;
                        const out = rgba[@as(usize, @intCast(destination)) * 4 ..][0..4];
                        if (ink == 0 or ink == total) {
                            out[0..3].* = if (ink == 0) bg else fg;
                        } else {
                            for (out[0..3], bg, fg) |*value, b, f| {
                                value.* = @intCast((@as(u64, total - ink) * b + @as(u64, ink) * f + total / 2) / total);
                            }
                        }
                        out[3] = 255;
                        destination += row.stride;
                    }
                    emitted += n;
                    self.cursor += n;
                    remaining -= n;
                    if (self.cursor == self.area.width) {
                        self.output_y += 1;
                        self.source_row_index = 0;
                        self.phase = .begin;
                    }
                },
            }
        }
        return emitted;
    }
};

/// Read 1..64 prevalidated contiguous mask bits, low bit first. Mask rows have
/// no byte padding. An empty mask denotes paper; never read past the allocation
/// or include padding/adjacent-row bits beyond the requested span.
pub fn readBits(mask: []const u8, first: usize, length: u32) u64 {
    if (mask.len == 0) return 0;
    const byte = first / 8;
    const shift: u6 = @intCast(first % 8);
    var value: u64 = 0;
    if (mask.len - byte >= 8) {
        value = std.mem.readInt(u64, mask[byte..][0..8], .little) >> shift;
        if (length > 64 - @as(u32, shift)) value |= @as(u64, mask[byte + 8]) << @as(u6, @intCast(64 - @as(u32, shift)));
    } else {
        for (mask[byte..], 0..) |b, i| value |= @as(u64, b) << @as(u6, @intCast(i * 8));
        value >>= shift;
    }
    return value & (@as(u64, std.math.maxInt(u64)) >> @as(u6, @intCast(64 - length)));
}
