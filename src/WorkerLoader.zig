const std = @import("std");
const js = @import("js.zig");
const Fetch = @import("Fetch.zig");
const DurableObject = @import("DurableObject.zig");

// ===========================================================================
// Dynamic Worker Loader — load and run workers at runtime.
// ===========================================================================

handle: js.Handle,
allocator: std.mem.Allocator,

const WorkerLoader = @This();

pub fn init(handle: js.Handle, allocator: std.mem.Allocator) WorkerLoader {
    return .{ .handle = handle, .allocator = allocator };
}

/// Load a worker by name with lazily-provided code.
/// The `name` is used for caching — subsequent calls with the same name
/// may return the same instance. Pass null for anonymous/one-shot workers.
pub fn get(self: *const WorkerLoader, name: ?[]const u8, code: WorkerCode) WorkerStub {
    const n_ptr = if (name) |n| n.ptr else @as([*]const u8, "");
    const n_len: u32 = if (name) |n| @intCast(n.len) else 0;
    const h = js.wl_get(self.handle, n_ptr, n_len, code.handle);
    return .{ .handle = h, .allocator = self.allocator };
}

/// Load a worker immediately from the provided code.
pub fn load(self: *const WorkerLoader, code: WorkerCode) WorkerStub {
    const h = js.wl_load(self.handle, code.handle);
    return .{ .handle = h, .allocator = self.allocator };
}

// ===========================================================================
// WorkerCode — builder for WorkerLoaderWorkerCode
// ===========================================================================

/// Describes a worker to be dynamically loaded.
/// Built incrementally, then consumed by `WorkerLoader.get()` or `.load()`.
///
/// ```zig
/// var code = WorkerCode.init("2025-04-01", "index.js");
/// code.addJsModule("index.js",
///     \\export default {
///     \\  async fetch(req) { return new Response("hello from dynamic worker"); }
///     \\};
/// );
/// code.setCpuMs(50);
/// const stub = loader.load(code);
/// ```
pub const WorkerCode = struct {
    handle: js.Handle,

    pub fn init(compat_date: []const u8, main_module: []const u8) WorkerCode {
        return .{
            .handle = js.wl_code_new(
                compat_date.ptr,
                @intCast(compat_date.len),
                main_module.ptr,
                @intCast(main_module.len),
            ),
        };
    }

    /// Add a compatibility flag (e.g. "nodejs_compat").
    pub fn addCompatFlag(self: *WorkerCode, flag: []const u8) void {
        js.wl_code_set_compat_flag(self.handle, flag.ptr, @intCast(flag.len));
    }

    /// Set CPU time limit in milliseconds.
    pub fn setCpuMs(self: *WorkerCode, ms: u32) void {
        js.wl_code_set_cpu_ms(self.handle, ms);
    }

    /// Set maximum number of sub-requests.
    pub fn setSubRequests(self: *WorkerCode, n: u32) void {
        js.wl_code_set_sub_requests(self.handle, n);
    }

    /// Set environment variables as a JSON object string.
    pub fn setEnvJson(self: *WorkerCode, json: []const u8) void {
        js.wl_code_set_env_json(self.handle, json.ptr, @intCast(json.len));
    }

    /// Set the global outbound fetcher. Pass null to block network access.
    pub fn setGlobalOutbound(self: *WorkerCode, fetcher_handle: ?js.Handle) void {
        js.wl_code_set_global_outbound(self.handle, fetcher_handle orelse js.null_handle);
    }

    pub const ModuleType = enum(u32) {
        js = 0,
        cjs = 1,
        text = 2,
        data = 3,
        json = 4,
        py = 5,
        wasm = 6,
    };

    /// Add a text-based module (JS, CJS, text, JSON, Python source).
    pub fn addModuleString(self: *WorkerCode, name: []const u8, mod_type: ModuleType, content: []const u8) void {
        js.wl_code_add_module_string(
            self.handle,
            name.ptr,
            @intCast(name.len),
            @intFromEnum(mod_type),
            content.ptr,
            @intCast(content.len),
        );
    }

    /// Add a binary module (data or wasm ArrayBuffer).
    pub fn addModuleBytes(self: *WorkerCode, name: []const u8, mod_type: ModuleType, content: []const u8) void {
        js.wl_code_add_module_bytes(
            self.handle,
            name.ptr,
            @intCast(name.len),
            @intFromEnum(mod_type),
            content.ptr,
            @intCast(content.len),
        );
    }

    // -- Convenience methods --------------------------------------------------

    /// Add an ES module (JavaScript source).
    pub fn addJsModule(self: *WorkerCode, name: []const u8, source: []const u8) void {
        self.addModuleString(name, .js, source);
    }

    /// Add a CommonJS module.
    pub fn addCjsModule(self: *WorkerCode, name: []const u8, source: []const u8) void {
        self.addModuleString(name, .cjs, source);
    }

    /// Add a Wasm module (binary bytes).
    pub fn addWasmModule(self: *WorkerCode, name: []const u8, bytes: []const u8) void {
        self.addModuleBytes(name, .wasm, bytes);
    }

    /// Add a text module.
    pub fn addTextModule(self: *WorkerCode, name: []const u8, content: []const u8) void {
        self.addModuleString(name, .text, content);
    }

    /// Add a JSON module (content should be a valid JSON string).
    pub fn addJsonModule(self: *WorkerCode, name: []const u8, json: []const u8) void {
        self.addModuleString(name, .json, json);
    }
};

// ===========================================================================
// WorkerStub — handle to a dynamically loaded worker
// ===========================================================================

/// A handle to a dynamically loaded worker.
/// Use `getEntrypoint()` to get a Fetcher for sending requests,
/// or `getDurableObjectClass()` to access DOs from the loaded worker.
pub const WorkerStub = struct {
    handle: js.Handle,
    allocator: std.mem.Allocator,

    /// Get a Fetcher for the default or named entrypoint.
    pub fn getEntrypoint(self: *const WorkerStub, name: ?[]const u8) DurableObject.Fetcher {
        const n_ptr = if (name) |n| n.ptr else @as([*]const u8, "");
        const n_len: u32 = if (name) |n| @intCast(n.len) else 0;
        const h = js.wl_stub_get_entrypoint(self.handle, n_ptr, n_len);
        return .{ .handle = h, .allocator = self.allocator };
    }

    /// Get a DurableObjectClass from the loaded worker's exports.
    /// Pass the result to `Facets.get()` to create a facet from this class.
    pub fn getDurableObjectClass(self: *const WorkerStub, name: ?[]const u8) DurableObject.DurableObjectClass {
        const n_ptr = if (name) |n| n.ptr else @as([*]const u8, "");
        const n_len: u32 = if (name) |n| @intCast(n.len) else 0;
        return .{ .handle = js.wl_stub_get_do_class(self.handle, n_ptr, n_len) };
    }

    /// Send a fetch request directly to the loaded worker's default entrypoint.
    pub fn fetch(self: *const WorkerStub, url: []const u8, options: Fetch.Options) !Fetch.Response {
        const fetcher = self.getEntrypoint(null);
        return fetcher.fetch(url, options);
    }
};
