const std = @import("std");
const iff = @import("iff.zig");
const jb2 = @import("jb2.zig");
const Allocator = std.mem.Allocator;

pub const ByteRange = extern struct { offset: u32, length: u32 };

pub const Component = struct {
    /// DIRM type values are also used by the WASM ABI.
    pub const Kind = enum(u8) {
        shared = 0,
        page = 1,
        thumbnail = 2,
        shared_annotations = 3,

        pub fn formType(self: Kind) *const [4]u8 {
            return switch (self) {
                .shared, .shared_annotations => "DJVI",
                .page => "DJVU",
                .thumbnail => "THUM",
            };
        }
    };

    id: []const u8,
    name: []const u8,
    title: []const u8,
    kind: Kind,
    size: u32 = 0,
    /// Bundled source bytes, including FORM header but excluding padding/magic.
    range: ?ByteRange = null,
    form: ?iff.Chunk = null,
    owned: ?[]u8 = null,
    owned_id: ?[]u8 = null,
    dictionary: ?*jb2.Image = null,
    cache: struct {
        previous: ?usize = null,
        next: ?usize = null,
        linked: bool = false,
        parent: ?usize = null,
        children: usize = 0,
        dictionary_bytes: usize = 0,
    } = .{},
};

/// Reclaimable input and immutable dictionaries, ordered from oldest to newest.
/// Links are component indexes: standalone INCL discovery can move the array.
/// The owning Document permits eviction only while no Job borrows these entries.
pub const Cache = struct {
    encoded_bytes: usize = 0,
    dictionary_bytes: usize = 0,
    first: ?usize = null,
    last: ?usize = null,

    pub fn bytes(self: Cache) usize {
        return self.encoded_bytes + self.dictionary_bytes;
    }

    pub fn touch(self: *Cache, components: []Component, index: usize) void {
        const c = &components[index];
        if (c.owned == null and c.dictionary == null) return;
        self.unlink(components, index);
        c.cache.previous = self.last;
        c.cache.next = null;
        c.cache.linked = true;
        if (self.last) |last| components[last].cache.next = index else self.first = index;
        self.last = index;
    }

    fn unlink(self: *Cache, components: []Component, index: usize) void {
        const c = &components[index].cache;
        if (!c.linked) return;
        if (c.previous) |previous| components[previous].cache.next = c.next else self.first = c.next;
        if (c.next) |next| components[next].cache.previous = c.previous else self.last = c.previous;
        c.previous = null;
        c.next = null;
        c.linked = false;
    }

    pub fn storeInput(self: *Cache, components: []Component, index: usize, form: iff.Chunk, input: []u8) void {
        const c = &components[index];
        std.debug.assert(c.form == null and c.owned == null);
        c.form = form;
        c.owned = input;
        self.encoded_bytes += input.len;
        self.touch(components, index);
    }

    pub fn storeDictionary(self: *Cache, components: []Component, index: usize, parent: ?usize, image: *jb2.Image) void {
        const c = &components[index];
        std.debug.assert(c.dictionary == null);
        c.dictionary = image;
        c.cache.parent = parent;
        c.cache.dictionary_bytes = @sizeOf(jb2.Image) + image.ownedBytes();
        self.dictionary_bytes += c.cache.dictionary_bytes;
        if (parent) |p| {
            std.debug.assert(components[p].dictionary == image.inherited);
            components[p].cache.children += 1;
        }
        self.touch(components, index);
    }

    /// No allocation is needed to recover memory. Skip dictionaries still
    /// borrowed by cached children; another pass revisits their released parents.
    /// The number of passes is bounded by the dictionary inheritance depth.
    pub fn trim(self: *Cache, allocator: Allocator, components: []Component, limit: usize) void {
        while (self.bytes() > limit) {
            var current = self.first;
            var removed = false;
            while (current) |index| {
                const c = &components[index];
                current = c.cache.next;
                if (c.cache.children != 0) continue;
                self.unlink(components, index);
                if (c.dictionary) |dictionary| {
                    if (c.cache.parent) |parent| components[parent].cache.children -= 1;
                    self.dictionary_bytes -= c.cache.dictionary_bytes;
                    dictionary.deinit(allocator);
                    allocator.destroy(dictionary);
                    c.dictionary = null;
                    c.cache.parent = null;
                    c.cache.dictionary_bytes = 0;
                }
                if (c.owned) |input| {
                    self.encoded_bytes -= input.len;
                    allocator.free(input);
                    c.owned = null;
                    c.form = null;
                }
                removed = true;
                if (self.bytes() <= limit) return;
            }
            std.debug.assert(removed); // Cached dictionary inheritance is acyclic.
        }
    }

    pub fn dropDictionaries(self: *Cache, allocator: Allocator, components: []Component) void {
        // Image.deinit frees only owned storage, so parents can be freed first.
        for (components, 0..) |*c, index| {
            if (c.dictionary) |dictionary| {
                dictionary.deinit(allocator);
                allocator.destroy(dictionary);
                c.dictionary = null;
            }
            c.cache.parent = null;
            c.cache.children = 0;
            c.cache.dictionary_bytes = 0;
            if (c.owned == null) self.unlink(components, index);
        }
        self.dictionary_bytes = 0;
    }

    pub fn clear(self: *Cache, allocator: Allocator, components: []Component) void {
        self.dropDictionaries(allocator, components);
        for (components) |*c| {
            if (c.owned) |input| {
                allocator.free(input);
                c.owned = null;
                c.form = null;
                c.cache = .{};
            }
        }
        self.* = .{};
    }
};
