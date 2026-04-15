const std = @import("std");
const js = @import("js.zig");
const Fetch = @import("Fetch.zig");

// ===========================================================================
// Service Binding — Worker-to-Worker RPC via fetch.
// ===========================================================================

handle: js.Handle,
allocator: std.mem.Allocator,

const ServiceBinding = @This();

pub fn init(handle: js.Handle, allocator: std.mem.Allocator) ServiceBinding {
    return .{ .handle = handle, .allocator = allocator };
}

/// Send a fetch request to the bound service worker.
/// JSPI-suspending.
pub fn fetch(self: *const ServiceBinding, url: []const u8, options: Fetch.Options) !Fetch.Response {
    const req_h = Fetch.buildRequest(url, options);
    const resp_h = js.service_binding_fetch(self.handle, req_h);
    if (resp_h == js.null_handle) return error.NullHandle;
    return Fetch.Response.init(resp_h, self.allocator);
}
