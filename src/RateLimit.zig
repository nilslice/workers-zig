const std = @import("std");
const js = @import("js.zig");

// ===========================================================================
// Rate Limiting — rate limit requests by key.
// ===========================================================================

handle: js.Handle,
allocator: std.mem.Allocator,

const RateLimit = @This();

pub fn init(handle: js.Handle, allocator: std.mem.Allocator) RateLimit {
    return .{ .handle = handle, .allocator = allocator };
}

pub const Outcome = struct {
    success: bool,
};

/// Check if a request should be rate limited.
/// Returns `success: true` if the request is allowed, `false` if rate limited.
/// JSPI-suspending.
pub fn limit(self: *const RateLimit, key: []const u8) Outcome {
    const result = js.rate_limit(self.handle, key.ptr, @intCast(key.len));
    return .{ .success = result != 0 };
}
