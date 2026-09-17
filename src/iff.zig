const std = @import("std");
const Error = @import("types.zig").Error;

pub fn tag(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn isIw44(kind: []const u8) bool {
    return tag(kind, "PM44") or tag(kind, "BM44");
}

pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn take(self: *Reader, n: usize) Error![]const u8 {
        if (n > self.bytes.len - self.pos) return error.InvalidData;
        const result = self.bytes[self.pos..][0..n];
        self.pos += n;
        return result;
    }

    pub fn byte(self: *Reader) Error!u8 {
        return (try self.take(1))[0];
    }

    pub fn uint(self: *Reader, n: usize) Error!u32 {
        var result: u32 = 0;
        for (try self.take(n)) |b| result = (result << 8) | b;
        return result;
    }

    pub fn string(self: *Reader) Error![]const u8 {
        const end = std.mem.indexOfScalarPos(u8, self.bytes, self.pos, 0) orelse return error.InvalidData;
        const result = self.bytes[self.pos..end];
        self.pos = end + 1;
        return result;
    }
};

pub const Chunk = struct {
    id: []const u8,
    data: []const u8,
    offset: usize,

    pub fn children(self: Chunk) Error!Iterator {
        if (!tag(self.id, "FORM") or self.data.len < 4) return error.InvalidData;
        return .{ .bytes = self.data[4..], .base = self.offset + 12 };
    }

    pub fn formType(self: Chunk) Error![]const u8 {
        if (!tag(self.id, "FORM") or self.data.len < 4) return error.InvalidData;
        return self.data[0..4];
    }
};

pub const Iterator = struct {
    bytes: []const u8,
    base: usize = 0,
    pos: usize = 0,

    pub fn next(self: *Iterator) Error!?Chunk {
        if (self.pos == self.bytes.len) return null;
        var reader: Reader = .{ .bytes = self.bytes, .pos = self.pos };
        const id = try reader.take(4);
        const length = try reader.uint(4);
        const data = try reader.take(length);
        const offset = self.base + self.pos;
        // A final odd chunk may omit padding at the end of its enclosing FORM.
        self.pos = reader.pos;
        if (length & 1 != 0 and self.pos < self.bytes.len) self.pos += 1;
        return .{ .id = id, .data = data, .offset = offset };
    }
};

pub fn root(bytes: []const u8) Error!Chunk {
    if (bytes.len < 12) return error.InvalidData;
    const start: usize = if (tag(bytes[0..4], "AT&T")) 4 else 0;
    var iter: Iterator = .{ .bytes = bytes[start..], .base = start };
    const chunk = (try iter.next()) orelse return error.InvalidData;
    const kind = try chunk.formType();
    // Standalone IW44 may omit the AT&T prefix.
    if (start == 0 and !isIw44(kind)) return error.InvalidData;
    if (iter.pos != iter.bytes.len) return error.InvalidData;
    return chunk;
}

pub fn infoVersion(bytes: []const u8) Error!u16 {
    if (bytes.len < 5) return error.InvalidData;
    // Early INFO has only the low byte; 0xff in the high byte also means absent.
    const high: u16 = if (bytes.len >= 6 and bytes[5] != 0xff) bytes[5] else 0;
    return (high << 8) | bytes[4];
}

pub const Info = struct {
    width: u32,
    height: u32,
    dpi: u32,
    rotation: u2,
    gamma_tenths: u8 = 22,

    pub fn parse(bytes: []const u8) Error!Info {
        if (bytes.len < 5) return error.InvalidData;
        var r: Reader = .{ .bytes = bytes };
        const width = try r.uint(2);
        const height = try r.uint(2);
        if (width == 0 or height == 0) return error.InvalidData;
        var dpi: u32 = if (bytes.len >= 8) @as(u32, bytes[6]) | (@as(u32, bytes[7]) << 8) else 300;
        if (dpi < 25 or dpi > 6000) dpi = 300;
        const flags = if (bytes.len >= 10) bytes[9] & 7 else 0;
        return .{
            .width = width,
            .height = height,
            .dpi = dpi,
            .gamma_tenths = if (bytes.len >= 9) std.math.clamp(bytes[8], 3, 50) else 22,
            .rotation = switch (flags) {
                6 => 1,
                2 => 2,
                5 => 3,
                else => 0,
            },
        };
    }
};
