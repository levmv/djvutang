//! Import-free test module; none of these exports belong to djvutang.wasm.
const std = @import("std");
const probe = @import("iw44_probe");
var budget: probe.Budget = .{ .parent = std.heap.wasm_allocator, .limit = 0 };
var input: []u8 = &.{};
var source: ?probe.Source = null;

fn status(err: anyerror) u32 {
    return switch (err) {
        error.InvalidArgument, error.Busy => 2,
        error.OutOfMemory => if (budget.denied) 4 else 5,
        error.LimitExceeded => 4,
        else => 3,
    };
}

export fn close() void {
    if (source) |*s| s.deinit();
    source = null;
    budget.allocator().free(input);
    input = &.{};
}

export fn input_alloc(length: usize, limit: usize) usize {
    close();
    budget = .{ .parent = std.heap.wasm_allocator, .limit = limit };
    input = budget.allocator().alloc(u8, length) catch return 0;
    return @intFromPtr(input.ptr);
}

export fn open() u32 {
    if (source != null) return 2;
    budget.denied = false;
    source = probe.Source.init(budget.allocator(), input) catch |err| return status(err);
    return 0;
}

export fn step(work: usize) u32 {
    const s = if (source) |*s| s else return 2;
    budget.denied = false;
    return if (s.decoder.step(work) catch |err| return status(err)) 0 else 1;
}

export fn reconstruct(reduction: u32, x: u32, y: u32, width: u32, height: u32) u32 {
    const s = if (source) |*s| s else return 2;
    budget.denied = false;
    if (width == 0 and height == 0 and x == 0 and y == 0) {
        s.reconstruct(reduction) catch |err| return status(err);
    } else s.decoder.reconstructReduced(reduction, .{ .x = x, .y = y, .width = width, .height = height }) catch |err| return status(err);
    return 0;
}

export fn result_ptr() usize {
    const s = if (source) |*s| s else return 0;
    if (s.decoder.phase != .done) return 0;
    const image = s.decoder.image orelse return 0;
    return if (image.pixels.len != 0) @intFromPtr(image.pixels.ptr) else 0;
}

export fn result_len() usize {
    const s = if (source) |*s| s else return 0;
    if (s.decoder.phase != .done) return 0;
    const image = s.decoder.image orelse return 0;
    if (image.pixels.len == 0) return 0;
    return @as(usize, image.area().width) * image.area().height * 3;
}

export fn result_width() u32 {
    const s = if (source) |*s| s else return 0;
    return if (s.decoder.image) |image| image.area().width else 0;
}

export fn result_height() u32 {
    const s = if (source) |*s| s else return 0;
    return if (s.decoder.image) |image| image.area().height else 0;
}

export fn live_bytes() usize {
    return budget.live;
}

export fn peak_bytes() usize {
    return budget.peak;
}
