//! DjVu page references: ID, relative number, title, absolute number, name.
//! URLs and viewer options stay opaque; the host controls navigation.
const std = @import("std");
const Document = @import("document.zig").Document;
const Error = @import("types.zig").Error;

pub const Kind = enum(u32) { none, page, url, options, unresolved };
pub const Link = struct { kind: Kind, page: ?u32 = null };

pub fn resolve(doc: *const Document, href: []const u8, from_page: ?usize) Error!Link {
    if (from_page) |page| if (page >= doc.pageCount()) return error.InvalidArgument;
    if (href.len > doc.limits.max_input_bytes) return error.LimitExceeded;
    if (!std.unicode.utf8ValidateSlice(href)) return error.InvalidArgument;
    if (href.len == 0) return .{ .kind = .none };
    if (href[0] == '?') return .{ .kind = .options };
    if (href[0] != '#') return .{ .kind = .url };
    const id = href[1..];
    const missing: Link = .{ .kind = .unresolved };
    if (id.len == 0) return missing;
    // IDs precede numeric syntax: an ID such as "+1" is not a relative link.
    // Only page components can be navigation targets.
    if (doc.id_index.get(id)) |component| {
        if (doc.components.items[component].kind == .page) {
            for (doc.pages.items, 0..) |candidate, page| if (candidate == component) return found(page);
        }
    }
    if ((id[0] == '+' or id[0] == '-') and decimal(id[1..])) {
        const origin = from_page orelse return missing;
        const distance = std.fmt.parseInt(usize, id[1..], 10) catch return missing;
        if (id[0] == '-') return if (distance <= origin) found(origin - distance) else missing;
        return if (distance < doc.pageCount() - origin) found(origin + distance) else missing;
    }
    // Duplicate titles are conventional: search from the current page and wrap.
    const start = from_page orelse 0;
    for (0..doc.pageCount()) |offset| {
        const page = (start + offset) % doc.pageCount();
        if (std.mem.eql(u8, id, doc.components.items[doc.pages.items[page]].title)) return found(page);
    }
    if (decimal(id)) {
        if (std.fmt.parseInt(usize, id, 10)) |page| {
            if (page != 0 and page <= doc.pageCount()) return found(page - 1);
        } else |_| {}
    }
    // Unlike titles, duplicate file names do not define an order for choosing
    // a page. Resolve only a unique match rather than inventing that order.
    var named: ?usize = null;
    for (doc.pages.items, 0..) |component, page| {
        if (!std.mem.eql(u8, id, doc.components.items[component].name)) continue;
        if (named != null) return missing;
        named = page;
    }
    return if (named) |page| found(page) else missing;
}

fn found(page: usize) Link {
    return .{ .kind = .page, .page = @intCast(page) };
}

fn decimal(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}
