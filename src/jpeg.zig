const std = @import("std");
const types = @import("types.zig");
const Error = types.Error;
const Pixmap = @import("pixmap.zig").Pixmap;

const Info = extern struct { width: u32, height: u32 };
const CLimits = extern struct { pixels: usize, markers: usize, scans: usize, blocks: usize };
extern fn djvu_jpeg_size() usize;
extern fn djvu_jpeg_init(
    state: *anyopaque,
    bytes: [*]const u8,
    length: usize,
    context: *anyopaque,
    allocate: *const fn (*anyopaque, usize) callconv(.c) ?*anyopaque,
    release: *const fn (*anyopaque, *anyopaque, usize) callconv(.c) void,
    limits: CLimits,
    info: *Info,
) c_int;
extern fn djvu_jpeg_step(*anyopaque, usize, [*]u8) c_int;
extern fn djvu_jpeg_deinit(*anyopaque) void;

// The C state and callback context keep stable addresses when Decoder moves.
const Context = struct {
    allocator: std.mem.Allocator,

    fn allocate(ctx: *anyopaque, size: usize) callconv(.c) ?*anyopaque {
        const self: *Context = @ptrCast(@alignCast(ctx));
        const bytes = self.allocator.alignedAlloc(u8, .@"16", size) catch return null;
        return bytes.ptr;
    }

    fn release(ctx: *anyopaque, ptr: *anyopaque, size: usize) callconv(.c) void {
        const self: *Context = @ptrCast(@alignCast(ctx));
        const bytes: [*]align(16) u8 = @ptrCast(@alignCast(ptr));
        self.allocator.free(bytes[0..size]);
    }
};

/// Borrowed JPEG bytes; all allocations use the caller's allocator. Header
/// parsing precedes pixel allocation so a Job can check the layer dimensions.
pub const Decoder = struct {
    context: *Context,
    state: []align(16) u8,
    info: Info,
    image: ?Pixmap = null,
    failure: ?Error = null,
    done: bool = false,

    pub fn init(allocator: std.mem.Allocator, data: []const u8, limits: types.Limits) Error!Decoder {
        if (data.len > limits.max_input_bytes) return error.LimitExceeded;
        const context = try allocator.create(Context);
        errdefer allocator.destroy(context);
        context.* = .{ .allocator = allocator };
        const state = try allocator.alignedAlloc(u8, .@"16", djvu_jpeg_size());
        errdefer allocator.free(state);
        errdefer djvu_jpeg_deinit(state.ptr);
        var info: Info = undefined;
        try check(djvu_jpeg_init(state.ptr, data.ptr, data.len, context, Context.allocate, Context.release, .{
            .pixels = limits.max_page_pixels,
            .markers = limits.max_chunks,
            .scans = limits.max_jpeg_scans,
            .blocks = limits.max_jpeg_blocks,
        }, &info));
        return .{ .context = context, .state = state, .info = info };
    }

    pub fn deinit(self: *Decoder) void {
        const allocator = self.context.allocator;
        djvu_jpeg_deinit(self.state.ptr);
        if (self.image) |*image| image.deinit(allocator);
        allocator.free(self.state);
        allocator.destroy(self.context);
        self.* = undefined;
    }

    pub fn takeImage(self: *Decoder) Pixmap {
        std.debug.assert(self.done);
        const image = self.image.?;
        self.image = null;
        return image;
    }

    pub fn step(self: *Decoder, work: usize) Error!bool {
        if (self.failure) |err| return err;
        if (work == 0) return error.InvalidArgument;
        if (self.done) return true;
        return self.advance(work) catch |err| {
            self.failure = err;
            return err;
        };
    }

    fn advance(self: *Decoder, work: usize) Error!bool {
        if (self.image == null) {
            self.image = .{
                .width = self.info.width,
                .height = self.info.height,
                .pixels = try self.context.allocator.alloc([3]u8, @as(usize, self.info.width) * self.info.height),
            };
        }
        const status = djvu_jpeg_step(self.state.ptr, @max(1, work / 64), @ptrCast(self.image.?.pixels.ptr));
        try check(status);
        self.done = status == 0;
        return self.done;
    }
};

fn check(status: c_int) Error!void {
    switch (status) {
        0, 1 => {},
        2 => return error.InvalidData,
        3 => return error.Unsupported,
        4 => return error.LimitExceeded,
        5 => return error.OutOfMemory,
        else => unreachable,
    }
}
