const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default ReleaseSafe)") orelse .ReleaseSafe;
    const core = b.addModule("djvutang", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });
    addJpeg(b, core);
    const test_module = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    addJpeg(b, test_module);
    const tests = b.addTest(.{ .root_module = test_module, .use_llvm = true });
    b.step("test", "Run native decoder tests").dependOn(&b.addRunArtifact(tests).step);

    const cli = b.addExecutable(.{
        .name = "djvutang",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "djvutang", .module = core }},
        }),
    });
    b.installArtifact(cli);

    const bench = b.addExecutable(.{
        .name = "djvutang-bench",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "djvutang", .module = core }},
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| run_bench.addArgs(args);
    b.step("bench", "Measure native cover rendering; pass input files after --").dependOn(&run_bench.step);

    const wasm_simd = b.option(bool, "wasm-simd", "Enable 128-bit SIMD in the WASM module (requires host support)") orelse false;
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = if (wasm_simd) std.Target.wasm.featureSet(&.{.simd128}) else .empty,
    });
    const wasm_core = b.createModule(.{
        .root_source_file = b.path("root.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .strip = true,
    });
    addJpeg(b, wasm_core);
    const wasm = b.addExecutable(.{
        .name = "djvutang",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("wasm/main.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .strip = true,
            .imports = &.{.{ .name = "djvutang", .module = wasm_core }},
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.stack_size = 1024 * 1024;
    wasm.max_memory = @import("wasm/heap.zig").max_memory;
    const install_wasm = b.addInstallArtifact(wasm, .{});
    b.step("wasm", "Build WASM without WASI or libc").dependOn(&install_wasm.step);

    const preview = b.addExecutable(.{
        .name = "preview-probe",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/wasm/preview.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .strip = true,
            .imports = &.{.{ .name = "abi", .module = wasm.root_module }},
        }),
    });
    preview.entry = .disabled;
    preview.rdynamic = true;
    preview.stack_size = 1024 * 1024;
    preview.max_memory = @import("wasm/heap.zig").max_memory;
    b.step("preview-probe-wasm", "Build the page rendering test probe").dependOn(&b.addInstallArtifact(preview, .{}).step);

    const heap_test = b.addExecutable(.{
        .name = "heap-test",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/wasm/heap.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "heap", .module = b.createModule(.{
                .root_source_file = b.path("wasm/heap.zig"),
                .target = wasm_target,
                .optimize = optimize,
            }) }},
        }),
    });
    heap_test.entry = .disabled;
    heap_test.rdynamic = true;
    heap_test.stack_size = 64 * 1024;
    heap_test.max_memory = 8 * 1024 * 1024;
    b.step("heap-test-wasm", "Check WASM allocation reuse and failure under a small memory ceiling").dependOn(&b.addInstallArtifact(heap_test, .{}).step);

    // The codec probe exposes reconstruction state used by the WASM tests.
    const iw44_wasm = b.addExecutable(.{
        .name = "iw44-probe",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/wasm/iw44.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "iw44_probe", .module = iw44Probe(b, wasm_target, optimize) }},
        }),
    });
    iw44_wasm.entry = .disabled;
    iw44_wasm.rdynamic = true;
    iw44_wasm.stack_size = 1024 * 1024;
    iw44_wasm.max_memory = 256 * 1024 * 1024;
    const install_probe = b.addInstallArtifact(iw44_wasm, .{});
    b.step("iw44-probe-wasm", "Build the IW44 test probe").dependOn(&install_probe.step);
}

fn iw44Probe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("tests/support/iw44-probe.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "iw44", .module = b.createModule(.{ .root_source_file = b.path("src/iw44.zig"), .target = target, .optimize = optimize }) },
            .{ .name = "budget", .module = b.createModule(.{ .root_source_file = b.path("src/budget.zig"), .target = target, .optimize = optimize }) },
        },
    });
}

fn addJpeg(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("vendor/stb"));
    module.addIncludePath(b.path("src/c-compat"));
    // Zig 0.16's fuzz runtime uses a different PC table from Clang and lacks
    // its trace-cmp callbacks. JPEG still runs, but only Zig supplies coverage.
    module.addCSourceFile(.{
        .file = b.path("src/jpeg_stb.c"),
        .flags = &.{
            "-std=c11",
            "-fwrapv",
            "-fno-sanitize-coverage=trace-cmp,inline-8bit-counters,pc-table,indirect-calls",
        },
    });
}
