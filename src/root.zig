const std = @import("std");

pub const Request = @import("Request.zig");
pub const Response = @import("Response.zig");
pub const Env = @import("Env.zig");
pub const Context = @import("Context.zig");
pub const KvNamespace = @import("KvNamespace.zig");
pub const R2Bucket = @import("R2Bucket.zig");
pub const D1Database = @import("D1Database.zig");
pub const Async = @import("Async.zig");
pub const Cache = @import("Cache.zig");
pub const Fetch = @import("Fetch.zig");
pub const ScheduledEvent = @import("ScheduledEvent.zig");
pub const StreamingResponse = @import("StreamingResponse.zig");
pub const WebSocket = @import("WebSocket.zig");
pub const DurableObject = @import("DurableObject.zig");
pub const WorkerLoader = @import("WorkerLoader.zig");
pub const Container = @import("Container.zig");
pub const Ai = @import("Ai.zig");
pub const Queue = @import("Queue.zig");
pub const AnalyticsEngine = @import("AnalyticsEngine.zig");
pub const RateLimit = @import("RateLimit.zig");
pub const Hyperdrive = @import("Hyperdrive.zig");
pub const ServiceBinding = @import("ServiceBinding.zig");
pub const DispatchNamespace = @import("DispatchNamespace.zig");
pub const Vectorize = @import("Vectorize.zig");
pub const Socket = @import("Socket.zig");
pub const Crypto = @import("Crypto.zig");
pub const EventSource = @import("EventSource.zig");
pub const FormData = @import("FormData.zig");
pub const HTMLRewriter = @import("HTMLRewriter.zig");
pub const Workflow = @import("Workflow.zig");
pub const Tail = @import("Tail.zig");
pub const EmailMessage = @import("EmailMessage.zig");
pub const SendEmail = @import("SendEmail.zig");
pub const Artifacts = @import("Artifacts.zig");
pub const Router = @import("Router.zig");
pub const js = @import("js.zig");

// Re-export standard HTTP types for convenience.
pub const Method = std.http.Method;
pub const Status = std.http.Status;
pub const Header = std.http.Header;

/// Execute an outbound HTTP request (JSPI-suspending).
pub fn fetch(alloc: std.mem.Allocator, url: []const u8, options: Fetch.Options) !Fetch.Response {
    return Fetch.send(alloc, url, options);
}

/// Return the current time as milliseconds since the Unix epoch (Date.now()).
pub fn now() f64 {
    return js.js_now();
}

/// Return an `std.Io` instance suitable for use in Workers isolates.
///
/// Workers run single-threaded inside a V8 isolate, so the stdlib's
/// `init_single_threaded` vtable is exactly what we want: its `now` routes
/// to WASI `clock_time_get` and its `randomSecure` routes to `random_get`.
pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// A process-lifetime allocator backed by the wasm linear memory.
///
/// For most `fetch` handler work, prefer `env.allocator` — it is a
/// per-request arena that is freed automatically when the request ends.
/// Reach for `workers.allocator` when you need memory that outlives a
/// single request (Durable Object state, outbound WebSockets, long-lived
/// caches) or in contexts where no `Env` is available.
pub const allocator: std.mem.Allocator = std.heap.wasm_allocator;

/// Sleep for the given number of milliseconds (JSPI-suspending).
pub fn sleep(ms: u32) void {
    js.js_sleep(ms);
}

/// Log a formatted message to the JS console.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch {
        const truncated = "[workers-zig] log message too long";
        js.console_error(truncated, truncated.len);
        return;
    };
    js.console_log(msg.ptr, @intCast(msg.len));
}
