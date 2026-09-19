const std = @import("std");
const iff = @import("iff.zig");
const bzz = @import("bzz.zig");
const component_module = @import("component.zig");
const iw44 = @import("iw44.zig");
const geometry_module = @import("geometry.zig");
const Text = @import("text.zig").Text;
const annotation = @import("annotations.zig");
const Outline = @import("outline.zig").Outline;
const links = @import("links.zig");
const types = @import("types.zig");
const Error = types.Error;

pub const ByteRange = component_module.ByteRange;
const Forms = std.AutoHashMapUnmanaged(u32, iff.Chunk);

pub const Component = component_module.Component;

// DIRM owns its decoded names and logical component order independently of
// retained container bytes. Range opening can append NAVM without moving them.
const Directory = struct {
    components: std.ArrayList(Component) = .empty,
    pages: std.ArrayList(usize) = .empty,
    names: []u8 = &.{},
    id_index: std.StringHashMapUnmanaged(usize) = .empty,
    indirect: bool = false,

    fn deinit(self: *Directory, allocator: std.mem.Allocator) void {
        self.components.deinit(allocator);
        self.pages.deinit(allocator);
        self.id_index.deinit(allocator);
        allocator.free(self.names);
    }

    fn parse(allocator: std.mem.Allocator, bytes: []const u8, limits: types.Limits, physical: ?*const Forms) Error!Directory {
        var self: Directory = .{};
        errdefer self.deinit(allocator);
        var r: iff.Reader = .{ .bytes = bytes };
        const version = try r.byte();
        if (version & 0x7f > 1) return error.Unsupported;
        self.indirect = version & 0x80 == 0;
        if (physical) |locations| {
            if (self.indirect and locations.count() != 0) return error.InvalidData;
        }
        const n: usize = try r.uint(2);
        if (n > limits.max_components) return error.LimitExceeded;
        const offsets = try allocator.alloc(u32, n);
        defer allocator.free(offsets);
        const sizes = try allocator.alloc(u32, n);
        defer allocator.free(sizes);
        for (offsets, sizes) |*offset, *size| {
            offset.* = if (self.indirect) 0 else try r.uint(4);
            size.* = if (!self.indirect and version & 0x7f == 0) try r.uint(3) else 0;
        }
        self.names = try bzz.decode(allocator, r.bytes[r.pos..], limits.max_bzz_bytes);
        r = .{ .bytes = self.names };
        if (version & 0x7f != 0) {
            for (sizes) |*size| size.* = try r.uint(3);
        }
        const flags = try r.take(n);
        for (offsets, sizes, flags) |offset, size, flag| {
            const id = try r.string();
            const name = if (flag & 0x80 != 0) try r.string() else id;
            const title = if (flag & 0x40 != 0) try r.string() else id;
            if (id.len == 0) return error.InvalidData;
            const entry = try self.id_index.getOrPut(allocator, id);
            if (entry.found_existing) return error.InvalidData;
            entry.value_ptr.* = self.components.items.len;
            const form: ?iff.Chunk = if (self.indirect or physical == null)
                null
            else
                physical.?.get(offset) orelse return error.InvalidData;
            const kind = std.enums.fromInt(Component.Kind, flag & 0x3f) orelse return error.Unsupported;
            if (form) |f| {
                if (size != 0 and size != f.data.len + 8) return error.InvalidData;
                if (!iff.tag(try f.formType(), kind.formType())) return error.InvalidData;
            }
            if (kind == .page) try self.pages.append(allocator, self.components.items.len);
            try self.components.append(allocator, .{
                .id = id,
                .name = name,
                .title = title,
                .kind = kind,
                .size = size,
                .form = form,
                .range = if (self.indirect or form != null) null else .{ .offset = offset, .length = size },
            });
        }
        if (r.pos != r.bytes.len) return error.InvalidData;
        return self;
    }
};

