// Keep the module root here so suites can import src/ and embed fixtures.
test {
    _ = @import("tests/native/core.zig");
    _ = @import("tests/native/jb2.zig");
    _ = @import("tests/native/composite.zig");
    _ = @import("tests/native/source.zig");
    _ = @import("tests/native/regions.zig");
    _ = @import("tests/native/text.zig");
    _ = @import("tests/native/mmr.zig");
    _ = @import("tests/native/jpeg.zig");
    _ = @import("tests/native/components.zig");
    _ = @import("tests/native/annotations.zig");
    _ = @import("tests/native/outline.zig");
    _ = @import("tests/native/thumbnails.zig");
    _ = @import("tests/native/iw44-document.zig");
    _ = @import("tests/native/iw44-regions.zig");
    _ = @import("tests/native/iw44-storage.zig");
    _ = @import("tests/native/iw44-reduced.zig");
    _ = @import("tests/native/preview.zig");
    _ = @import("tests/native/palette.zig");
    _ = @import("tests/fuzz/native.zig");
}
