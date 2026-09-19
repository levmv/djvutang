//! Complete document metadata discovery without loading image payloads.
const std = @import("std");
const document = @import("document.zig");
const iff = @import("iff.zig");
const bzz = @import("bzz.zig");
const annotation = @import("annotations.zig");
const Error = @import("types.zig").Error;

/// Zero-based page, or null when the record uses only shared annotation bytes.
pub const Record = struct { key: []const u8, value: []const u8, page: ?u32 };
pub const Xmp = struct { value: []const u8, page: ?u32 };

/// Owned snapshot. Empty arrays mean the complete supported document was checked.
/// Shared records are represented once; context-dependent interpretations remain
/// separate. Key case, duplicate source entries and XMP packets are preserved.
pub const Metadata = struct {
    arena: std.heap.ArenaAllocator,
    metadata: []const Record,
    xmp: []const Xmp,

    pub fn deinit(self: *Metadata) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn jsonStringify(self: *const Metadata, stream: *std.json.Stringify) std.Io.Writer.Error!void {
        try stream.write(.{ .metadata = self.metadata, .xmp = self.xmp });
    }
};

/// component=0xffffffff addresses the original input; other indexes address an
/// external component file, including its AT&T prefix. Supply the source's full
/// size with each range so even skipped payloads can be checked against EOF.
pub const Request = extern struct { component: u32, offset: u32, length: u32 };
const main_source = std.math.maxInt(u32);
const Part = union(enum) { include: usize, annotation: annotation.Span };
const Component = struct {
    parts: std.ArrayList(Part) = .empty,
    raw: std.ArrayList(u8) = .empty,
    page: ?u32 = null,
    referenced: bool = false,
    mark: u2 = 0,
    height: usize = 1,
    has_annotations: bool = false,
    parsed_alone: bool = false,
    visit: usize = 0,
};
const Frame = struct { component: usize, part: usize = 0 };
const Fragment = struct { start: u32, component: usize, span: annotation.Span };
const Current = struct {
    stage: enum { form, chunk, payload } = .form,
    payload: enum { include, plain, compressed } = .plain,
    form_start: u32,
    origin: u32,
    source_size: u32,
    cursor: u32 = 0,
    end: u32 = 0,
    next: u32 = 0,
    length: u32 = 0,
};
// Identify the physical entry, not just its value: separate identical pairs must
// survive. Entries completed by page-local fragments also retain that page.
const Key = struct { xmp: bool, key: []const u8, value: []const u8, component: u32, start: u32, page: ?u32 };
const KeyContext = struct {
    pub fn hash(_: KeyContext, key: Key) u64 {
        var h = std.hash.Wyhash.init(@intFromBool(key.xmp));
        const identity = [_]u32{ key.component, key.start, key.page orelse main_source };
        h.update(std.mem.asBytes(&identity));
        for ([_][]const u8{ key.key, key.value }) |bytes| {
            const length: u64 = bytes.len;
            h.update(std.mem.asBytes(&length));
            h.update(bytes);
        }
        return h.final();
    }
    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return a.xmp == b.xmp and std.mem.eql(u8, a.key, b.key) and std.mem.eql(u8, a.value, b.value) and
            a.component == b.component and a.start == b.start and a.page == b.page;
    }
};

