//! Cover benchmark. Timings exclude file IO and hashing; peaks include input.
const std = @import("std");
const djvu = @import("djvutang");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var first_path: usize = 1;
    var width: ?u32 = null;
    var full = false;
    while (first_path < args.len and std.mem.startsWith(u8, args[first_path], "--")) : (first_path += 1) {
        const arg = args[first_path];
        if (std.mem.startsWith(u8, arg, "--width=")) {
            width = try std.fmt.parseInt(u32, arg[8..], 10);
            if (width.? == 0 or width.? > 65535) return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--full")) {
            full = true;
        } else return error.InvalidArgument;
    }
    if (first_path == args.len or (full and width != null)) {
        std.debug.print("usage: zig build bench -- [--width=N | --full] INPUT...\n", .{});
        return error.InvalidArgument;
    }
    var buffer: [4096]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    for (args[first_path..]) |path| {
        var budget: djvu.Budget = .{ .parent = init.gpa, .limit = 192 * 1024 * 1024 };
        {
            const a = budget.allocator();
            const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
            defer file.close(init.io);
            var reader = file.reader(init.io, &.{});
            const bytes = try reader.interface.allocRemaining(a, .limited(128 * 1024 * 1024));
            defer a.free(bytes);
            const start = std.Io.Clock.awake.now(init.io);
            var doc = try djvu.Document.open(a, bytes, .{});
            defer doc.deinit();
            const info = try doc.info(0);
            const display_width: u32 = if (info.rotation & 1 != 0) info.height else info.width;
            const display_height: u32 = if (info.rotation & 1 != 0) info.width else info.height;
            const options: djvu.RenderOptions = .{ .size = if (full) null else .{
                .width = width orelse 400,
                .height = if (width) |w| @max(1, (display_height * w + display_width - 1) / display_width) else 600,
            } };
            var job = try djvu.RenderJob.init(&doc, 0, options);
            defer job.deinit();
            const setup_ms = milliseconds(start.durationTo(std.Io.Clock.awake.now(init.io)));
            for (0..2) |pass| {
                if (pass != 0) try job.restart(options);
                var durations = [_]i96{ 0, 0, 0 };
                var iw44_durations = [_]i96{0} ** 5;
                var steps: usize = 0;
                var longest: i96 = 0;
                while (true) {
                    const wavelet = if (job.wavelet) |*decoder| decoder else blk: {
                        for (&job.regional) |*layer| if (layer.*) |*decoder| {
                            if (decoder.phase != .done) break :blk decoder;
                        };
                        break :blk null;
                    };
                    // A solid-layer plan can retain a satisfied `needed` region;
                    // only an active IW44 phase denotes reconstruction work.
                    const stage: usize = if (wavelet != null) 0 else if (job.renderer) |r|
                        (if (r.rasterized) 2 else 1)
                    else
                        0;
                    const iw44_stage: ?usize = if (wavelet) |decoder| switch (decoder.phase) {
                        .entropy => 0,
                        .scatter => 1,
                        .filter => 2,
                        .extract => 3,
                        .color => 4,
                        else => null,
                    } else null;
                    const before = std.Io.Clock.awake.now(init.io);
                    const status = try job.step(4096);
                    const elapsed = before.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
                    durations[stage] += elapsed;
                    if (iw44_stage) |i| iw44_durations[i] += elapsed;
                    longest = @max(longest, elapsed);
                    steps += 1;
                    if (status == .done) break;
                }
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(try job.pixels(), &digest, .{});
                const geometry = try job.geometry();
                var symbol_bytes: usize = 0;
                if (job.image) |*image| {
                    for (0..image.shapeCount()) |i| symbol_bytes += image.shape(@intCast(i)).pixels.len;
                }
                try std.json.Stringify.value(.{
                    .file = path,
                    .warm = pass != 0,
                    .source = .{ info.width, info.height },
                    .output = .{ geometry.width, geometry.height },
                    .setup_ms = if (pass == 0) setup_ms else 0,
                    .decode_ms = milliseconds(.{ .nanoseconds = durations[0] }),
                    .mask_ms = milliseconds(.{ .nanoseconds = durations[1] }),
                    .compose_ms = milliseconds(.{ .nanoseconds = durations[2] }),
                    .jb2 = .{
                        .page_shapes = if (job.image) |image| image.shapes.items.len else 0,
                        .inherited_shapes = if (job.image) |image| image.inherited_count else 0,
                        .symbol_bytes = symbol_bytes,
                        .blits = if (job.image) |image| image.blits.items.len else 0,
                    },
                    .iw44_ms = .{
                        .entropy = milliseconds(.{ .nanoseconds = iw44_durations[0] }),
                        .scatter = milliseconds(.{ .nanoseconds = iw44_durations[1] }),
                        .filter = milliseconds(.{ .nanoseconds = iw44_durations[2] }),
                        .extract = milliseconds(.{ .nanoseconds = iw44_durations[3] }),
                        .color = milliseconds(.{ .nanoseconds = iw44_durations[4] }),
                    },
                    .max_step_ms = milliseconds(.{ .nanoseconds = longest }),
                    .steps = steps,
                    .live_bytes = budget.live,
                    .peak_bytes = budget.peak,
                    .rgba_sha256 = &std.fmt.bytesToHex(digest, .lower),
                }, .{}, &out.interface);
                try out.interface.writeByte('\n');
                try out.interface.flush();
            }
        }
        std.debug.assert(budget.live == 0);
    }
}

fn milliseconds(duration: std.Io.Duration) f64 {
    return @as(f64, @floatFromInt(duration.nanoseconds)) / std.time.ns_per_ms;
}
