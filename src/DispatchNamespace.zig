const std = @import("std");
const js = @import("js.zig");
const Fetch = @import("Fetch.zig");

// ===========================================================================
// Dynamic Dispatch — Workers for Platforms (dispatch namespace).
// ===========================================================================

handle: js.Handle,
allocator: std.mem.Allocator,

const DispatchNamespace = @This();

pub fn init(handle: js.Handle, allocator: std.mem.Allocator) DispatchNamespace {
    return .{ .handle = handle, .allocator = allocator };
}

/// Resource limits for the dispatched Worker script.
pub const Limits = struct {
    cpu_ms: ?u32 = null,
    sub_requests: ?u32 = null,
};

/// Options for dispatching a Worker script.
pub const DispatchOptions = struct {
    limits: ?Limits = null,
    /// Outbound worker configuration as a JSON object string.
    outbound: ?[]const u8 = null,
};

/// Look up a Worker script by name in this dispatch namespace and return
/// a Fetcher that can send requests to it.
///
/// ```zig
/// const ns = try env.dispatchNamespace("DISPATCH_NS");
/// const worker = try ns.get("customer-worker", .{});
/// var resp = try worker.fetch("https://fake-host/path", .{});
/// ```
pub fn get(self: *const DispatchNamespace, name: []const u8, options: DispatchOptions) Fetcher {
    const opts_h = js.dispatch_ns_get(
        self.handle,
        name.ptr,
        @intCast(name.len),
        if (options.limits) |l| l.cpu_ms orelse 0 else 0,
        if (options.limits) |l| l.sub_requests orelse 0 else 0,
        if (options.outbound) |o| o.ptr else @as([*]const u8, ""),
        if (options.outbound) |o| @as(u32, @intCast(o.len)) else 0,
    );
    return .{ .handle = opts_h, .allocator = self.allocator };
}

/// A fetcher for a dispatched Worker — can send fetch requests to it.
pub const Fetcher = struct {
    handle: js.Handle,
    allocator: std.mem.Allocator,

    /// Send a fetch request to the dispatched Worker.
    /// JSPI-suspending.
    pub fn fetch(self: *const Fetcher, url: []const u8, options: Fetch.Options) !Fetch.Response {
        const req_h = Fetch.buildRequest(url, options);
        const resp_h = js.dispatch_ns_fetch(self.handle, req_h);
        if (resp_h == js.null_handle) return error.NullHandle;
        return Fetch.Response.init(resp_h, self.allocator);
    }
};