/// Keep Document alive and stable until deinit. One scan per document; rendering
/// may use the same document. Input eviction is Busy while a scan exists.
/// Work counts structural operations. BZZ and one annotation stream's parsing
/// remain synchronous under the existing byte/node limits. Always deinit after
/// success, failure or cancellation. No partial result is published.
pub const Scan = struct {
    pub const Status = enum { progress, input, done };
    doc: *document.Document,
    components: std.ArrayList(Component) = .empty,
    phase: enum { collect, validate, parse, done, taken } = .collect,
    failure: ?Error = null,
    pending: ?Request = null,
    current: ?Current = null,
    component: usize = 0,
    chunks: usize = 0,
    annotation_bytes: usize = 0,
    stack: std.ArrayList(Frame) = .empty,
    generation: usize = 0,
    raw: std.ArrayList(u8) = .empty,
    fragments: std.ArrayList(Fragment) = .empty,
    arena: std.heap.ArenaAllocator,
    records: std.ArrayList(Record) = .empty,
    packets: std.ArrayList(Xmp) = .empty,
    seen: std.HashMapUnmanaged(Key, void, KeyContext, 80) = .empty,

    pub fn init(doc: *document.Document) Error!Scan {
        if (doc.metadata_busy) return error.Busy;
        doc.metadata_busy = true;
        var self: Scan = .{ .doc = doc, .arena = std.heap.ArenaAllocator.init(doc.allocator) };
        errdefer self.deinit();
        try self.grow();
        for (doc.pages.items, 0..) |component, page| self.components.items[component].page = @intCast(page);
        return self;
    }

    pub fn deinit(self: *Scan) void {
        const a = self.doc.allocator;
        for (self.components.items) |*component| {
            component.parts.deinit(a);
            component.raw.deinit(a);
        }
        self.components.deinit(a);
        self.stack.deinit(a);
        self.raw.deinit(a);
        self.fragments.deinit(a);
        self.seen.deinit(a);
        self.arena.deinit();
        self.doc.metadata_busy = false;
        self.* = undefined;
    }

    /// Cancel unfinished work without replacing a result or an earlier failure.
    pub fn cancel(self: *Scan) void {
        if (self.phase == .done or self.phase == .taken or self.failure != null) return;
        self.failure = error.Cancelled;
        self.pending = null;
    }

    pub fn nextRange(self: *const Scan) Error!?Request {
        if (self.failure) |err| return err;
        if (self.phase == .taken) return error.InvalidArgument;
        return self.pending;
    }

    /// Borrows exactly the requested bytes for this call. source_size is the
    /// full original/external file size, not this range or its component size.
    pub fn provide(self: *Scan, bytes: []const u8, source_size: u32) Error!void {
        errdefer |err| self.failure = err;
        const request = (try self.nextRange()) orelse return error.InvalidArgument;
        if (bytes.len != request.length or @as(u64, request.offset) + request.length > source_size) return error.InvalidData;
        const current = &self.current.?;
        if (current.source_size != 0 and current.source_size != source_size) return error.InvalidData;
        current.source_size = source_size;
        self.pending = null;
        try self.consume(bytes);
    }

    pub fn step(self: *Scan, work: usize) Error!Status {
        if (self.failure) |err| return err;
        errdefer |err| self.failure = err;
        if (self.phase == .taken or work == 0) return error.InvalidArgument;
        if (self.pending) |request| {
            // A host that only has whole external files may use the ordinary
            // component supply API instead of satisfying our first header read.
            if (request.component != main_source and self.current.?.stage == .form and
                self.doc.components.items[request.component].form != null)
            {
                self.pending = null;
                self.current = null;
            } else return .input;
        }
        for (0..work) |_| {
            switch (self.phase) {
                .collect => if (!try self.collect()) return .input,
                .validate => try self.validate(),
                .parse => try self.parse(),
                .done => return .done,
                .taken => unreachable,
            }
        }
        return if (self.phase == .done) .done else .progress;
    }

    pub fn takeResult(self: *Scan) Error!Metadata {
        if (self.failure) |err| return err;
        if (self.phase != .done) return error.InvalidArgument;
        errdefer |err| self.failure = err;
        const a = self.arena.allocator();
        const records = try self.records.toOwnedSlice(a);
        const packets = try self.packets.toOwnedSlice(a);
        const arena = self.arena;
        self.arena = std.heap.ArenaAllocator.init(self.doc.allocator);
        self.phase = .taken;
        return .{ .arena = arena, .metadata = records, .xmp = packets };
    }

    fn grow(self: *Scan) Error!void {
        const old = self.components.items.len;
        try self.components.resize(self.doc.allocator, self.doc.components.items.len);
        @memset(self.components.items[old..], .{});
    }

    fn collect(self: *Scan) Error!bool {
        try self.grow();
        if (self.component == self.components.items.len) {
            self.component = 0;
            self.phase = .validate;
            return true;
        }
        const entry = self.doc.components.items[self.component];
        if (entry.kind == .thumbnail) {
            self.component += 1;
            return true;
        }
        if (self.current == null) self.current = .{
            .form_start = if (entry.form != null or entry.range != null) 0 else 4,
            .origin = if (entry.range) |range| range.offset else 0,
            .source_size = if (entry.range != null) self.doc.source_size else 0,
        };
        const current = &self.current.?;
        if (current.stage != .form and current.cursor == current.end) {
            self.current = null;
            self.component += 1;
            return true;
        }
        if (entry.form) |form| {
            if (current.stage == .form) {
                current.end = std.math.cast(u32, 8 + form.data.len) orelse return error.LimitExceeded;
                try self.beginForm(try form.formType());
            } else {
                const length = self.readLength();
                if (@as(u64, current.cursor) + length > current.end) return error.InvalidData;
                try self.consume(form.data[current.cursor - current.form_start - 8 ..][0..length]);
            }
            return true;
        }
        self.pending = .{
            .component = if (entry.range != null) main_source else @intCast(self.component),
            .offset = current.origin + current.cursor,
            .length = self.readLength(),
        };
        return false;
    }

    fn readLength(self: *const Scan) u32 {
        const current = self.current.?;
        return switch (current.stage) {
            // Directory extents let us fetch FORM and its first child header
            // together, without speculatively reading an image payload.
            .form => if (self.doc.components.items[self.component].range) |range| @min(range.length, 20) else current.form_start + 12,
            .chunk => @min(8, current.end - current.cursor),
            .payload => current.length,
        };
    }

    fn beginForm(self: *Scan, kind: []const u8) Error!void {
        const entry = self.doc.components.items[self.component];
        const root_kind = try self.doc.container.formType();
        const expected = if (self.component == 0 and iff.isIw44(root_kind)) root_kind else entry.kind.formType();
        if (!iff.tag(kind, expected)) return error.InvalidData;
        const current = &self.current.?;
        const length = current.end - current.form_start;
        if (entry.size != 0 and entry.size != length) return error.InvalidData;
        if (entry.range) |range| if (range.length != length) return error.InvalidData;
        current.cursor = current.form_start + 12;
        current.stage = .chunk;
    }

    fn consume(self: *Scan, bytes: []const u8) Error!void {
        const current = &self.current.?;
        switch (current.stage) {
            .form => {
                const start = current.form_start;
                if ((start != 0 and !iff.tag(bytes[0..4], "AT&T")) or !iff.tag(bytes[start..][0..4], "FORM")) return error.InvalidData;
                const length = std.mem.readInt(u32, bytes[start + 4 ..][0..4], .big);
                const end = @as(u64, start) + 8 + length;
                if (length < 4 or end + current.origin > current.source_size) return error.InvalidData;
                if (start != 0 and end != current.source_size and !(length & 1 != 0 and end + 1 == current.source_size)) return error.InvalidData;
                current.end = @intCast(end);
                try self.beginForm(bytes[start + 8 ..][0..4]);
                if (bytes.len > start + 12) try self.consume(bytes[start + 12 ..]);
            },
            .chunk => {
                if (bytes.len != 8) return error.InvalidData;
                self.chunks += 1;
                if (self.chunks > self.doc.limits.max_chunks) return error.LimitExceeded;
                const id = bytes[0..4];
                const length = std.mem.readInt(u32, bytes[4..8], .big);
                const end = @as(u64, current.cursor) + 8 + length;
                if (end > current.end) return error.InvalidData;
                current.next = @intCast(end + @intFromBool(length & 1 != 0 and end < current.end));
                if (iff.tag(id, "INFO") and self.doc.components.items[self.component].kind != .page) return error.InvalidData;
                if (iff.tag(id, "INCL") and !iff.isIw44(try self.doc.container.formType())) {
                    current.payload = .include;
                } else if (iff.tag(id, "ANTa")) {
                    current.payload = .plain;
                    if (length > self.doc.limits.max_annotation_bytes - self.annotation_bytes) return error.LimitExceeded;
                } else if (iff.tag(id, "ANTz")) {
                    current.payload = .compressed;
                } else {
                    current.cursor = current.next;
                    return;
                }
                if (length > self.doc.limits.max_input_bytes) return error.LimitExceeded;
                current.cursor += 8;
                current.length = length;
                current.stage = .payload;
                if (length == 0) try self.consume(&.{});
            },
            .payload => {
                const a = self.doc.allocator;
                if (current.payload == .include) {
                    const target = try self.doc.includeComponent(bytes);
                    const kind = self.doc.components.items[target].kind;
                    if (kind != .shared and kind != .shared_annotations) return error.InvalidData;
                    try self.grow();
                    try self.components.items[self.component].parts.append(a, .{ .include = target });
                    self.components.items[target].referenced = true;
                } else {
                    const remaining = @min(self.doc.limits.max_annotation_bytes, std.math.maxInt(u32)) - self.annotation_bytes;
                    const decoded = if (current.payload == .compressed and bytes.len != 0)
                        try bzz.decode(a, bytes, @min(remaining, self.doc.limits.max_bzz_bytes))
                    else
                        null;
                    defer if (decoded) |data| a.free(data);
                    const data = decoded orelse bytes;
                    if (data.len > remaining) return error.LimitExceeded;
                    const component = &self.components.items[self.component];
                    const span: annotation.Span = .{ .start = @intCast(component.raw.items.len), .length = @intCast(data.len) };
                    try component.raw.appendSlice(a, data);
                    try component.parts.append(a, .{ .annotation = span });
                    self.annotation_bytes += data.len;
                    component.has_annotations = component.raw.items.len != 0;
                }
                current.cursor = current.next;
                current.stage = .chunk;
            },
        }
    }

    fn push(self: *Scan, component: usize) Error!void {
        if (self.stack.items.len >= self.doc.limits.max_include_depth) return error.LimitExceeded;
        try self.stack.append(self.doc.allocator, .{ .component = component });
    }

    // Validate every edge even for a negative result. Completed subtree heights
    // bound deep paths independently of directory order and repeated references.
    fn validate(self: *Scan) Error!void {
        if (self.stack.items.len == 0) {
            if (self.component == self.components.items.len) {
                self.component = 0;
                self.phase = .parse;
                return;
            }
            const index = self.component;
            self.component += 1;
            if (self.components.items[index].mark == 2) return;
            try self.push(index);
            self.components.items[index].mark = 1;
            return;
        }
        const frame = &self.stack.items[self.stack.items.len - 1];
        const component = &self.components.items[frame.component];
        if (frame.part == component.parts.items.len) {
            if (component.height > self.doc.limits.max_include_depth) return error.LimitExceeded;
            component.mark = 2;
            _ = self.stack.pop();
            return;
        }
        switch (component.parts.items[frame.part]) {
            .annotation => frame.part += 1,
            .include => |target| {
                const child = &self.components.items[target];
                switch (child.mark) {
                    0 => {
                        try self.push(target);
                        child.mark = 1;
                    },
                    1 => return error.InvalidData,
                    2 => {
                        component.height = @max(component.height, child.height + 1);
                        component.has_annotations = component.has_annotations or child.has_annotations;
                        frame.part += 1;
                    },
                    else => unreachable,
                }
            },
        }
    }

    fn parse(self: *Scan) Error!void {
        if (self.stack.items.len == 0) {
            if (self.component == self.components.items.len) {
                self.phase = .done;
                return;
            }
            const index = self.component;
            self.component += 1;
            const component = &self.components.items[index];
            if (!component.has_annotations or (component.page == null and component.referenced)) return;
            self.raw.clearRetainingCapacity();
            self.fragments.clearRetainingCapacity();
            self.generation += 1;
            component.visit = self.generation;
            try self.push(index);
            return;
        }
        const frame = &self.stack.items[self.stack.items.len - 1];
        const component = &self.components.items[frame.component];
        if (frame.part == component.parts.items.len) {
            _ = self.stack.pop();
            if (self.stack.items.len == 0) try self.extract();
            return;
        }
        const part = component.parts.items[frame.part];
        frame.part += 1;
        switch (part) {
            .include => |target| {
                const child = &self.components.items[target];
                if (child.visit == self.generation) return;
                child.visit = self.generation;
                try self.push(target);
            },
            .annotation => |span| {
                if (span.length == 0) return;
                try self.fragments.append(self.doc.allocator, .{ .start = @intCast(self.raw.items.len), .component = frame.component, .span = span });
                try self.raw.appendSlice(self.doc.allocator, component.raw.items[span.start..][0..span.length]);
            },
        }
    }

    fn extract(self: *Scan) Error!void {
        const sole = self.fragments.items[0].component;
        const alone = for (self.fragments.items) |fragment| {
            if (fragment.component != sole) break false;
        } else true;
        // With a single contributor the complete byte stream is identical on
        // every referencing page. Mixed streams still need parsing: they can
        // change escapes or complete expressions across INCL.
        if (alone and self.components.items[sole].parsed_alone) return;
        var fields = try annotation.Fields.decode(self.doc.allocator, self.raw.items, self.doc.limits);
        defer fields.deinit();
        for (fields.metadata) |field| try self.record(false, field.key, field.value, field.span);
        for (fields.xmp) |field| try self.record(true, "", field.value, field.span);
        if (alone) self.components.items[sole].parsed_alone = true;
    }

    fn record(self: *Scan, xmp: bool, key: []const u8, value: []const u8, span: annotation.Span) Error!void {
        var lo: usize = 0;
        var hi = self.fragments.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const f = self.fragments.items[mid];
            if (f.start + f.span.length <= span.start) lo = mid + 1 else hi = mid;
        }
        const first = self.fragments.items[lo];
        const end = span.start + span.length;
        var page: ?u32 = null;
        for (self.fragments.items[lo..]) |fragment| {
            if (fragment.start >= end) break;
            if (self.components.items[fragment.component].page) |number| {
                page = number;
                break;
            }
        }
        const candidate: Key = .{
            .xmp = xmp,
            .key = key,
            .value = value,
            .component = @intCast(first.component),
            .start = first.span.start + (span.start - first.start),
            .page = page,
        };
        if (self.seen.contains(candidate)) return;
        if (self.records.items.len + self.packets.items.len >= self.doc.limits.max_annotation_nodes) return error.LimitExceeded;
        const a = self.arena.allocator();
        var owned = candidate;
        owned.key = try a.dupe(u8, key);
        owned.value = try a.dupe(u8, value);
        try self.seen.put(self.doc.allocator, owned, {});
        if (xmp) {
            try self.packets.append(a, .{ .value = owned.value, .page = page });
        } else try self.records.append(a, .{ .key = owned.key, .value = owned.value, .page = page });
    }
};
