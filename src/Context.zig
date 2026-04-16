const js = @import("js.zig");

handle: js.Handle,

const Context = @This();

pub fn init(handle: js.Handle) Context {
    return .{ .handle = handle };
}

/// Register a promise/task that should continue running even after the
/// response has been sent.  Keeps the Worker alive until the task settles.
pub fn waitUntil(self: *const Context, promise_handle: js.Handle) void {
    js.ctx_wait_until(self.handle, promise_handle);
}

/// Tell the runtime to forward the request to the origin if the Worker
/// throws an unhandled exception, instead of returning an error response.
pub fn passThroughOnException(self: *const Context) void {
    js.ctx_pass_through_on_exception(self.handle);
}
