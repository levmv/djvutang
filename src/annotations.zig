//! ANTa/ANTz syntax and annotation data (DjVu 3 section 8.3.4, with extensions).
const std = @import("std");
const types = @import("types.zig");
const Error = types.Error;
const geometry = @import("geometry.zig");
const Info = @import("iff.zig").Info;
const utf8 = @import("utf8.zig");

pub const Span = struct { start: u32, length: u32 };
pub const Chunk = struct { component: u32, start: u32, length: u32 };
pub const Metadata = struct { key: []const u8, value: []const u8, expression: u32 };
pub const Alignment = struct { horizontal: []const u8, vertical: []const u8 };
pub const View = struct {
    background: ?u32 = null,
    zoom: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    alignment: ?Alignment = null,
};
pub const PrintStrings = struct { left: ?[]const u8 = null, center: ?[]const u8 = null, right: ?[]const u8 = null };
pub const Shape = enum { rect, oval, text, poly, line };
pub const Border = struct {
    kind: enum { none, xor, solid, shadow_in, shadow_out, shadow_ein, shadow_eout },
    color: ?u32 = null,
    width: ?u32 = null,
};
/// Optional values preserve absence; colors are 0xRRGGBB, opacity is the DjVu
/// value (0..200), not a normalized alpha. Unknown options remain in source.
pub const Style = struct {
    border: ?Border = null,
    always_visible: bool = false,
    highlight: ?u32 = null,
    opacity: ?u8 = null,
    arrow: bool = false,
    line_width: ?u32 = null,
    line_color: ?u32 = null,
    background: ?u32 = null,
    text_color: ?u32 = null,
    pushpin: bool = false,

    pub fn jsonStringify(self: *const Style, stream: *std.json.Stringify) std.Io.Writer.Error!void {
        try stream.write(.{
            .border = self.border,
            .alwaysVisible = self.always_visible,
            .highlight = self.highlight,
            .opacity = self.opacity,
            .arrow = self.arrow,
            .lineWidth = self.line_width,
            .lineColor = self.line_color,
            .background = self.background,
            .textColor = self.text_color,
            .pushpin = self.pushpin,
        });
    }
};
/// Bounds/points are unrotated INFO pixels, top-left, matching PageTransform.
/// The source expression retains the original rotated, bottom-left coordinates.
pub const Area = struct {
    expression: u32,
    href: []const u8,
    target: ?[]const u8,
    comment: []const u8,
    shape: Shape,
    bounds: geometry.Rect,
    points: []const geometry.Point,
    style: Style,
};

