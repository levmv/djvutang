const std = @import("std");
const djvu = @import("djvutang");

const Command = union(enum) {
    info,
    text: usize,
    annotations: usize,
    outline,
    resolve_link: struct { href: []const u8, origin: ?usize },
    render: RenderCommand,
};
const RenderCommand = struct {
    output: []const u8,
    page: usize,
    thumbnail: bool,
    options: djvu.RenderOptions,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: djvutang info INPUT | " ++
            "text INPUT [PAGE=1] | annotations INPUT [PAGE=1] | outline INPUT | " ++
            "resolve-link INPUT HREF [FROM_PAGE] | " ++
            "render INPUT OUTPUT.ppm [PAGE=1] [SUBSAMPLE=1] [ROTATION=0] | " ++
            "fit INPUT OUTPUT.ppm PAGE WIDTH HEIGHT [ROTATION=0] | " ++
            "region INPUT OUTPUT.ppm PAGE SUBSAMPLE ROTATION X Y WIDTH HEIGHT | " ++
            "thumbnail INPUT OUTPUT.ppm [PAGE=1]\n", .{});
        std.process.exit(2);
    }
    const command = try parseCommand(args[1], args[3..]);
    const path = args[2];
    var budget: djvu.Budget = .{ .parent = init.gpa, .limit = 192 * 1024 * 1024 };
    const allocator = budget.allocator();
    const input = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer input.close(init.io);
    var doc = try openDocument(init.io, input, allocator);
    defer doc.deinit();
    var buffer: [4096]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const w = &out.interface;
    switch (command) {
        .info => {
            try w.print("{{\"pages\":{d},\"sizes\":[", .{doc.pageCount()});
            for (0..doc.pageCount()) |i| {
                try prepare(init.io, &doc, input, path, i, .page);
                const info = try doc.info(i);
                if (i != 0) try w.writeAll(",");
                try w.print("{{\"width\":{d},\"height\":{d},\"rotation\":{d}}}", .{ info.width, info.height, info.rotation });
                try doc.dropComponents();
            }
            try w.writeAll("]}\n");
        },
        .text => |page| {
            try prepare(init.io, &doc, input, path, page, .includes);
            if (try doc.text(page)) |value| {
                var text = value;
                defer text.deinit(allocator);
                try writeTextJson(w, &text, allocator);
            } else try w.writeAll("null\n");
        },
        .annotations => |page| {
            try prepare(init.io, &doc, input, path, page, .includes);
            if (try doc.annotations(page)) |value| {
                var data = value;
                defer data.deinit();
                try std.json.Stringify.value(&data, .{}, w);
            } else try w.writeAll("null");
            try w.writeAll("\n");
        },
        .outline => {
            if (try doc.outline()) |value| {
                var data = value;
                defer data.deinit(allocator);
                try std.json.Stringify.value(&data, .{}, w);
            } else try w.writeAll("null");
            try w.writeAll("\n");
        },
        .resolve_link => |link| {
            try std.json.Stringify.value(try doc.resolveLink(link.href, link.origin), .{}, w);
            try w.writeAll("\n");
        },
        .render => |render| {
            try prepare(init.io, &doc, input, path, render.page, if (render.thumbnail) .thumbnail else .includes);
            try renderToFile(init.io, &doc, render, &budget, w);
        },
    }
    try w.flush();
}

fn pageIndex(arg: []const u8) !usize {
    const page = try std.fmt.parseInt(usize, arg, 10);
    if (page == 0) return error.InvalidArgument;
    return page - 1;
}

fn parseCommand(name: []const u8, args: []const []const u8) !Command {
    if (std.mem.eql(u8, name, "info") and args.len == 0) return .info;
    if (std.mem.eql(u8, name, "outline") and args.len == 0) return .outline;
    if (std.mem.eql(u8, name, "text") and args.len <= 1)
        return .{ .text = if (args.len == 1) try pageIndex(args[0]) else 0 };
    if (std.mem.eql(u8, name, "annotations") and args.len <= 1)
        return .{ .annotations = if (args.len == 1) try pageIndex(args[0]) else 0 };
    if (std.mem.eql(u8, name, "resolve-link") and args.len >= 1 and args.len <= 2) {
        return .{ .resolve_link = .{
            .href = args[0],
            .origin = if (args.len == 2) try pageIndex(args[1]) else null,
        } };
    }

    const thumbnail = std.mem.eql(u8, name, "thumbnail");
    const fit = std.mem.eql(u8, name, "fit");
    const region = std.mem.eql(u8, name, "region");
    const valid = (std.mem.eql(u8, name, "render") and args.len >= 1 and args.len <= 4) or
        (fit and args.len >= 4 and args.len <= 5) or
        (region and args.len == 8) or
        (thumbnail and args.len >= 1 and args.len <= 2);
    if (!valid) return error.InvalidArgument;
    const page = if (args.len >= 2) try pageIndex(args[1]) else 0;
    const rotation_arg: usize = if (fit) 4 else 3;
    return .{ .render = .{
        .output = args[0],
        .page = page,
        .thumbnail = thumbnail,
        .options = .{
            .subsample = if (!fit and args.len >= 3) try std.fmt.parseInt(u16, args[2], 10) else 1,
            .rotation = if (args.len > rotation_arg) try std.fmt.parseInt(u2, args[rotation_arg], 10) else 0,
            .size = if (fit) .{
                .width = try std.fmt.parseInt(u32, args[2], 10),
                .height = try std.fmt.parseInt(u32, args[3], 10),
            } else null,
            .region = if (region) .{
                .x = try std.fmt.parseInt(u32, args[4], 10),
                .y = try std.fmt.parseInt(u32, args[5], 10),
                .width = try std.fmt.parseInt(u32, args[6], 10),
                .height = try std.fmt.parseInt(u32, args[7], 10),
            } else null,
        },
    } };
}

