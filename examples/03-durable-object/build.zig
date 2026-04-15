const std = @import("std");
const workers_zig = @import("workers-zig");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("workers-zig", .{});

    const exe = workers_zig.addWorker(b, dep, b.path("src/main.zig"), .{
        .name = "worker",
        .optimize = optimize,
    });

    b.installArtifact(exe);
}