pub const Annotations = struct {
    arena: std.heap.ArenaAllocator,
    bytes: []const u8,
    source: []const u8,
    has_replacements: bool,
    legacy_escapes: bool,
    chunks: []const Chunk = &.{},
    expressions: []const Span,
    view: View = .{},
    areas: []const Area,
    metadata: []const Metadata,
    xmp: ?[]const u8 = null,
    header: PrintStrings = .{},
    footer: PrintStrings = .{},

    pub fn deinit(self: *Annotations) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Entries stay in source order; the last valid entry for a key wins.
    pub fn metadataValue(self: *const Annotations, key: []const u8) ?[]const u8 {
        var i = self.metadata.len;
        while (i != 0) {
            i -= 1;
            if (eq(self.metadata[i].key, key)) return self.metadata[i].value;
        }
        return null;
    }

    pub fn jsonStringify(self: *const Annotations, stream: *std.json.Stringify) std.Io.Writer.Error!void {
        try stream.write(.{
            .source = self.source,
            .bytes = utf8.JsonBytes{ .bytes = if (self.source.ptr != self.bytes.ptr) self.bytes else null },
            .hasReplacements = self.has_replacements,
            .legacyEscapes = self.legacy_escapes,
            .chunks = self.chunks,
            .expressions = self.expressions,
            .view = self.view,
            .areas = self.areas,
            .metadata = self.metadata,
            .xmp = self.xmp,
            .header = self.header,
            .footer = self.footer,
        });
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, info: Info, limits: types.Limits) Error!Annotations {
        if (bytes.len > @min(limits.max_annotation_bytes, std.math.maxInt(u32))) return error.LimitExceeded;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const source = try a.dupe(u8, bytes);
        const legacy = legacyStrings(source);
        var parser: Parser = .{ .allocator = a, .source = source, .legacy = legacy, .limits = limits };
        try parser.parse();
        const valid_source = std.unicode.utf8ValidateSlice(source);
        var result: Annotations = .{
            // The parser's allocator points at the local arena. Move the arena
            // into the result only after the last allocation has finished.
            .arena = undefined,
            .bytes = source,
            .source = if (valid_source) source else try utf8.toUtf8(a, source),
            .has_replacements = !valid_source or parser.has_replacements,
            .legacy_escapes = legacy,
            .expressions = &.{},
            .areas = &.{},
            .metadata = &.{},
        };
        var spans: std.ArrayList(Span) = .empty;
        var areas: std.ArrayList(Area) = .empty;
        var metadata: std.ArrayList(Metadata) = .empty;
        const transform = try geometry.Transform.init(info, .{});
        var i: usize = 0;
        while (i < parser.nodes.items.len) : (i = parser.nodes.items[i].subtree_end) {
            const node = parser.nodes.items[i];
            const expression: u32 = @intCast(spans.items.len);
            try spans.append(a, .{ .start = node.start, .length = node.finish - node.start });
            var children = parser.children(i);
            const head = children.next() orelse continue;
            const name = parser.symbol(head) orelse continue;
            const arg = children.next() orelse continue;
            if (eq(name, "maparea")) {
                if (try parser.area(i, expression, transform)) |area| try areas.append(a, area);
            } else if (eq(name, "metadata")) {
                var entries = parser.children(i);
                _ = entries.next();
                while (entries.next()) |entry| {
                    if (parser.metadataEntry(entry)) |field| {
                        try metadata.append(a, .{ .key = field.key, .value = field.value, .expression = expression });
                    }
                }
            } else if (eq(name, "phead") or eq(name, "pfoot")) {
                const print = if (eq(name, "phead")) &result.header else &result.footer;
                var entries = parser.children(i);
                _ = entries.next();
                while (entries.next()) |entry| {
                    const value = parser.string(entry) orelse continue;
                    inline for (.{ "left", "center", "right" }) |field| {
                        if (std.mem.startsWith(u8, value, field ++ "::")) @field(print, field) = value[field.len + 2 ..];
                    }
                }
            } else if (eq(name, "align")) {
                const horizontal = parser.symbol(arg) orelse continue;
                const vertical = parser.symbol(children.next()) orelse continue;
                if (children.next() == null and
                    oneOf(horizontal, &.{ "left", "center", "right", "default" }) and
                    oneOf(vertical, &.{ "top", "center", "bottom", "default" }))
                {
                    result.view.alignment = .{ .horizontal = horizontal, .vertical = vertical };
                }
            } else if (children.next() == null) {
                if (eq(name, "xmp")) {
                    if (parser.string(arg)) |value| result.xmp = value;
                } else if (eq(name, "background")) {
                    if (parser.color(arg)) |value| result.view.background = value;
                } else if (parser.symbol(arg)) |value| {
                    if (eq(name, "zoom") and validZoom(value)) result.view.zoom = value;
                    if (eq(name, "mode") and oneOf(value, &.{ "color", "bw", "fore", "back" })) result.view.mode = value;
                }
            }
        }
        result.expressions = try spans.toOwnedSlice(a);
        result.areas = try areas.toOwnedSlice(a);
        result.metadata = try metadata.toOwnedSlice(a);
        result.arena = arena;
        return result;
    }
};

