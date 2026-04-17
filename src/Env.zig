const std = @import("std");
const js = @import("js.zig");
pub const KvNamespace = @import("KvNamespace.zig");
pub const R2Bucket = @import("R2Bucket.zig");
pub const D1Database = @import("D1Database.zig");
pub const DurableObject = @import("DurableObject.zig");
pub const WorkerLoader = @import("WorkerLoader.zig");
pub const Ai = @import("Ai.zig");
pub const Queue = @import("Queue.zig");
pub const AnalyticsEngine = @import("AnalyticsEngine.zig");
pub const RateLimit = @import("RateLimit.zig");
pub const Hyperdrive = @import("Hyperdrive.zig");
pub const ServiceBinding = @import("ServiceBinding.zig");
pub const DispatchNamespace = @import("DispatchNamespace.zig");
pub const Vectorize = @import("Vectorize.zig");
pub const Workflow = @import("Workflow.zig");
pub const SendEmail = @import("SendEmail.zig");
pub const Artifacts = @import("Artifacts.zig");

handle: js.Handle,
allocator: std.mem.Allocator,

const Env = @This();

pub fn init(handle: js.Handle, allocator: std.mem.Allocator) Env {
    return .{ .handle = handle, .allocator = allocator };
}

/// Get a text binding (environment variable or secret) by name.
/// Returns null if the binding does not exist or is not a string.
pub fn get(self: *const Env, name: []const u8) !?[]const u8 {
    const str_handle = js.env_get_text_binding(self.handle, name.ptr, @intCast(name.len));
    if (str_handle == js.null_handle) return null;
    const str = try js.readString(str_handle, self.allocator);
    return str;
}

/// Generic binding accessor. Returns a binding of the given type, looked up
/// by the name declared in wrangler.toml. The name is comptime-known since
/// bindings are always static configuration.
///
/// ```zig
/// const ai = try env.binding(workers.Ai, "AI");
/// const kv = try env.binding(workers.KvNamespace, "MY_KV");
/// const ns = try env.binding(workers.DurableObject.Namespace, "COUNTER");
/// ```
pub fn binding(self: *const Env, comptime T: type, comptime name: []const u8) !T {
    const h = js.env_get_binding(self.handle, name.ptr, name.len);
    if (h == js.null_handle) return error.BindingNotFound;
    return T.init(h, self.allocator);
}

// -- Convenience accessors (delegate to binding) ---------------------------

pub fn kv(self: *const Env, comptime name: []const u8) !KvNamespace {
    return self.binding(KvNamespace, name);
}

pub fn r2(self: *const Env, comptime name: []const u8) !R2Bucket {
    return self.binding(R2Bucket, name);
}

pub fn d1(self: *const Env, comptime name: []const u8) !D1Database {
    return self.binding(D1Database, name);
}

pub fn durableObject(self: *const Env, comptime name: []const u8) !DurableObject.Namespace {
    return self.binding(DurableObject.Namespace, name);
}

pub fn workerLoader(self: *const Env, comptime name: []const u8) !WorkerLoader {
    return self.binding(WorkerLoader, name);
}

pub fn ai(self: *const Env, comptime name: []const u8) !Ai {
    return self.binding(Ai, name);
}

pub fn queue(self: *const Env, comptime name: []const u8) !Queue {
    return self.binding(Queue, name);
}

pub fn analyticsEngine(self: *const Env, comptime name: []const u8) !AnalyticsEngine {
    return self.binding(AnalyticsEngine, name);
}

pub fn rateLimit(self: *const Env, comptime name: []const u8) !RateLimit {
    return self.binding(RateLimit, name);
}

pub fn hyperdrive(self: *const Env, comptime name: []const u8) !Hyperdrive {
    return self.binding(Hyperdrive, name);
}

pub fn serviceBinding(self: *const Env, comptime name: []const u8) !ServiceBinding {
    return self.binding(ServiceBinding, name);
}

pub fn dispatchNamespace(self: *const Env, comptime name: []const u8) !DispatchNamespace {
    return self.binding(DispatchNamespace, name);
}

pub fn vectorize(self: *const Env, comptime name: []const u8) !Vectorize {
    return self.binding(Vectorize, name);
}

pub fn workflow(self: *const Env, comptime name: []const u8) !Workflow {
    return self.binding(Workflow, name);
}

pub fn sendEmail(self: *const Env, comptime name: []const u8) !SendEmail {
    return self.binding(SendEmail, name);
}

pub fn artifacts(self: *const Env, comptime name: []const u8) !Artifacts {
    return self.binding(Artifacts, name);
}
