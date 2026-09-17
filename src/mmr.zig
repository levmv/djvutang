//! Resumable Smmr / CCITT Group 4 decoder; see THIRD_PARTY_NOTICES.txt.
const std = @import("std");
const types = @import("types.zig");
const Error = types.Error;
const Bitmap = @import("pixmap.zig").Bitmap;
const tables = @import("mmr_tables.zig");

const Bits = struct {
    data: []const u8 = &.{},
    pos: usize = 0,

    fn remaining(self: Bits) usize {
        return self.data.len * 8 - self.pos;
    }

    fn read(self: *Bits, count: usize) Error!u32 {
        if (count > self.remaining()) return error.InvalidData;
        var value: u32 = 0;
        for (0..count) |_| {
            value = (value << 1) | ((self.data[self.pos / 8] >> @intCast(7 - self.pos % 8)) & 1);
            self.pos += 1;
        }
        return value;
    }

    fn code(self: *Bits, tree: []const [2]i16) Error!u32 {
        var node: i16 = 1;
        // T.6's longest code has 13 bits. No padding can complete a short code.
        for (0..13) |_| {
            node = tree[@intCast(node)][try self.read(1)];
            if (node < 0) return @intCast(~node);
            if (node == 0) return error.InvalidData;
        }
        return error.InvalidData;
    }
};

