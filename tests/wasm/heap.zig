//! Exercise the instance heap directly; these exports are absent from production.
const heap = @import("heap");

export fn alloc(len: u32, log_alignment: u32) u32 {
    const ptr = heap.allocator.rawAlloc(len, @enumFromInt(log_alignment), @returnAddress()) orelse return 0;
    return @intFromPtr(ptr);
}

export fn resize(ptr: u32, len: u32, log_alignment: u32, new_len: u32) bool {
    const memory: [*]u8 = @ptrFromInt(ptr);
    return heap.allocator.rawResize(memory[0..len], @enumFromInt(log_alignment), new_len, @returnAddress());
}

export fn realloc(ptr: u32, len: u32, log_alignment: u32, new_len: u32) u32 {
    const memory: [*]u8 = @ptrFromInt(ptr);
    switch (log_alignment) {
        inline 0, 4, 16, 17 => |bits| {
            const aligned: []align(1 << bits) u8 = @alignCast(memory[0..len]);
            const next = heap.allocator.realloc(aligned, new_len) catch return 0;
            return @intFromPtr(next.ptr);
        },
        else => unreachable,
    }
}

export fn free(ptr: u32, len: u32, log_alignment: u32) void {
    const memory: [*]u8 = @ptrFromInt(ptr);
    heap.allocator.rawFree(memory[0..len], @enumFromInt(log_alignment), @returnAddress());
}
