pub const Error = error{ InvalidData, Unsupported, LimitExceeded, Cancelled, OutOfMemory, InvalidArgument, Busy, MissingComponent };

/// Resource limits, independent of the format's theoretical range.
pub const Limits = struct {
    max_input_bytes: usize = 128 * 1024 * 1024,
    max_bzz_bytes: usize = 16 * 1024 * 1024,
    max_page_pixels: usize = 64 * 1024 * 1024,
    max_shape_pixels: usize = 16 * 1024 * 1024,
    max_shapes: usize = 100_000,
    max_blits: usize = 1_000_000,
    max_cells: usize = 1_000_000,
    max_records: usize = 2_000_000,
    max_components: usize = 65_535,
    max_chunks: usize = 1_000_000,
    max_include_depth: usize = 64,
    max_iw_slices: usize = 512,
    max_jpeg_scans: usize = 256,
    max_jpeg_blocks: usize = 16 * 1024 * 1024,
    max_text_bytes: usize = 4 * 1024 * 1024,
    max_text_zones: usize = 100_000,
    max_text_depth: usize = 64,
    max_annotation_bytes: usize = 4 * 1024 * 1024,
    max_annotation_nodes: usize = 100_000,
    max_annotation_depth: usize = 64,
    max_outline_bytes: usize = 4 * 1024 * 1024,
    max_outline_entries: usize = 65_535,
    max_outline_depth: usize = 64,
};
