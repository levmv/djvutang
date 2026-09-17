//! Page rendering test probe with explicit IW44 reduction controls.
const abi = @import("abi");

comptime {
    _ = abi;
}

export fn preview_start(page: u32, width: u32, height: u32, rotation: u32, limit: u32) u32 {
    switch (limit) {
        1, 2, 4, 8, 16, 32 => {},
        else => return 7,
    }
    const status = abi.render_start_sized(page, width, height, rotation, 0, 0, 0, 0);
    if (status != 0) return status;
    const job = abi.probeJob().?;
    job.preview_limit = limit;
    job.retain_preview_coefficients = true;
    return 0;
}

// Zero means no IW44 layer, one means ordinary full reconstruction.
export fn preview_reduction(layer: u32) u32 {
    const job = abi.probeJob() orelse return 0;
    return if (layer < 2) job.iw44_reductions[layer] else 0;
}

export fn preview_has_mask() u32 {
    const job = abi.probeJob() orelse return 0;
    return @intFromBool(job.image != null or job.bitmap != null);
}

// Encoded IW44 dimensions, independent of the selected reconstruction grid.
export fn preview_layer_dimension(layer: u32, axis: u32) u32 {
    const job = abi.probeJob() orelse return 0;
    if (layer >= 2 or axis >= 2 or job.layers[layer].wavelets.items.len == 0) return 0;
    if (job.regional[layer]) |*decoder| return if (axis == 0) decoder.header.width else decoder.header.height;
    const image = (if (layer == 0) job.background else job.foreground) orelse return 0;
    return if (axis == 0) image.width else image.height;
}
