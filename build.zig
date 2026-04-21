const std = @import("std");

/// Derive the library version from build.zig.zon so it never goes stale.
const workers_zig_version = blk: {
    const zon = @embedFile("build.zig.zon");
    const key = ".version = \"";
    const start = std.mem.indexOf(u8, zon, key) orelse break :blk "unknown";
    const after = start + key.len;
    const end = std.mem.indexOfScalarPos(u8, zon, after, '"') orelse break :blk "unknown";
    break :blk zon[after..end];
};

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

    // Re-usable build tools (compiled once, used by root worker + all examples).
    const inject_exe = b.addExecutable(.{
        .name = "inject_producers",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/inject_producers.zig"),
            .target = b.graph.host,
        }),
    });
    const gen_entry_exe = b.addExecutable(.{
        .name = "gen_entry",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen_entry.zig"),
            .target = b.graph.host,
        }),
    });

    const artifacts = setupWorkerPostProcess(b, inject_exe, gen_entry_exe, exe);
    b.getInstallStep().dependOn(&b.addInstallBinFile(artifacts.wasm, "worker.wasm").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(artifacts.entry_js, "entry.js").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(b.path("js/shim.js"), "shim.js").step);

    // -------------------------------------------------------------------
    // Build all examples
    // -------------------------------------------------------------------
    const examples = .{
        .{ "01-hello", "hello" },
        .{ "02-kv-r2", "kv-r2" },
        .{ "03-durable-object", "durable-object" },
        .{ "04-websocket-ai", "websocket-ai" },
        .{ "05-tcp-echo", "tcp-echo" },
    };

    const examples_step = b.step("examples", "Build all examples");

    inline for (examples) |entry| {
        const dir = entry[0];
        const name = entry[1];

        const ex_user_mod = b.createModule(.{
            .root_source_file = b.path("examples/" ++ dir ++ "/src/main.zig"),
            .imports = &.{
                .{ .name = "workers-zig", .module = workers_mod },
            },
        });

        const ex_exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/entry.zig"),
                .target = wasm_target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "workers-zig", .module = workers_mod },
                    .{ .name = "worker_main", .module = ex_user_mod },
                },
            }),
        });
        ex_exe.entry = .disabled;
        ex_exe.rdynamic = true;

        const ex_artifacts = setupWorkerPostProcess(b, inject_exe, gen_entry_exe, ex_exe);
        const ex_install = b.addInstallBinFile(ex_artifacts.wasm, "examples/" ++ dir ++ "/worker.wasm");
        const ex_install_entry = b.addInstallBinFile(ex_artifacts.entry_js, "examples/" ++ dir ++ "/entry.js");
        const ex_install_shim = b.addInstallBinFile(b.path("js/shim.js"), "examples/" ++ dir ++ "/shim.js");

        const ex_step = b.step("example-" ++ name, "Build the " ++ dir ++ " example");
        ex_step.dependOn(&ex_install.step);
        ex_step.dependOn(&ex_install_entry.step);
        ex_step.dependOn(&ex_install_shim.step);

        examples_step.dependOn(ex_step);
    }

    // -------------------------------------------------------------------
    // Tests — run unit tests for all source files that contain test blocks.
    // Tests are pure logic (JSON building, parsing, routing) and run on
    // the host target without needing WASM/FFI.
    // -------------------------------------------------------------------
    const test_files = .{
        "src/Ai.zig",
        "src/Crypto.zig",
        "src/HTMLRewriter.zig",
        "src/Queue.zig",
        "src/Request.zig",
        "src/Router.zig",
        "src/SendEmail.zig",
        "src/Tail.zig",
        "src/Vectorize.zig",
        "src/Workflow.zig",
    };

    const test_step = b.step("test", "Run unit tests");

    inline for (test_files) |file| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = b.graph.host,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
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

    // Tools live inside the downstream build graph (they are created per call
    // to addWorker because each project has its own b.* namespace).
    const inject_exe = b.addExecutable(.{
        .name = "inject_producers",
        .root_module = b.createModule(.{
            .root_source_file = workers_dep.path("src/inject_producers.zig"),
            .target = b.graph.host,
        }),
    });
    const gen_entry_exe = b.addExecutable(.{
        .name = "gen_entry",
        .root_module = b.createModule(.{
            .root_source_file = workers_dep.path("src/gen_entry.zig"),
            .target = b.graph.host,
        }),
    });

    const artifacts = setupWorkerPostProcess(b, inject_exe, gen_entry_exe, exe);
    const wasm_name = std.mem.concat(b.allocator, u8, &.{ options.name, ".wasm" }) catch @panic("OOM");
    b.getInstallStep().dependOn(&b.addInstallBinFile(artifacts.wasm, wasm_name).step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(artifacts.entry_js, "entry.js").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(workers_dep.path("js/shim.js"), "shim.js").step);

    return exe;
}

/// Shared post-processing: run inject_producers and gen_entry on a compiled wasm
/// executable. Returns the post-processed wasm and generated entry.js.
fn setupWorkerPostProcess(
    b: *std.Build,
    inject_exe: *std.Build.Step.Compile,
    gen_entry_exe: *std.Build.Step.Compile,
    exe: *std.Build.Step.Compile,
) struct { wasm: std.Build.LazyPath, entry_js: std.Build.LazyPath } {
    const inject_run = b.addRunArtifact(inject_exe);
    inject_run.addArtifactArg(exe);
    const wasm = inject_run.addOutputFileArg("worker.wasm");
    inject_run.addArg("sdk");
    inject_run.addArg("workers-zig");
    inject_run.addArg(workers_zig_version);

    const gen_entry_run = b.addRunArtifact(gen_entry_exe);
    gen_entry_run.addArtifactArg(exe);
    const entry_js = gen_entry_run.addOutputFileArg("entry.js");

    return .{ .wasm = wasm, .entry_js = entry_js };
}
