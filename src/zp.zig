//! DjVu ZP arithmetic decoding.
const table = @import("zp_table.zig");
const Error = @import("types.zig").Error;

pub const Decoder = struct {
    bytes: []const u8,
    pos: usize = 0,
    interval: u32 = 0,
    code: u32 = 0,
    fence: u32 = 0,
    reservoir: u32 = 0,
    bits: u6 = 0,
    padding: u8 = 25,

    pub fn init(bytes: []const u8) Error!Decoder {
        // IW44 can describe slices with no stored arithmetic bytes. The same
        // bounded virtual 1 bits apply at initialization and later refills.
        var self: Decoder = .{ .bytes = bytes };
        self.code = (@as(u32, try self.byte()) << 8) | try self.byte();
        try self.refill();
        self.fence = @min(self.code, 0x7fff);
        return self;
    }

    fn byte(self: *Decoder) Error!u8 {
        if (self.pos < self.bytes.len) {
            const b = self.bytes[self.pos];
            self.pos += 1;
            return b;
        }
        // ZP termination permits bounded virtual 1 bits, not endless EOF.
        if (self.padding == 0) return error.InvalidData;
        self.padding -= 1;
        return 255;
    }

    fn refill(self: *Decoder) Error!void {
        while (self.bits <= 24) {
            self.reservoir = (self.reservoir << 8) | try self.byte();
            self.bits += 8;
        }
    }

    fn normalize(self: *Decoder, shift: u5) Error!void {
        self.bits -= shift;
        const count: u5 = @intCast(self.bits);
        self.interval = (self.interval << shift) & 0xffff;
        self.code = ((self.code << shift) & 0xffff) |
            ((self.reservoir >> count) & ((@as(u32, 1) << shift) - 1));
        if (self.bits < 16) try self.refill();
        self.fence = @min(self.code, 0x7fff);
    }

    fn lower(self: *Decoder, split: u32) Error!void {
        self.interval += 0x10000 - split;
        self.code += 0x10000 - split;
        const inv: u16 = ~@as(u16, @truncate(self.interval));
        try self.normalize(@intCast(@clz(inv)));
    }

    pub fn bit(self: *Decoder, context: *u8) Error!u1 {
        const state = context.*;
        if (state > 250) return error.InvalidData;
        const most: u1 = @truncate(state);
        var split = self.interval + table.p[state];
        if (split <= self.fence) {
            self.interval = split;
            return most;
        }
        split = @min(split, 0x6000 + ((split + self.interval) >> 2));
        if (split > self.code) {
            context.* = table.dn[state];
            try self.lower(split);
            return most ^ 1;
        }
        if (self.interval >= table.m[state]) context.* = table.up[state];
        self.interval = split;
        try self.normalize(1);
        return most;
    }

    pub fn raw(self: *Decoder) Error!u1 {
        return self.simple(0x8000 + (self.interval >> 1));
    }

    /// IW44 uses a different equiprobable split from JB2/BZZ.
    pub fn wavelet(self: *Decoder) Error!u1 {
        return self.simple(0x8000 + ((3 * self.interval) >> 3));
    }

    fn simple(self: *Decoder, split: u32) Error!u1 {
        if (split > self.code) {
            try self.lower(split);
            return 1;
        }
        self.interval = split;
        try self.normalize(1);
        return 0;
    }
};