/// Metadata-only interpretation of the same ordered annotation stream. No INFO,
/// image geometry or maparea construction is needed. Spans address input bytes.
/// Keys borrow those bytes; keep them alive until deinit.
pub const Fields = struct {
    pub const Entry = struct { key: []const u8, value: []const u8, span: Span };
    pub const Xmp = struct { value: []const u8, span: Span };
    arena: std.heap.ArenaAllocator,
    metadata: []const Entry,
    xmp: []const Xmp,

    pub fn deinit(self: *Fields) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, limits: types.Limits) Error!Fields {
        if (bytes.len > @min(limits.max_annotation_bytes, std.math.maxInt(u32))) return error.LimitExceeded;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var parser: Parser = .{ .allocator = a, .source = bytes, .legacy = legacyStrings(bytes), .limits = limits };
        try parser.parse();
        var metadata: std.ArrayList(Entry) = .empty;
        var xmp: std.ArrayList(Xmp) = .empty;
        var i: usize = 0;
        while (i < parser.nodes.items.len) : (i = parser.nodes.items[i].subtree_end) {
            var children = parser.children(i);
            const name = parser.symbol(children.next()) orelse continue;
            if (eq(name, "metadata")) {
                while (children.next()) |entry| {
                    if (parser.metadataEntry(entry)) |field| try metadata.append(a, field);
                }
            } else if (eq(name, "xmp")) {
                const value = parser.string(children.next()) orelse continue;
                if (children.next() == null) {
                    const node = parser.nodes.items[i];
                    try xmp.append(a, .{ .value = value, .span = .{ .start = node.start, .length = node.finish - node.start } });
                }
            }
        }
        const entries = try metadata.toOwnedSlice(a);
        const packets = try xmp.toOwnedSlice(a);
        return .{ .arena = arena, .metadata = entries, .xmp = packets };
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn oneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (eq(value, choice)) return true;
    return false;
}

fn validZoom(value: []const u8) bool {
    if (oneOf(value, &.{ "stretch", "one2one", "width", "page" })) return true;
    if (value.len < 2 or value[0] != 'd') return false;
    for (value[1..]) |c| if (!std.ascii.isDigit(c)) return false;
    const n = std.fmt.parseInt(u16, value[1..], 10) catch return false;
    return n >= 1 and n <= 999;
}

fn escape(c: u8) ?u8 {
    return switch (c) {
        'a' => 7,
        'b' => 8,
        't' => 9,
        'n' => 10,
        'v' => 11,
        'f' => 12,
        'r' => 13,
        '\\', '"' => c,
        else => null,
    };
}

fn octal(c: u8) bool {
    return c >= '0' and c <= '7';
}

// An invalid modern escape selects quote-only escaping for the whole stream.
fn legacyStrings(bytes: []const u8) bool {
    var quoted = false;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c == '"') {
            quoted = !quoted;
            continue;
        }
        if (!quoted or c != '\\') continue;
        i += 1;
        if (i == bytes.len) return false;
        if (escape(bytes[i]) != null) continue;
        if (!octal(bytes[i])) return true;
        var value: u16 = bytes[i] - '0';
        var count: usize = 1;
        while (count < 3 and i + 1 < bytes.len and octal(bytes[i + 1])) : (count += 1) {
            i += 1;
            value = value * 8 + bytes[i] - '0';
        }
        if (value > 255) return true;
    }
    return false;
}