const State = enum { mode, run1, run2, fill, uncompressed, literal, trailer, done };

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    limits: types.Limits,
    data: []const u8,
    offset: usize,
    striped: bool,
    invert: u1,
    rows_per_stripe: u32,
    stripe_end: u32 = 0,
    bits: Bits = .{},
    image: Bitmap,
    // Changing elements of the previous/current raw (uninverted) row.
    // Binary search avoids rescanning a long reference run for each short run.
    previous: []u32,
    current: []u32,
    previous_count: usize = 0,
    current_count: usize = 0,
    row: u32 = 0,
    x: u32 = 0,
    last_color: u1 = 0,
    pen: u1 = 0,
    start: bool = true,
    state: State = .mode,
    records: usize = 0,
    horizontal_start: u32 = 0,
    run_total: u32 = 0,
    fill_left: u32 = 0,
    fill_color: u1 = 0,
    after_fill: State = .mode,
    literal_left: u4 = 0,
    literal_bits: u8 = 0,
    after_literal: State = .uncompressed,
    literal_pen: u1 = 0,
    trailer_started: bool = false,

    pub fn init(allocator: std.mem.Allocator, data: []const u8, limits: types.Limits) Error!Decoder {
        if (data.len > limits.max_input_bytes or data.len > std.math.maxInt(usize) / 8) return error.LimitExceeded;
        if (data.len < 8 or !std.mem.eql(u8, data[0..3], "MMR")) return error.InvalidData;
        if (data[3] & 0xfc != 0) return error.Unsupported;
        const width: u32 = std.mem.readInt(u16, data[4..6], .big);
        const height: u32 = std.mem.readInt(u16, data[6..8], .big);
        if (width == 0 or height == 0) return error.InvalidData;
        const count = std.math.mul(usize, width, height) catch return error.LimitExceeded;
        if (count > limits.max_page_pixels) return error.LimitExceeded;
        const striped = data[3] & 2 != 0;
        if (striped and data.len < 10) return error.InvalidData;
        const rps = if (striped) std.mem.readInt(u16, data[8..10], .big) else height;
        if (rps == 0) return error.InvalidData;
        const pixels = try allocator.alloc(u8, (count + 7) / 8);
        errdefer allocator.free(pixels);
        @memset(pixels, 0);
        const previous = try allocator.alloc(u32, width);
        errdefer allocator.free(previous);
        const current = try allocator.alloc(u32, width);
        errdefer allocator.free(current);
        var self: Decoder = .{
            .allocator = allocator,
            .limits = limits,
            .data = data,
            .offset = if (striped) 10 else 8,
            .striped = striped,
            .invert = @truncate(data[3]),
            .rows_per_stripe = rps,
            .image = .{ .width = width, .height = height, .pixels = pixels },
            .previous = previous,
            .current = current,
        };
        try self.beginStripe();
        return self;
    }

    pub fn deinit(self: *Decoder) void {
        self.image.deinit(self.allocator);
        self.allocator.free(self.previous);
        self.allocator.free(self.current);
        self.* = undefined;
    }

    pub fn takeImage(self: *Decoder) Bitmap {
        std.debug.assert(self.state == .done);
        const image = self.image;
        self.image = .{};
        return image;
    }

    fn beginStripe(self: *Decoder) Error!void {
        var size = self.data.len - self.offset;
        if (self.striped) {
            if (size < 4) return error.InvalidData;
            size = std.mem.readInt(u32, self.data[self.offset..][0..4], .big);
            self.offset += 4;
        }
        if (size == 0 or size > self.data.len - self.offset) return error.InvalidData;
        self.bits = .{ .data = self.data[self.offset..][0..size] };
        self.offset += size;
        self.stripe_end = @min(self.image.height, self.row + self.rows_per_stripe);
        self.previous_count = 0; // Every stripe starts against an imaginary white row.
        self.trailer_started = false;
        self.state = .mode;
    }

    fn nextRow(self: *Decoder) void {
        std.debug.assert(self.x == self.image.width);
        std.mem.swap([]u32, &self.previous, &self.current);
        self.previous_count = self.current_count;
        self.current_count = 0;
        self.row += 1;
        self.x = 0;
        self.pen = 0;
        self.last_color = 0;
        self.start = true;
    }

    fn writePixel(self: *Decoder, raw: u1) Error!void {
        if (self.x >= self.image.width or self.row >= self.stripe_end) return error.InvalidData;
        if (raw != self.last_color) {
            self.current[self.current_count] = self.x;
            self.current_count += 1;
            self.last_color = raw;
        }
        const index = @as(usize, self.row) * self.image.width + self.x;
        if (raw ^ self.invert != 0) self.image.pixels[index / 8] |= @as(u8, 1) << @intCast(index % 8);
        self.x += 1;
    }

    fn reference(self: *const Decoder) [2]u32 {
        var lo: usize = 0;
        var hi = self.previous_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const x = self.previous[mid];
            if (x < self.x or (x == self.x and !self.start)) lo = mid + 1 else hi = mid;
        }
        // Even transitions enter black, odd transitions enter white.
        if (lo % 2 != self.pen) lo += 1;
        return .{
            if (lo < self.previous_count) self.previous[lo] else self.image.width,
            if (lo + 1 < self.previous_count) self.previous[lo + 1] else self.image.width,
        };
    }

    fn record(self: *Decoder) Error!void {
        if (self.records >= self.limits.max_records) return error.LimitExceeded;
        self.records += 1;
    }

    fn advance(self: *Decoder) Error!void {
        switch (self.state) {
            .done => {},
            .mode => {
                if (self.x == self.image.width) self.nextRow();
                if (self.row == self.stripe_end) {
                    self.state = .trailer;
                    return;
                }
                try self.record();
                const mode = try self.bits.code(&tables.mode);
                if (mode == 1) {
                    self.horizontal_start = self.x;
                    self.run_total = 0;
                    self.state = .run1;
                } else if (mode == 9) {
                    if (try self.bits.read(3) != 7) return error.Unsupported;
                    self.state = .uncompressed;
                } else {
                    const b = self.reference();
                    const shifts = [_]i32{ 0, 1, 2, 3, -1, -2, -3 };
                    const end: i32 = if (mode == 0) @intCast(b[1]) else @as(i32, @intCast(b[0])) + shifts[mode - 2];
                    if (end < self.x or end > self.image.width) return error.InvalidData;
                    self.fill_left = @as(u32, @intCast(end)) - self.x;
                    self.fill_color = self.pen;
                    if (mode != 0) self.pen ^= 1;
                    self.after_fill = .mode;
                    self.state = .fill;
                }
                self.start = false;
            },
            .run1, .run2 => {
                try self.record();
                const value = try self.bits.code(if (self.pen == 0) &tables.white else &tables.black);
                self.run_total += value;
                if (self.run_total > self.image.width - self.x) return error.InvalidData;
                if (value >= 64) return;
                if (self.state == .run2 and self.x + self.run_total == self.horizontal_start) return error.InvalidData;
                self.fill_left = self.run_total;
                self.fill_color = self.pen;
                self.pen ^= 1;
                self.run_total = 0;
                self.after_fill = if (self.state == .run1) .run2 else .mode;
                self.state = .fill;
            },
            .fill => {
                if (self.fill_left == 0) {
                    self.state = self.after_fill;
                    return;
                }
                try self.writePixel(self.fill_color);
                self.fill_left -= 1;
            },
            .uncompressed => {
                try self.record();
                var zeros: u4 = 0;
                while (try self.bits.read(1) == 0) {
                    zeros += 1;
                    if (zeros > 10) return error.InvalidData;
                }
                self.literal_bits = if (zeros < 5) 1 else 0;
                self.literal_left = if (zeros < 5) zeros + 1 else if (zeros == 5) 5 else zeros - 6;
                self.after_literal = if (zeros < 6) .uncompressed else .mode;
                if (zeros >= 6) self.literal_pen = @intCast(try self.bits.read(1));
                self.state = .literal;
            },
            .literal => {
                if (self.literal_left == 0) {
                    self.state = self.after_literal;
                    if (self.state == .mode) self.pen = self.literal_pen;
                    self.start = self.x == 0;
                    return;
                }
                self.literal_left -= 1;
                try self.writePixel(@truncate(self.literal_bits >> @intCast(self.literal_left)));
                if (self.x == self.image.width) self.nextRow();
            },
            .trailer => {
                if (!self.trailer_started) {
                    self.trailer_started = true;
                    const left = self.bits.remaining();
                    if (left <= 7) {
                        // Known-height streams sometimes omit EOFB. Only a final
                        // partial byte of uniform padding is unambiguous.
                        const padding = try self.bits.read(left);
                        if (padding != 0 and padding != (@as(u32, 1) << @intCast(left)) - 1) return error.InvalidData;
                    } else if (try self.bits.read(24) != 0x001001) return error.InvalidData;
                }
                if (self.bits.remaining() != 0) {
                    if (try self.bits.read(@min(8, self.bits.remaining())) != 0) return error.InvalidData;
                    return;
                }
                if (self.row < self.image.height) return self.beginStripe();
                if (self.offset != self.data.len) return error.InvalidData;
                self.state = .done;
            },
        }
    }

    /// One unit decodes a bounded codeword or writes one pixel, including long runs.
    pub fn step(self: *Decoder, work: usize) Error!bool {
        if (work == 0) return error.InvalidArgument;
        for (0..work) |_| {
            if (self.state == .done) return true;
            try self.advance();
        }
        return self.state == .done;
    }
};
