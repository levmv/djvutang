const std = @import("std");
const djvu = @import("djvutang");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3 and args.len != 5) return error.ExpectedInputOutputAndOptionalSize;
    const a = init.gpa;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .limited(64 * 1024 * 1024));
    defer a.free(bytes);
    // Both objects stay at these addresses until deinit; input stays alive too.
    var doc = try djvu.Document.open(a, bytes, .{});
    defer doc.deinit();
    const size: ?djvu.RenderSize = if (args.len == 5) .{
        .width = try std.fmt.parseInt(u32, args[3], 10),
        .height = try std.fmt.parseInt(u32, args[4], 10),
    } else null;
    var job = try djvu.RenderJob.init(&doc, 0, .{ .size = size });
    defer job.deinit();
    while (try job.step(4096) != .done) {}
    const geometry = try job.geometry();
    const rgba = try job.pixels();
    const header = try std.fmt.allocPrint(a, "P6\n{d} {d}\n255\n", .{ geometry.width, geometry.height });
    defer a.free(header);
    const ppm = try a.alloc(u8, header.len + rgba.len / 4 * 3);
    defer a.free(ppm);
    @memcpy(ppm[0..header.len], header);
    for (0..rgba.len / 4) |i| @memcpy(ppm[header.len + 3 * i ..][0..3], rgba[4 * i ..][0..3]);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = ppm });
}
