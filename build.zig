const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Expose the workers-zig module for downstream consumers.
    const workers_mod = b.addModule("workers-zig", .{
        .root_source_file = b.path("src/root.zig"),
    });

    // -------------------------------------------------------------------
    // Internal test / example: build the bundled example as a wasm target
    // so `zig build` from the repo root produces a working worker.
    // -------------------------------------------------------------------
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });

    const user_mod = b.createModule(.{
        .root_source_file = b.path("examples/01-hello/src/main.zig"),
        .imports = &.{
            .{ .name = "workers-zig", .module = workers_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "worker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/entry.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "workers-zig", .module = workers_mod },
                .{ .name = "worker_main", .module = user_mod },
            },
        }),
    });
    exe.entry = .disabled;
    exe.rdynamic = true;

    b.installArtifact(exe);

    // Run gen_entry on the compiled wasm to generate entry.js.
    const gen_entry_exe = b.addExecutable(.{
        .name = "gen_entry",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen_entry.zig"),
            .target = b.graph.host,
        }),
    });
    const gen_entry_run = b.addRunArtifact(gen_entry_exe);
    gen_entry_run.addArtifactArg(exe);
    const entry_js = gen_entry_run.addOutputFileArg("entry.js");
    b.getInstallStep().dependOn(&b.addInstallBinFile(entry_js, "entry.js").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(b.path("js/shim.js"), "shim.js").step);
}

// ---------------------------------------------------------------------------
// Public build helper – call from your project's build.zig
// ---------------------------------------------------------------------------
pub const WorkerOptions = struct {
    name: []const u8 = "worker",
    optimize: std.builtin.OptimizeMode = .ReleaseSmall,
};

/// Add a Cloudflare Worker compilation target to your build graph.
///
/// Compiles the user source to wasm, then parses the wasm binary's export
/// section for Durable Object classes (detected via `do_<Name>_fetch` exports)
/// and generates entry.js + copies shim.js into `zig-out/bin/`.
///
/// ```zig
/// const workers_zig = @import("workers-zig");
///
/// pub fn build(b: *std.Build) void {
///     const dep = b.dependency("workers-zig", .{});
///     const exe = workers_zig.addWorker(b, dep, b.path("src/main.zig"), .{});
///     b.installArtifact(exe);
/// }
/// ```
pub fn addWorker(
    b: *std.Build,
    workers_dep: *std.Build.Dependency,
    user_source: std.Build.LazyPath,
    options: WorkerOptions,
) *std.Build.Step.Compile {
    const workers_mod = workers_dep.module("workers-zig");

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });

    const user_mod = b.createModule(.{
        .root_source_file = user_source,
        .imports = &.{
            .{ .name = "workers-zig", .module = workers_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = options.name,
        .root_module = b.createModule(.{
            .root_source_file = workers_dep.path("src/entry.zig"),
            .target = wasm_target,
            .optimize = options.optimize,
            .imports = &.{
                .{ .name = "workers-zig", .module = workers_mod },
                .{ .name = "worker_main", .module = user_mod },
            },
        }),
    });

    exe.entry = .disabled;
    exe.rdynamic = true;

    // Build the gen_entry tool for the host target, then run it on the
    // compiled wasm binary to find DO classes (via `do_<Name>_fetch` exports)
    // and generate entry.js.
    const gen_entry_exe = b.addExecutable(.{
        .name = "gen_entry",
        .root_module = b.createModule(.{
            .root_source_file = workers_dep.path("src/gen_entry.zig"),
            .target = b.graph.host,
        }),
    });

    const gen_entry_run = b.addRunArtifact(gen_entry_exe);
    gen_entry_run.addArtifactArg(exe); // input: the compiled wasm binary
    const entry_js = gen_entry_run.addOutputFileArg("entry.js"); // output: generated entry.js

    // Install entry.js and shim.js to zig-out/bin/
    b.getInstallStep().dependOn(&b.addInstallBinFile(entry_js, "entry.js").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(workers_dep.path("js/shim.js"), "shim.js").step);

    return exe;
}