const Node = struct {
    kind: enum { list, symbol, string },
    value: []const u8 = "",
    has_replacements: bool = false,
    start: u32,
    finish: u32,
    /// Exclusive preorder node index; start/finish above are source byte offsets.
    subtree_end: usize,
};
const Children = struct {
    nodes: []const Node,
    pos: usize,
    end: usize,

    fn next(self: *Children) ?usize {
        if (self.pos >= self.end) return null;
        const index = self.pos;
        self.pos = self.nodes[index].subtree_end;
        return index;
    }
};
const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    legacy: bool,
    limits: types.Limits,
    nodes: std.ArrayList(Node) = .empty,
    has_replacements: bool = false,

    fn parse(self: *Parser) Error!void {
        var stack: [64]usize = undefined;
        var depth: usize = 0;
        var p: usize = if (std.mem.startsWith(u8, self.source, "\xef\xbb\xbf")) 3 else 0;
        while (p < self.source.len) {
            const c = self.source[p];
            if (std.ascii.isWhitespace(c)) {
                p += 1;
                continue;
            }
            if (c == ')') {
                if (depth == 0) return error.InvalidData;
                depth -= 1;
                const node = &self.nodes.items[stack[depth]];
                node.subtree_end = self.nodes.items.len;
                node.finish = @intCast(p + 1);
                p += 1;
                continue;
            }
            if (self.nodes.items.len >= self.limits.max_annotation_nodes) return error.LimitExceeded;
            const index = self.nodes.items.len;
            const start = p;
            p += 1;
            var node: Node = .{ .kind = .symbol, .start = @intCast(start), .finish = 0, .subtree_end = index + 1 };
            if (c == '(') {
                if (depth >= @min(stack.len, self.limits.max_annotation_depth)) return error.LimitExceeded;
                stack[depth] = index;
                depth += 1;
                node.kind = .list;
            } else if (c == '"') {
                const parsed = try self.readString(p);
                p = parsed.end;
                node.kind = .string;
                node.value = parsed.value;
                node.has_replacements = parsed.has_replacements;
                self.has_replacements = self.has_replacements or parsed.has_replacements;
            } else {
                while (p < self.source.len and !std.ascii.isWhitespace(self.source[p]) and
                    self.source[p] != '(' and self.source[p] != ')' and self.source[p] != '"') : (p += 1)
                {}
                node.value = self.source[start..p];
                node.has_replacements = !std.unicode.utf8ValidateSlice(node.value);
            }
            node.finish = @intCast(p);
            try self.nodes.append(self.allocator, node);
        }
        if (depth != 0) return error.InvalidData;
    }
    const ParsedString = struct { value: []const u8, end: usize, has_replacements: bool };

    /// start follows the opening quote; end follows the closing quote.
    fn readString(self: *const Parser, start: usize) Error!ParsedString {
        var p = start;
        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(self.allocator);
        while (p < self.source.len and self.source[p] != '"') {
            var ch = self.source[p];
            p += 1;
            if (ch == '\\') {
                if (p == self.source.len) return error.InvalidData;
                if (self.legacy) {
                    if (self.source[p] == '"') {
                        ch = '"';
                        p += 1;
                    }
                } else if (escape(self.source[p])) |value| {
                    ch = value;
                    p += 1;
                } else {
                    var value: u16 = 0;
                    var count: usize = 0;
                    while (count < 3 and p < self.source.len and octal(self.source[p])) : (count += 1) {
                        value = value * 8 + self.source[p] - '0';
                        p += 1;
                    }
                    if (count == 0 or value > 255) return error.InvalidData;
                    ch = @intCast(value);
                }
            }
            try decoded.append(self.allocator, ch);
        }
        if (p == self.source.len) return error.InvalidData;
        const original = try decoded.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(original);
        if (std.unicode.utf8ValidateSlice(original))
            return .{ .value = original, .end = p + 1, .has_replacements = false };
        const repaired = try utf8.toUtf8(self.allocator, original);
        self.allocator.free(original);
        return .{ .value = repaired, .end = p + 1, .has_replacements = true };
    }

    fn children(self: *const Parser, index: usize) Children {
        const node = self.nodes.items[index];
        return .{ .nodes = self.nodes.items, .pos = index + 1, .end = if (node.kind == .list) node.subtree_end else index + 1 };
    }

    fn symbol(self: *const Parser, index: ?usize) ?[]const u8 {
        const node = self.nodes.items[index orelse return null];
        return if (node.kind == .symbol and !node.has_replacements) node.value else null;
    }

    fn string(self: *const Parser, index: ?usize) ?[]const u8 {
        const node = self.nodes.items[index orelse return null];
        return if (node.kind == .string) node.value else null;
    }

    fn metadataEntry(self: *const Parser, index: usize) ?Fields.Entry {
        var pair = self.children(index);
        const key = self.symbol(pair.next()) orelse return null;
        const value = self.string(pair.next()) orelse return null;
        if (pair.next() != null) return null;
        const node = self.nodes.items[index];
        return .{ .key = key, .value = value, .span = .{ .start = node.start, .length = node.finish - node.start } };
    }

    // A repaired identifier could point to a different destination. Keep the
    // original expression, but do not publish it as an actionable link.
    fn exactString(self: *const Parser, index: ?usize) ?[]const u8 {
        const node = self.nodes.items[index orelse return null];
        return if (node.kind == .string and !node.has_replacements) node.value else null;
    }

    fn integer(self: *const Parser, index: ?usize) ?i32 {
        const value = self.symbol(index) orelse return null;
        if (value.len == 0) return null;
        const digits = if (value[0] == '+' or value[0] == '-') value[1..] else value;
        if (digits.len == 0) return null;
        for (digits) |c| if (!std.ascii.isDigit(c)) return null;
        return std.fmt.parseInt(i32, value, 10) catch null;
    }

    fn color(self: *const Parser, index: ?usize) ?u32 {
        const value = self.symbol(index) orelse return null;
        if (value.len != 7 or value[0] != '#') return null;
        for (value[1..]) |c| if (!std.ascii.isHex(c)) return null;
        return std.fmt.parseInt(u32, value[1..], 16) catch null;
    }

    fn area(self: *const Parser, index: usize, expression: u32, transform: geometry.Transform) Error!?Area {
        var args = self.children(index);
        _ = args.next();
        const url = args.next() orelse return null;
        var target: ?[]const u8 = null;
        const href = self.exactString(url) orelse blk: {
            var parts = self.children(url);
            if (!eq(self.symbol(parts.next()) orelse return null, "url")) return null;
            const value = self.exactString(parts.next()) orelse return null;
            target = self.exactString(parts.next()) orelse return null;
            if (parts.next() != null) return null;
            break :blk value;
        };
        const comment = self.string(args.next()) orelse return null;
        var shape = self.children(args.next() orelse return null);
        const kind = std.meta.stringToEnum(Shape, self.symbol(shape.next()) orelse return null) orelse return null;
        var points: std.ArrayList(geometry.Point) = .empty;
        while (shape.next()) |x_node| {
            const x = self.integer(x_node) orelse return null;
            const y = self.integer(shape.next()) orelse return null;
            try points.append(self.allocator, .{ .x = @floatFromInt(x), .y = @floatFromInt(y) });
        }
        if (kind == .poly) {
            if (points.items.len < 3) return null;
        } else if (points.items.len != 2) return null;
        if (kind != .poly and kind != .line) {
            if (points.items[1].x < 0 or points.items[1].y < 0) return null;
            points.items[1].x += points.items[0].x;
            points.items[1].y += points.items[0].y;
        }
        const page_height: f64 = @floatFromInt(transform.geometry.page_height);
        for (points.items) |*p| {
            p.* = transform.unmap(.{ .x = p.x, .y = page_height - p.y });
        }
        var lo = points.items[0];
        var hi = lo;
        for (points.items[1..]) |p| {
            lo.x = @min(lo.x, p.x);
            lo.y = @min(lo.y, p.y);
            hi.x = @max(hi.x, p.x);
            hi.y = @max(hi.y, p.y);
        }
        var style: Style = .{};
        while (args.next()) |option| self.styleOption(option, &style);
        return .{
            .expression = expression,
            .href = href,
            .target = target,
            .comment = comment,
            .shape = kind,
            .bounds = .{ .x = lo.x, .y = lo.y, .width = hi.x - lo.x, .height = hi.y - lo.y },
            .points = if (kind == .poly or kind == .line) try points.toOwnedSlice(self.allocator) else &.{},
            .style = style,
        };
    }

    fn styleOption(self: *const Parser, index: usize, style: *Style) void {
        var args = self.children(index);
        const name = self.symbol(args.next()) orelse return;
        const value = args.next();
        if (args.next() != null) return;
        if (value == null) {
            if (eq(name, "none")) style.border = .{ .kind = .none };
            if (eq(name, "xor")) style.border = .{ .kind = .xor };
            if (eq(name, "border_avis")) style.always_visible = true;
            if (eq(name, "arrow")) style.arrow = true;
            if (eq(name, "pushpin")) style.pushpin = true;
        }
        if (self.color(value)) |c| {
            if (eq(name, "border")) style.border = .{ .kind = .solid, .color = c, .width = 1 };
            if (eq(name, "hilite")) style.highlight = c;
            if (eq(name, "lineclr")) style.line_color = c;
            if (eq(name, "backclr")) style.background = c;
            if (eq(name, "textclr")) style.text_color = c;
        }
        if (self.integer(value)) |n| {
            if (eq(name, "opacity") and n >= 0 and n <= 200) style.opacity = @intCast(n);
            if (eq(name, "width") and n >= 1) style.line_width = @intCast(n);
        }
        inline for (.{ "shadow_in", "shadow_out", "shadow_ein", "shadow_eout" }) |field| {
            if (eq(name, field)) {
                const n = if (value == null) @as(?i32, null) else self.integer(value) orelse return;
                if (n == null or (n.? >= 1 and n.? <= 32)) {
                    style.border = .{
                        .kind = @field(@FieldType(Border, "kind"), field),
                        .width = if (n) |w| @intCast(w) else null,
                    };
                }
            }
        }
    }
};