fn openDocument(io: std.Io, input: std.Io.File, allocator: std.mem.Allocator) !djvu.Document {
    const size = std.math.cast(u32, try input.length(io)) orelse return error.LimitExceeded;
    var source = try djvu.DocumentSource.init(allocator, size, .{});
    defer source.deinit();
    while (try source.nextRange()) |range| {
        const bytes = try readRange(io, input, allocator, range);
        defer allocator.free(bytes);
        try source.provide(bytes);
    }
    return source.finish();
}

fn writeTextJson(w: *std.Io.Writer, text: *const djvu.PageText, allocator: std.mem.Allocator) !void {
    const display = try text.toUtf8(allocator);
    defer allocator.free(display);
    try w.writeAll("{\"text\":");
    try std.json.Stringify.value(display, .{}, w);
    try w.writeAll(",\"bytes\":");
    if (text.has_replacements) {
        try std.json.Stringify.value(text.bytes, .{ .emit_strings_as_arrays = true }, w);
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"hasReplacements\":");
    try std.json.Stringify.value(text.has_replacements, .{}, w);
    try w.writeAll(",\"zones\":[");
    for (text.zones, 0..) |zone, i| {
        if (i != 0) try w.writeAll(",");
        try std.json.Stringify.value(.{
            .type = @tagName(zone.kind),
            .parent = if (zone.parent == djvu.no_parent) @as(?u32, null) else zone.parent,
            .x = zone.bounds.x,
            .y = zone.bounds.y,
            .width = zone.bounds.width,
            .height = zone.bounds.height,
            .start = zone.text_start,
            .length = zone.text_length,
            .subtreeEnd = zone.subtree_end,
        }, .{}, w);
    }
    try w.writeAll("]}\n");
}

fn renderToFile(
    io: std.Io,
    doc: *djvu.Document,
    command: RenderCommand,
    budget: *const djvu.Budget,
    w: *std.Io.Writer,
) !void {
    var job = if (command.thumbnail) (try djvu.RenderJob.initThumbnail(doc, command.page)) orelse {
        try w.writeAll("null\n");
        return;
    } else try djvu.RenderJob.init(doc, command.page, command.options);
    defer job.deinit();
    var steps: usize = 0;
    while (try job.step(4096) != .done) {
        steps += 1;
    }
    const rgba = try job.pixels();
    const geometry = try job.geometry();
    try writePpm(io, command.output, doc.allocator, rgba, geometry);
    try std.json.Stringify.value(.{
        .x = geometry.x,
        .y = geometry.y,
        .width = geometry.width,
        .height = geometry.height,
        .page_width = geometry.page_width,
        .page_height = geometry.page_height,
        .steps = steps + 1,
        .peak_bytes = budget.peak,
        .dictionary_decodes = doc.dictionary_decodes,
    }, .{}, w);
    try w.writeAll("\n");
}

fn writePpm(
    io: std.Io,
    path: []const u8,
    allocator: std.mem.Allocator,
    rgba: []const u8,
    geometry: djvu.RenderGeometry,
) !void {
    const header = try std.fmt.allocPrint(allocator, "P6\n{d} {d}\n255\n", .{ geometry.width, geometry.height });
    defer allocator.free(header);
    const ppm = try allocator.alloc(u8, header.len + rgba.len / 4 * 3);
    defer allocator.free(ppm);
    @memcpy(ppm[0..header.len], header);
    for (0..rgba.len / 4) |i| @memcpy(ppm[header.len + i * 3 ..][0..3], rgba[i * 4 ..][0..3]);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = ppm });
}

fn readRange(io: std.Io, file: std.Io.File, allocator: std.mem.Allocator, range: djvu.ByteRange) ![]u8 {
    const bytes = try allocator.alloc(u8, range.length);
    errdefer allocator.free(bytes);
    if (try file.readPositionalAll(io, bytes, range.offset) != bytes.len) return error.UnexpectedEof;
    return bytes;
}

fn prepare(
    io: std.Io,
    doc: *djvu.Document,
    input: std.Io.File,
    path: []const u8,
    page: usize,
    scope: djvu.Document.Scope,
) !void {
    var missing = try doc.nextMissing(page, scope);
    if (missing == null) return;
    var dir = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(path) orelse ".", .{});
    defer dir.close(io);
    while (missing) |index| : (missing = try doc.nextMissing(page, scope)) {
        if (doc.components.items[index].range) |range| {
            if (range.length > doc.limits.max_input_bytes - doc.bytes.len - doc.suppliedBytes()) return error.LimitExceeded;
            const bytes = try readRange(io, input, doc.allocator, range);
            doc.provideComponent(index, bytes) catch |err| {
                doc.allocator.free(bytes);
                return err;
            };
            continue;
        }
        const name = doc.components.items[index].name;
        // Component names are data: the CLI reads sibling files, never paths or links.
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
            std.mem.indexOfAny(u8, name, "/\\:\x00") != null)
        {
            return error.InvalidComponentName;
        }
        if ((try dir.statFile(io, name, .{ .follow_symlinks = false })).kind != .file) return error.InvalidComponentFile;
        const file = try dir.openFile(io, name, .{ .follow_symlinks = false });
        defer file.close(io);
        if ((try file.stat(io)).kind != .file) return error.InvalidComponentFile;
        var reader = file.reader(io, &.{});
        const remaining = doc.limits.max_input_bytes - doc.bytes.len - doc.suppliedBytes();
        const bytes = try reader.interface.allocRemaining(doc.allocator, .limited(remaining));
        doc.provideComponent(index, bytes) catch |err| {
            doc.allocator.free(bytes);
            return err;
        };
    }
}
