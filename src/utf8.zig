//! Replacement decoding, matching the WHATWG UTF-8 decoder (BOM is preserved).
//! Byte ranges always address the source, never the replacement string.
const std = @import("std");
const Error = @import("types.zig").Error;

const Unit = struct { len: usize, valid: bool };

fn unit(bytes: []const u8) Unit {
    const first = bytes[0];
    if (first < 0x80) return .{ .len = 1, .valid = true };
    const len: usize = switch (first) {
        0xc2...0xdf => 2,
        0xe0...0xef => 3,
        0xf0...0xf4 => 4,
        else => return .{ .len = 1, .valid = false },
    };
    for (1..len) |i| {
        var low: u8 = 0x80;
        var high: u8 = 0xbf;
        if (i == 1) switch (first) {
            0xe0 => low = 0xa0,
            0xed => high = 0x9f,
            0xf0 => low = 0x90,
            0xf4 => high = 0x8f,
            else => {},
        };
        // Consume the valid prefix of an unfinished sequence, leaving the
        // offending byte for the next unit. In particular, never swallow ASCII.
        if (i == bytes.len or bytes[i] < low or bytes[i] > high)
            return .{ .len = i, .valid = false };
    }
    return .{ .len = len, .valid = true };
}

/// A source span must not split a valid scalar. Damaged bytes can have their
/// own zones; each requested span is decoded independently, like TextDecoder.
pub fn boundary(bytes: []const u8, index: usize) bool {
    if (index == 0 or index == bytes.len or bytes[index] & 0xc0 != 0x80) return true;
    var back: usize = 1;
    while (back <= @min(index, 3)) : (back += 1) {
        const start = index - back;
        if (bytes[start] & 0xc0 == 0x80) continue;
        const part = unit(bytes[start..]);
        return !part.valid or part.len <= back;
    }
    return true;
}

/// Owned, valid UTF-8. Each malformed subsequence becomes U+FFFD; valid bytes,
/// including BOM, NUL and separators, are copied exactly. At most 3x the input.
pub fn toUtf8(allocator: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    var length: usize = 0;
    var pos: usize = 0;
    while (pos < bytes.len) {
        const part = unit(bytes[pos..]);
        length = std.math.add(usize, length, if (part.valid) part.len else 3) catch return error.LimitExceeded;
        pos += part.len;
    }
    const result = try allocator.alloc(u8, length);
    pos = 0;
    var out: usize = 0;
    while (pos < bytes.len) {
        const part = unit(bytes[pos..]);
        const value = if (part.valid) bytes[pos..][0..part.len] else "\xef\xbf\xbd";
        @memcpy(result[out..][0..value.len], value);
        pos += part.len;
        out += value.len;
    }
    return result;
}

/// JSON carries original bytes only when they cannot be recovered by UTF-8
/// encoding the display string. Force an array, independent of byte contents.
pub const JsonBytes = struct {
    bytes: ?[]const u8,

    pub fn jsonStringify(self: JsonBytes, stream: *std.json.Stringify) std.Io.Writer.Error!void {
        const bytes = self.bytes orelse return stream.write(null);
        try stream.beginArray();
        for (bytes) |byte| try stream.write(byte);
        try stream.endArray();
    }
};
