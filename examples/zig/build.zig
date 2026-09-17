const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("djvutang", .{ .target = target, .optimize = optimize });
    const app = b.addExecutable(.{
        .name = "preview",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "djvutang", .module = dependency.module("djvutang") }},
        }),
    });
    b.installArtifact(app);
    const run = b.addRunArtifact(app);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Render the first page to PPM").dependOn(&run.step);
}