/// Opens an immutable file through exact byte-range requests. Keeps DIRM/NAVM;
/// indexed FORM headers are checked when components are supplied to Document.
/// Zero DIRM sizes require header reads; gaps are scanned for late metadata.
/// DJVU pages retain NAVM only; standalone IW44/THUM are read whole.
/// Always deinit, including after finish/error.
pub const DocumentSource = struct {
    const Location = struct { kind: [4]u8, length: u32 };

    allocator: std.mem.Allocator,
    limits: types.Limits,
    size: u32,
    stage: enum { header, chunk, metadata, whole, done, failed, taken } = .header,
    request: ByteRange,
    index: std.ArrayList(u8) = .empty,
    directory: ?Directory = null,
    locations: std.AutoHashMapUnmanaged(u32, Location) = .empty,
    bundled_container: bool = false,
    single_page: bool = false,
    root_end: u32 = 0,
    cursor: u32 = 16,
    chunk_end: u32 = 0,
    chunks: usize = 0,
    forms: usize = 0,
    visited: usize = 0,

    pub fn init(allocator: std.mem.Allocator, size: u32, limits: types.Limits) Error!DocumentSource {
        if (size < 12) return error.InvalidData;
        if (limits.max_input_bytes < @min(size, 16)) return error.LimitExceeded;
        return .{
            .allocator = allocator,
            .size = size,
            .limits = limits,
            .request = .{ .offset = 0, .length = @min(size, 16) },
        };
    }

    pub fn deinit(self: *DocumentSource) void {
        if (self.directory) |*directory| directory.deinit(self.allocator);
        self.index.deinit(self.allocator);
        self.locations.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn nextRange(self: *const DocumentSource) Error!?ByteRange {
        return switch (self.stage) {
            .done => null,
            .failed, .taken => error.InvalidArgument,
            else => self.request,
        };
    }

    /// Borrows bytes only for this call. An error ends this opening attempt.
    pub fn provide(self: *DocumentSource, bytes: []const u8) Error!void {
        errdefer self.stage = .failed;
        const range = (try self.nextRange()) orelse return error.InvalidArgument;
        if (bytes.len != range.length) return error.InvalidData;
        switch (self.stage) {
            .header => {
                const start: usize = if (iff.tag(bytes[0..4], "AT&T")) 4 else 0;
                if (bytes.len < start + 12 or !iff.tag(bytes[start..][0..4], "FORM")) return error.InvalidData;
                const length = std.mem.readInt(u32, bytes[start + 4 ..][0..4], .big);
                const end = @as(u64, start) + 8 + length;
                if (length < 4 or end > self.size) return error.InvalidData;
                const has_final_padding = length & 1 != 0 and end + 1 == self.size;
                if (end != self.size and !has_final_padding) return error.InvalidData;
                const kind = bytes[start + 8 ..][0..4];
                if (start == 0 and !iff.isIw44(kind)) return error.InvalidData;
                self.bundled_container = iff.tag(kind, "DJVM");
                self.single_page = iff.tag(kind, "DJVU");
                if (!self.bundled_container and !iff.tag(kind, "DJVU") and
                    !iff.tag(kind, "THUM") and !iff.isIw44(kind))
                {
                    return error.Unsupported;
                }
                try self.append(bytes);
                if (self.bundled_container or self.single_page) {
                    self.root_end = @intCast(end);
                    try self.nextChunk();
                } else {
                    if (self.size > self.limits.max_input_bytes) return error.LimitExceeded;
                    self.stage = if (self.size == bytes.len) .done else .whole;
                    self.request = .{
                        .offset = @intCast(bytes.len),
                        .length = self.size - @as(u32, @intCast(bytes.len)),
                    };
                }
            },
            .whole => {
                try self.append(bytes);
                self.stage = .done;
            },
            .chunk => {
                const length = std.mem.readInt(u32, bytes[4..8], .big);
                const end = @as(u64, self.cursor) + 8 + length;
                if (end > self.root_end) return error.InvalidData;
                self.chunk_end = @intCast(end + @intFromBool(length & 1 != 0 and end < self.root_end));
                if (self.bundled_container and self.chunks == 0 and !iff.tag(bytes[0..4], "DIRM")) return error.InvalidData;
                try self.countChunk(iff.tag(bytes[0..4], "FORM"));
                if (self.locations.getPtr(self.cursor)) |location| {
                    // Only zero-sized entries reach this path. Read their size
                    // once; FORM type validation still belongs to component supply.
                    if (!iff.tag(bytes[0..4], "FORM") or length < 4) return error.InvalidData;
                    location.length = length + 8;
                    self.visited += 1;
                    try self.advance();
                } else if ((self.bundled_container and self.chunks == 1) or iff.tag(bytes[0..4], "NAVM")) {
                    try self.append(bytes);
                    const retained_end = @as(u64, self.index.items.len) + length + (length & 1);
                    if (retained_end > self.limits.max_input_bytes) return error.LimitExceeded;
                    self.stage = .metadata;
                    self.request = .{ .offset = self.cursor + 8, .length = length };
                    if (length == 0) {
                        if (self.bundled_container and self.chunks == 1) return error.InvalidData;
                        try self.advance();
                    }
                } else try self.advance();
            },
            .metadata => {
                try self.append(bytes);
                if (bytes.len & 1 != 0) try self.append(&.{0});
                if (self.bundled_container and self.chunks == 1) try self.readDirectory(bytes);
                try self.advance();
            },
            else => unreachable,
        }
    }

    fn append(self: *DocumentSource, bytes: []const u8) Error!void {
        if (bytes.len > self.limits.max_input_bytes - self.index.items.len) return error.LimitExceeded;
        try self.index.appendSlice(self.allocator, bytes);
    }

    fn readDirectory(self: *DocumentSource, bytes: []const u8) Error!void {
        self.directory = try Directory.parse(self.allocator, bytes, self.limits, null);
        for (self.directory.?.components.items) |component| {
            const range = component.range orelse continue;
            // Check in wide arithmetic before any skip or host request. A zero
            // size still needs room for a FORM header and its four-byte type.
            if (range.offset < self.chunk_end or range.offset & 1 != 0 or
                (range.length != 0 and range.length < 12) or
                @as(u64, range.offset) + @max(range.length, 12) > self.root_end)
            {
                return error.InvalidData;
            }
            const entry = try self.locations.getOrPut(self.allocator, range.offset);
            const kind = component.kind.formType();
            if (entry.found_existing) {
                // Distinct IDs may alias one physical FORM, but their known
                // sizes and expected FORM types must agree.
                const location = entry.value_ptr;
                if (!iff.tag(&location.kind, kind) or
                    (location.length != 0 and range.length != 0 and location.length != range.length))
                {
                    return error.InvalidData;
                }
                location.length = @max(location.length, range.length);
            } else entry.value_ptr.* = .{ .kind = kind.*, .length = range.length };
        }
    }

    fn countChunk(self: *DocumentSource, form: bool) Error!void {
        self.chunks += 1;
        if (self.chunks > self.limits.max_chunks) return error.LimitExceeded;
        if (form and self.bundled_container) {
            if (self.directory.?.indirect) return error.InvalidData;
            self.forms += 1;
            if (self.forms > self.limits.max_components) return error.LimitExceeded;
        }
    }

    fn advance(self: *DocumentSource) Error!void {
        self.cursor = self.chunk_end;
        try self.nextChunk();
    }

    fn nextChunk(self: *DocumentSource) Error!void {
        // Walk top-level boundaries using DIRM sizes. Only unindexed gaps and
        // zero-sized entries need IO. Visiting every unique directory offset
        // proves that no entry overlaps another component, metadata or padding.
        while (self.cursor < self.root_end) {
            const location = self.locations.get(self.cursor) orelse break;
            if (location.length == 0) break;
            try self.countChunk(true);
            self.visited += 1;
            self.cursor += location.length;
            if (location.length & 1 != 0 and self.cursor < self.root_end) self.cursor += 1;
        }
        if (self.cursor == self.root_end) {
            if (self.bundled_container) {
                if (self.chunks == 0 or self.visited != self.locations.count()) return error.InvalidData;
                for (self.directory.?.components.items) |*component| {
                    if (component.range) |*range| range.length = self.locations.get(range.offset).?.length;
                }
            }
            self.stage = .done;
            std.mem.writeInt(u32, self.index.items[8..12], @intCast(self.index.items.len - 12), .big);
        } else {
            if (self.root_end - self.cursor < 8) return error.InvalidData;
            self.stage = .chunk;
            self.request = .{ .offset = self.cursor, .length = 8 };
        }
    }

    /// Transfers the retained input to Document. Call once, after nextRange=null.
    pub fn finish(self: *DocumentSource) Error!Document {
        if (self.stage != .done) return error.InvalidArgument;
        const bytes = try self.index.toOwnedSlice(self.allocator);
        self.stage = .taken;
        errdefer self.allocator.free(bytes);
        var doc = if (self.bundled_container) Document{
            .allocator = self.allocator,
            .limits = self.limits,
            .bytes = bytes,
            .container = try iff.root(bytes),
        } else try Document.open(self.allocator, bytes, self.limits);
        if (self.bundled_container) {
            doc.adoptDirectory(self.directory.?);
            self.directory = null;
        } else if (self.single_page) {
            doc.components.items[0].form = null;
            doc.components.items[0].size = self.root_end - 4;
            doc.components.items[0].range = .{ .offset = 4, .length = self.root_end - 4 };
        }
        // The retained index and parsed directory now have one owner.
        doc.owned_input = bytes;
        doc.source_size = self.size;
        return doc;
    }
};

/// Input bytes stay immutable and alive until deinit. Keep the Document address
/// stable while a Job, MetadataScan or Chunks iterator borrows it. Only one Job
/// may live at a time; decoded shared dictionaries are immutable.
pub const Document = struct {
    allocator: std.mem.Allocator,
    limits: types.Limits,
    bytes: []const u8,
    owned_input: ?[]u8 = null,
    source_size: u32 = 0,
    container: iff.Chunk,
    components: std.ArrayList(Component) = .empty,
    pages: std.ArrayList(usize) = .empty,
    // A standalone THUM is an ordered image collection with one physical
    // component. These borrowed chunks have no original document page numbers.
    thumbnail_images: std.ArrayList(iff.Chunk) = .empty,
    names: []u8 = &.{},
    id_index: std.StringHashMapUnmanaged(usize) = .empty,
    busy: bool = false,
    metadata_busy: bool = false,
    dictionary_decodes: usize = 0,
    indirect: bool = false,
    cache: component_module.Cache = .{},
    include_name_bytes: usize = 0,

    pub fn open(allocator: std.mem.Allocator, bytes: []const u8, limits: types.Limits) Error!Document {
        if (bytes.len > limits.max_input_bytes) return error.LimitExceeded;
        const root = try iff.root(bytes);
        var self: Document = .{ .allocator = allocator, .bytes = bytes, .limits = limits, .container = root };
        errdefer self.deinit();
        const kind = try root.formType();
        if (iff.tag(kind, "DJVU") or iff.isIw44(kind)) {
            if (limits.max_components == 0) return error.LimitExceeded;
            try self.components.append(allocator, .{
                .id = "",
                .name = "",
                .title = "",
                .kind = .page,
                .form = root,
            });
            try self.pages.append(allocator, 0);
            if (iff.tag(kind, "DJVU")) try self.discoverIncludes(root);
        } else if (iff.tag(kind, "DJVM")) {
            try self.directory(root);
        } else if (iff.tag(kind, "THUM")) {
            if (limits.max_components == 0) return error.LimitExceeded;
            try self.components.append(allocator, .{
                .id = "",
                .name = "",
                .title = "",
                .kind = .thumbnail,
                .form = root,
            });
            var chunks = try root.children();
            var count: usize = 0;
            while (try chunks.next()) |chunk| {
                count += 1;
                if (count > limits.max_chunks) return error.LimitExceeded;
                if (!iff.tag(chunk.id, "TH44")) continue;
                try self.thumbnail_images.append(allocator, chunk);
                try self.pages.append(allocator, 0);
            }
        } else return error.Unsupported;
        return self;
    }

    pub fn deinit(self: *Document) void {
        std.debug.assert(!self.busy and !self.metadata_busy);
        self.cache.clear(self.allocator, self.components.items);
        for (self.components.items) |component| {
            if (component.owned_id) |id| self.allocator.free(id);
        }
        self.components.deinit(self.allocator);
        self.pages.deinit(self.allocator);
        self.thumbnail_images.deinit(self.allocator);
        self.id_index.deinit(self.allocator);
        self.allocator.free(self.names);
        if (self.owned_input) |bytes| self.allocator.free(bytes);
        self.* = undefined;
    }

    fn directory(self: *Document, root: iff.Chunk) Error!void {
        var iter = try root.children();
        const dir = (try iter.next()) orelse return error.InvalidData;
        if (!iff.tag(dir.id, "DIRM")) return error.InvalidData;
        var physical: Forms = .empty;
        defer physical.deinit(self.allocator);
        var count: usize = 1;
        while (try iter.next()) |chunk| {
            count += 1;
            if (count > self.limits.max_chunks) return error.LimitExceeded;
            if (iff.tag(chunk.id, "FORM")) {
                if (physical.count() >= self.limits.max_components) return error.LimitExceeded;
                const offset = std.math.cast(u32, chunk.offset) orelse return error.LimitExceeded;
                try physical.put(self.allocator, offset, chunk);
            }
        }
        self.adoptDirectory(try Directory.parse(self.allocator, dir.data, self.limits, &physical));
    }

    fn adoptDirectory(self: *Document, parsed: Directory) void {
        self.components = parsed.components;
        self.pages = parsed.pages;
        self.names = parsed.names;
        self.id_index = parsed.id_index;
        self.indirect = parsed.indirect;
    }

    /// A standalone page has no DIRM: retain its INCL IDs as host-resolved names.
    /// Registration is transactional, including when a supplied DJVI adds IDs.
    fn discoverIncludes(self: *Document, form: iff.Chunk) Error!void {
        const start = self.components.items.len;
        const name_bytes = self.include_name_bytes;
        errdefer {
            for (self.components.items[start..]) |component| {
                _ = self.id_index.remove(component.id);
                self.allocator.free(component.owned_id.?);
            }
            self.components.shrinkRetainingCapacity(start);
            self.include_name_bytes = name_bytes;
        }
        var iter = try form.children();
        var count: usize = 0;
        while (try iter.next()) |chunk| {
            count += 1;
            if (count > self.limits.max_chunks) return error.LimitExceeded;
            if (iff.tag(chunk.id, "INCL")) _ = try self.includeComponent(chunk.data);
        }
    }

    /// Resolve an include, registering host-resolved names for a standalone DJVU.
    /// Component indexes survive registration; pointers into the array do not.
    pub fn includeComponent(self: *Document, raw: []const u8) Error!usize {
        if (!iff.tag(try self.container.formType(), "DJVU")) return self.resolve(raw);
        if (self.id_index.get(raw)) |index| return index;
        const id = std.mem.trimEnd(u8, raw, "\x00\r\n");
        if (id.len == 0 or std.mem.indexOfScalar(u8, id, 0) != null or !std.unicode.utf8ValidateSlice(id)) {
            return error.InvalidData;
        }
        if (self.id_index.get(id)) |index| return index;
        if (self.components.items.len >= self.limits.max_components or
            self.include_name_bytes > self.limits.max_input_bytes or
            id.len > self.limits.max_input_bytes - self.include_name_bytes)
        {
            return error.LimitExceeded;
        }
        try self.components.ensureUnusedCapacity(self.allocator, 1);
        try self.id_index.ensureUnusedCapacity(self.allocator, 1);
        const owned = try self.allocator.dupe(u8, id);
        const index = self.components.items.len;
        self.id_index.putAssumeCapacityNoClobber(owned, index);
        self.components.appendAssumeCapacity(.{
            .id = owned,
            .name = owned,
            .title = owned,
            .kind = .shared,
            .owned_id = owned,
        });
        self.include_name_bytes += owned.len;
        return index;
    }

    pub fn pageCount(self: *const Document) usize {
        return self.pages.items.len;
    }

    pub fn pageComponent(self: *const Document, page: usize) Error!usize {
        if (page >= self.pages.items.len) return error.InvalidArgument;
        return self.pages.items[page];
    }

    /// Locate a stored thumbnail, or the next unloaded component to inspect.
    /// DIRM THUM takes precedence; absent entries fall back to page-local TH44.
    /// No IO or image decoding. Recheck after supplying a missing component.
    pub fn thumbnailComponent(self: *const Document, page: usize) Error!?usize {
        const source = (try self.thumbnailSource(page)) orelse return null;
        return source.component;
    }

    /// Borrowed first IW44 chunk, or null if the page has no stored thumbnail.
    /// MissingComponent means its THUM or fallback page needs loading. Page INCL
    /// is never followed. THUM contains independent images; page-local TH44 can
    /// continue across chunks, which Job.initThumbnail decodes together.
    pub fn thumbnailChunk(self: *const Document, page: usize) Error!?iff.Chunk {
        const source = (try self.thumbnailSource(page)) orelse return null;
        return source.chunk orelse error.MissingComponent;
    }
    const ThumbnailSource = struct { component: usize, chunk: ?iff.Chunk = null };

    fn thumbnailSource(self: *const Document, page: usize) Error!?ThumbnailSource {
        const page_component = try self.pageComponent(page);
        if (iff.tag(try self.container.formType(), "THUM"))
            return .{ .component = page_component, .chunk = self.thumbnail_images.items[page] };
        var index = page_component;
        var ordinal: usize = 0;
        while (index != 0) {
            index -= 1;
            const entry = self.components.items[index];
            if (entry.kind == .page) ordinal += 1;
            if (entry.kind != .thumbnail) continue;
            const form = entry.form orelse return .{ .component = index };
            if (try self.thumbnailAt(form, ordinal)) |chunk|
                return .{ .component = index, .chunk = chunk };
            break;
        }
        const form = self.components.items[page_component].form orelse return .{ .component = page_component };
        if (!iff.tag(try form.formType(), "DJVU")) return null;
        const chunk = (try self.thumbnailAt(form, 0)) orelse return null;
        return .{ .component = page_component, .chunk = chunk };
    }

    fn thumbnailAt(self: *const Document, form: iff.Chunk, ordinal: usize) Error!?iff.Chunk {
        var remaining = ordinal;
        var chunks = try form.children();
        var count: usize = 0;
        while (try chunks.next()) |chunk| {
            count += 1;
            if (count > self.limits.max_chunks) return error.LimitExceeded;
            if (!iff.tag(chunk.id, "TH44")) continue;
            if (remaining == 0) return chunk;
            remaining -= 1;
        }
        return null;
    }

    pub fn find(self: *const Document, component: usize, id: []const u8) Error!?iff.Chunk {
        return self.findIn(try self.componentForm(component), id);
    }

    fn findIn(self: *const Document, form: iff.Chunk, id: []const u8) Error!?iff.Chunk {
        var iter = try form.children();
        var result: ?iff.Chunk = null;
        var count: usize = 0;
        while (try iter.next()) |chunk| {
            count += 1;
            if (count > self.limits.max_chunks) return error.LimitExceeded;
            if (iff.tag(chunk.id, id)) {
                if (result != null) return error.InvalidData;
                result = chunk;
            }
        }
        return result;
    }

    pub fn info(self: *const Document, page: usize) Error!iff.Info {
        const component = try self.pageComponent(page);
        const form = try self.componentForm(component);
        const kind = try form.formType();
        const result = if (iff.tag(kind, "THUM")) blk: {
            const header = try iw44.Header.parse(self.thumbnail_images.items[page].data);
            break :blk iff.Info{ .width = header.width, .height = header.height, .dpi = 300, .rotation = 0 };
        } else if (iff.isIw44(kind)) blk: {
            var chunks = try form.children();
            var first: ?[]const u8 = null;
            var count: usize = 0;
            while (try chunks.next()) |chunk| {
                count += 1;
                if (count > self.limits.max_chunks) return error.LimitExceeded;
                if (first == null and iff.tag(chunk.id, kind)) first = chunk.data;
            }
            const header = try iw44.Header.parse(first orelse return error.InvalidData);
            // Standalone IW44 has no INFO. Its header owns the image dimensions;
            // use the conventional photo defaults, regardless of optional chunks.
            break :blk iff.Info{ .width = header.width, .height = header.height, .dpi = 100, .rotation = 0 };
        } else blk: {
            const chunk = (try self.findIn(form, "INFO")) orelse return error.InvalidData;
            break :blk try iff.Info.parse(chunk.data);
        };
        const pixels = std.math.mul(usize, result.width, result.height) catch return error.LimitExceeded;
        if (pixels > self.limits.max_page_pixels) return error.LimitExceeded;
        return result;
    }

    /// Resolve output dimensions/region without starting a job or decoding layers.
    pub fn geometry(self: *const Document, page: usize, options: geometry_module.Options) Error!geometry_module.Geometry {
        return geometry_module.Geometry.init(try self.info(page), options);
    }

    pub fn transform(self: *const Document, page: usize, options: geometry_module.Options) Error!geometry_module.Transform {
        return geometry_module.Transform.init(try self.info(page), options);
    }

    /// Owned snapshot, independent of image decoding and the document lifetime.
    /// null means no text chunk; a present empty text layer is a Text with no bytes.
    pub fn text(self: *const Document, page: usize) Error!?Text {
        var chunks = try self.pageChunks(page);
        defer chunks.deinit();
        var selected: ?iff.Chunk = null;
        while (try chunks.next()) |entry| {
            const chunk = entry.chunk;
            if (!iff.tag(chunk.id, "TXTa") and !iff.tag(chunk.id, "TXTz")) continue;
            if (selected != null) return error.InvalidData;
            selected = chunk;
        }
        const chunk = selected orelse return null;
        const page_info = try self.info(page);
        return try Text.decode(self.allocator, chunk.data, iff.tag(chunk.id, "TXTz"), page_info.height, self.limits);
    }

    pub fn resolve(self: *const Document, raw: []const u8) Error!usize {
        if (self.id_index.get(raw)) |index| return index;
        const id = std.mem.trimEnd(u8, raw, "\x00\r\n");
        return self.id_index.get(id) orelse error.InvalidData;
    }

    /// Owned NAVM snapshot from the index; no page components need loading.
    /// A unique root-level NAVM is accepted even outside its conventional slot.
    pub fn outline(self: *const Document) Error!?Outline {
        const chunk = (try self.findIn(self.container, "NAVM")) orelse return null;
        return try Outline.decode(self.allocator, chunk.data, self.limits);
    }

    /// No IO or allocations. Relative links need an explicit zero-based origin;
    /// missing origins use page 0 only to choose among duplicate titles.
    pub fn resolveLink(self: *const Document, href: []const u8, from_page: ?usize) Error!links.Link {
        return links.resolve(self, href, from_page);
    }

    /// Owned snapshot; annotation syntax errors do not affect image or text.
    pub fn annotations(self: *const Document, page: usize) Error!?annotation.Annotations {
        var chunks = try self.pageChunks(page);
        defer chunks.deinit();
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(self.allocator);
        var sources: std.ArrayList(annotation.Chunk) = .empty;
        defer sources.deinit(self.allocator);
        const limit = @min(self.limits.max_annotation_bytes, std.math.maxInt(u32));
        while (try chunks.next()) |entry| {
            const chunk = entry.chunk;
            const compressed = iff.tag(chunk.id, "ANTz");
            if (!compressed and !iff.tag(chunk.id, "ANTa")) continue;
            const remaining = limit - raw.items.len;
            // An empty ANTz may omit BZZ data; it still counts as present.
            const decoded = if (compressed and chunk.data.len != 0)
                try bzz.decode(self.allocator, chunk.data, @min(remaining, self.limits.max_bzz_bytes))
            else
                null;
            defer if (decoded) |bytes| self.allocator.free(bytes);
            const bytes = decoded orelse chunk.data;
            if (bytes.len > remaining) return error.LimitExceeded;
            try sources.append(self.allocator, .{
                .component = @intCast(entry.component),
                .start = @intCast(raw.items.len),
                .length = @intCast(bytes.len),
            });
            try raw.appendSlice(self.allocator, bytes);
        }
        if (sources.items.len == 0) return null;
        // Expressions can span chunks, and legacy escape detection applies to
        // the entire annotation stream. Parse only after ordered concatenation.
        var result = try annotation.Annotations.decode(self.allocator, raw.items, try self.info(page), self.limits);
        errdefer result.deinit();
        result.chunks = try result.arena.allocator().dupe(annotation.Chunk, sources.items);
        return result;
    }

    pub fn dropDictionaries(self: *Document) Error!void {
        if (self.busy) return error.Busy;
        self.cache.dropDictionaries(self.allocator, self.components.items);
    }

    /// Retained supplied input, excluding the original borrowed/owned index.
    pub fn suppliedBytes(self: *const Document) usize {
        return self.cache.encoded_bytes;
    }

    /// Requested bytes in reclaimable input and dictionaries, not allocator capacity.
    pub fn cacheBytes(self: *const Document) usize {
        return self.cache.bytes();
    }

    /// Evict older input/dictionaries until their retained bytes fit the limit.
    /// Finish borrowed chunk/iterator use first. Jobs and metadata scans return
    /// Busy until deinit. Owned metadata snapshots remain valid.
    pub fn trimCache(self: *Document, limit: usize) Error!void {
        if (self.busy or self.metadata_busy) return error.Busy;
        self.cache.trim(self.allocator, self.components.items, limit);
    }

    pub fn componentForm(self: *const Document, component: usize) Error!iff.Chunk {
        if (component >= self.components.items.len) return error.InvalidArgument;
        return self.components.items[component].form orelse error.MissingComponent;
    }

    /// Takes ownership on success; bytes must use this Document's allocator.
    /// Supply exact FORM bytes for a range entry, an AT&T-prefixed file otherwise.
    /// May supply an unloaded entry between steps of another page's active Job.
    pub fn provideComponent(self: *Document, component: usize, bytes: []u8) Error!void {
        if (component >= self.components.items.len) return error.InvalidArgument;
        const entry = self.components.items[component];
        if (entry.form != null) return error.InvalidArgument;
        if (self.bytes.len > self.limits.max_input_bytes) return error.LimitExceeded;
        const input_budget = self.limits.max_input_bytes - self.bytes.len;
        const retained = self.suppliedBytes();
        if (retained > input_budget or bytes.len > input_budget - retained) return error.LimitExceeded;
        const supplied = if (entry.range) |range| blk: {
            if (bytes.len != range.length) return error.InvalidData;
            var iter: iff.Iterator = .{ .bytes = bytes };
            const form = (try iter.next()) orelse return error.InvalidData;
            if (form.data.len + 8 != bytes.len) return error.InvalidData;
            break :blk form;
        } else try iff.root(bytes);
        if (!iff.tag(try supplied.formType(), entry.kind.formType())) return error.InvalidData;
        if (entry.size != 0 and entry.size != supplied.data.len + 8) return error.InvalidData;
        if (iff.tag(try self.container.formType(), "DJVU")) try self.discoverIncludes(supplied);
        // Discovery may have moved the component array. Indexes remain stable.
        self.cache.storeInput(self.components.items, component, supplied, bytes);
    }

    pub const Scope = enum { page, includes, thumbnail };

    /// A host can load this entry and retry; null means the requested scope is ready.
    /// INFO/geometry need .page; rendering/text need .includes. Thumbnails inspect
    /// THUM and, when absent there, the physical page without following INCL.
    pub fn nextMissing(self: *const Document, page: usize, scope: Scope) Error!?usize {
        if (scope == .thumbnail) {
            const component = (try self.thumbnailComponent(page)) orelse return null;
            return if (self.components.items[component].form == null) component else null;
        }
        const component = try self.pageComponent(page);
        if (self.components.items[component].form == null) return component;
        if (scope == .page) return null;
        var iter = try self.pageChunks(page);
        defer iter.deinit();
        while (iter.next() catch |err| {
            if (err == error.MissingComponent) return iter.missing;
            return err;
        }) |_| {}
        return null;
    }

    /// Release supplied files and dictionaries; IDs and component indexes survive.
    pub fn dropComponents(self: *Document) Error!void {
        if (self.busy or self.metadata_busy) return error.Busy;
        self.cache.clear(self.allocator, self.components.items);
    }

    /// Expand DjVu INCL in place, once per component; reject cycles and non-DJVI
    /// targets. Standalone IW44 exposes its own chunks without include semantics;
    /// standalone THUM exposes only the selected image, without shared metadata.
    pub fn pageChunks(self: *const Document, page: usize) Error!Chunks {
        const kind = try self.container.formType();
        var chunks = try Chunks.init(self, try self.pageComponent(page));
        if (iff.tag(kind, "THUM")) {
            const chunk = self.thumbnail_images.items[page];
            chunks.stack.items[0].chunks = .{
                .bytes = self.bytes[chunk.offset..][0 .. 8 + chunk.data.len],
                .base = chunk.offset,
            };
        }
        return chunks;
    }
};

/// Borrowed traversal. After an error, discard it; recreate the iterator after
/// supplying a missing component rather than resuming past the failed INCL.
pub const Chunks = struct {
    const Frame = struct { component: usize, chunks: iff.Iterator };
    pub const Entry = struct { component: usize, chunk: iff.Chunk };
    doc: *const Document,
    visited: []u8,
    stack: std.ArrayList(Frame) = .empty,
    count: usize = 0,
    missing: ?usize = null,

    fn init(doc: *const Document, component: usize) Error!Chunks {
        var self: Chunks = .{ .doc = doc, .visited = try doc.allocator.alloc(u8, doc.components.items.len) };
        @memset(self.visited, 0);
        errdefer self.deinit();
        try self.push(component);
        return self;
    }

    pub fn deinit(self: *Chunks) void {
        self.doc.allocator.free(self.visited);
        self.stack.deinit(self.doc.allocator);
        self.* = undefined;
    }

    fn push(self: *Chunks, component: usize) Error!void {
        // A host may supply a DJVI (discovering more IDs) between iterator calls.
        if (component >= self.visited.len) {
            const old_len = self.visited.len;
            self.visited = try self.doc.allocator.realloc(self.visited, self.doc.components.items.len);
            @memset(self.visited[old_len..], 0);
        }
        if (self.visited[component] == 1) return error.InvalidData;
        if (self.visited[component] == 2) return;
        if (self.stack.items.len >= self.doc.limits.max_include_depth) return error.LimitExceeded;
        const form = self.doc.componentForm(component) catch |err| {
            if (err == error.MissingComponent) self.missing = component;
            return err;
        };
        try self.stack.append(self.doc.allocator, .{ .component = component, .chunks = try form.children() });
        self.visited[component] = 1;
    }

    pub fn next(self: *Chunks) Error!?Entry {
        while (self.stack.items.len != 0) {
            const frame = &self.stack.items[self.stack.items.len - 1];
            const chunk = (try frame.chunks.next()) orelse {
                self.visited[frame.component] = 2;
                _ = self.stack.pop();
                continue;
            };
            self.count += 1;
            if (self.count > self.doc.limits.max_chunks) return error.LimitExceeded;
            if (iff.tag(chunk.id, "INCL") and !iff.isIw44(try self.doc.container.formType())) {
                const target = try self.doc.resolve(chunk.data);
                const kind = self.doc.components.items[target].kind;
                if (kind != .shared and kind != .shared_annotations) return error.InvalidData;
                try self.push(target);
                continue;
            }
            if (self.doc.components.items[frame.component].kind != .page and iff.tag(chunk.id, "INFO")) {
                return error.InvalidData;
            }
            return .{ .component = frame.component, .chunk = chunk };
        }
        return null;
    }
};
