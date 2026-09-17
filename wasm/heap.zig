//! Large WASM buffers use reusable runs of 64 KiB pages. Small allocations
//! retain the standard allocator's size classes. This singleton belongs to the
//! instance, not a document; close() releases buffers without resetting it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const max_memory = 256 * 1024 * 1024;
const page_size = 64 * 1024;
const max_pages = max_memory / page_size;

// Only pages acquired here can become free. Zero also covers the stack, data,
// and pages owned by the standard allocator. Adjacent free runs need no nodes
// or headers to split/coalesce, and live buffers never move implicitly.
var free_pages: [max_pages]bool = @splat(false);

pub const allocator: Allocator = .{
    .ptr = undefined,
    .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
};

fn large(len: usize, alignment: Alignment) bool {
    return len >= page_size or alignment.toByteUnits() >= page_size;
}

fn pages(len: usize) usize {
    return (len - 1) / page_size + 1;
}

fn alloc(_: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
    if (!large(len, alignment)) return std.heap.wasm_allocator.rawAlloc(len, alignment, ra);
    if (len > max_memory) return null;
    const count = pages(len);
    const page_alignment = @max(1, alignment.toByteUnits() / page_size);
    const current = @wasmMemorySize(0);
    if (current > max_pages) return null;
    var start: usize = 0;
    var run: usize = 0;
    for (free_pages[0..current], 0..) |available, i| {
        if (!available) {
            run = 0;
            continue;
        }
        if (run == 0) {
            if (i % page_alignment != 0) continue;
            start = i;
        }
        run += 1;
        if (run == count) {
            @memset(free_pages[start..][0..count], false);
            return @ptrFromInt(start * page_size);
        }
    }
    // Extend a free tail before growing memory. Any alignment gap is available
    // to later allocations; failed growth changes no allocation or free state.
    start = current;
    while (start > 0 and free_pages[start - 1]) start -= 1;
    start = std.mem.alignForward(usize, start, page_alignment);
    if (start > max_pages or count > max_pages - start) return null;
    const end = start + count;
    std.debug.assert(end > current);
    if (@wasmMemoryGrow(0, end - current) == -1) return null;
    @memset(free_pages[current..end], true);
    @memset(free_pages[start..end], false);
    return @ptrFromInt(start * page_size);
}

fn resize(_: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ra: usize) bool {
    // Free dispatch uses the caller's current length/alignment, so crossing
    // the threshold must use the ordinary allocate/copy/free fallback.
    if (large(memory.len, alignment) != large(len, alignment)) return false;
    if (!large(memory.len, alignment)) return std.heap.wasm_allocator.rawResize(memory, alignment, len, ra);
    const start = @intFromPtr(memory.ptr) / page_size;
    if (len > max_memory or pages(len) > max_pages - start) return false;
    const old_end = start + pages(memory.len);
    const end = start + pages(len);
    if (end <= old_end) {
        @memset(free_pages[end..old_end], true);
        return true;
    }
    const current = @wasmMemorySize(0);
    for (free_pages[old_end..@min(current, end)]) |available| if (!available) return false;
    if (end > current and @wasmMemoryGrow(0, end - current) == -1) return false;
    @memset(free_pages[old_end..end], false);
    return true;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ra: usize) ?[*]u8 {
    return if (resize(ctx, memory, alignment, len, ra)) memory.ptr else null;
}

fn free(_: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
    if (!large(memory.len, alignment)) return std.heap.wasm_allocator.rawFree(memory, alignment, ra);
    const start = @intFromPtr(memory.ptr) / page_size;
    @memset(free_pages[start..][0..pages(memory.len)], true);
}
