const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Keep this object at a stable address while its allocator is in use.
/// Counts requested live bytes, excluding borrowed input and allocator overhead.
pub const Budget = struct {
    parent: Allocator,
    limit: usize,
    live: usize = 0,
    peak: usize = 0,
    denied: bool = false,

    pub fn allocator(self: *Budget) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn from(ctx: *anyopaque) *Budget {
        return @ptrCast(@alignCast(ctx));
    }

    fn allow(self: *Budget, old: usize, new: usize) bool {
        if (new > self.limit - (self.live - old)) {
            self.denied = true;
            return false;
        }
        return true;
    }

    fn change(self: *Budget, old: usize, new: usize) void {
        self.live = self.live - old + new;
        self.peak = @max(self.peak, self.live);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self = from(ctx);
        if (!self.allow(0, len)) return null;
        const ptr = self.parent.rawAlloc(len, alignment, ra) orelse return null;
        self.change(0, len);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ra: usize) bool {
        const self = from(ctx);
        if (!self.allow(memory.len, len)) return false;
        if (!self.parent.rawResize(memory, alignment, len, ra)) return false;
        self.change(memory.len, len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ra: usize) ?[*]u8 {
        const self = from(ctx);
        if (!self.allow(memory.len, len)) return null;
        const ptr = self.parent.rawRemap(memory, alignment, len, ra) orelse return null;
        self.change(memory.len, len);
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        const self = from(ctx);
        self.parent.rawFree(memory, alignment, ra);
        self.change(memory.len, 0);
    }
};
