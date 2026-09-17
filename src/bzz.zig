//! BZZ stream decoding.
const std = @import("std");
const Zp = @import("zp.zig").Decoder;
const Error = @import("types.zig").Error;

fn raw(zp: *Zp, bits: u5) Error!u32 {
    var n: u32 = 0;
    for (0..bits) |_| n = (n << 1) | try zp.raw();
    return n;
}

fn rank(zp: *Zp, contexts: *[300]u8, previous: usize) Error!usize {
    const group: usize = @min(previous, 2);
    if (try zp.bit(&contexts[group]) != 0) return 0;
    if (try zp.bit(&contexts[3 + group]) != 0) return 1;
    var offset: usize = 6;
    for (1..8) |bits| {
        const width: usize = @as(usize, 1) << @intCast(bits);
        if (try zp.bit(&contexts[offset]) != 0) {
            var n: usize = 1;
            while (n < width) n = (n << 1) | try zp.bit(&contexts[offset + n]);
            return n;
        }
        offset += width;
    }
    return 256;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, max_bytes: usize) Error![]u8 {
    if (bytes.len == 0) return error.InvalidData;
    var zp = try Zp.init(bytes);
    var contexts = [_]u8{0} ** 300;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    while (true) {
        const size: usize = try raw(&zp, 24);
        if (size == 0) return result.toOwnedSlice(allocator);
        if (size > 4 * 1024 * 1024 or size - 1 > max_bytes - result.items.len) return error.LimitExceeded;
        const data = try allocator.alloc(u8, size);
        defer allocator.free(data);
        var shift: u5 = 0;
        if (try zp.raw() != 0) {
            shift = 1;
            if (try zp.raw() != 0) shift = 2;
        }
        var order: [256]u8 = undefined;
        for (&order, 0..) |*entry, i| entry.* = @intCast(i);
        var frequency = [_]u32{0} ** 4;
        var addition: u32 = 4;
        var previous: usize = 3;
        var marker: ?usize = null;
        for (data, 0..) |*dest, i| {
            const index = try rank(&zp, &contexts, previous);
            previous = index;
            if (index == 256) {
                if (marker != null) return error.InvalidData;
                marker = i;
                dest.* = 0;
                continue;
            }
            dest.* = order[index];
            addition += addition >> shift;
            if (addition > 0x10000000) {
                addition >>= 24;
                for (&frequency) |*f| f.* >>= 24;
            }
            const f = addition + if (index < 4) frequency[index] else @as(u32, 0);
            var k = index;
            while (k >= 4) : (k -= 1) order[k] = order[k - 1];
            while (k > 0 and f >= frequency[k - 1]) : (k -= 1) {
                order[k] = order[k - 1];
                frequency[k] = frequency[k - 1];
            }
            order[k] = dest.*;
            frequency[k] = f;
        }
        const mark = marker orelse return error.InvalidData;
        if (mark == 0 or mark >= size) return error.InvalidData;
        // Invert BWT: pair each byte in the last column with its occurrence
        // rank. Blocks fit in 24 bits, leaving the high byte for the symbol.
        const links = try allocator.alloc(u32, size);
        defer allocator.free(links);
        var counts = [_]u32{0} ** 256;
        for (data, 0..) |c, i| {
            if (i == mark) continue;
            links[i] = (@as(u32, c) << 24) | counts[c];
            counts[c] += 1;
        }
        // The end marker sorts first; prefix sums locate the other symbols
        // in the first column. Following links reconstructs the block backwards.
        var total: u32 = 1;
        for (&counts) |*count| {
            const n = count.*;
            count.* = total;
            total += n;
        }
        var cursor: usize = 0;
        var output = size - 1;
        while (output > 0) {
            if (cursor >= size or cursor == mark) return error.InvalidData;
            const link = links[cursor];
            const c: u8 = @truncate(link >> 24);
            output -= 1;
            data[output] = c;
            cursor = counts[c] + (link & 0xffffff);
        }
        if (cursor != mark) return error.InvalidData;
        try result.appendSlice(allocator, data[0 .. size - 1]);
    }
}
