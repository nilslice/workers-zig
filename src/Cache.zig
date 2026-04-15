const std = @import("std");
const js = @import("js.zig");
const Request = @import("Request.zig");
const Response = @import("Response.zig");

handle: js.Handle,

const Cache = @This();

/// Cache key: either a URL path string or the original Request object.
/// Using the Request preserves the full URL, method, and headers for
/// `Vary`-aware matching.
///
/// ```zig
/// cache.match(.{ .url = "/api/data" });
/// cache.match(.{ .request = request });
/// ```
pub const Key = union(enum) {
    url: []const u8,
    request: *const Request,
};

/// Get the default cache (`caches.default`).
pub fn default() Cache {
    return .{ .handle = js.cache_default() };
}

/// Open a named cache (`caches.open(name)`).  JSPI-suspending.
pub fn open(name: []const u8) Cache {
    return .{ .handle = js.cache_open(name.ptr, @intCast(name.len)) };
}

/// Look up a key in the cache.  Returns the cached Response, or null if
/// there is no match.  JSPI-suspending.
///
/// ```zig
/// const cache = workers.Cache.default();
/// if (cache.match(.{ .request = request })) |resp| {
///     return resp;  // serve from cache
/// }
/// ```
pub fn match(self: *const Cache, key: Key) ?Response {
    const h = switch (key) {
        .url => |u| js.cache_match(self.handle, u.ptr, @intCast(u.len)),
        .request => |r| js.cache_match_request(self.handle, r.handle),
    };
    if (h == js.null_handle) return null;
    return .{ .handle = h };
}

/// Store a Response in the cache.  JSPI-suspending.
///
/// ```zig
/// var resp = workers.Response.ok("data");
/// resp.setHeader("cache-control", "max-age=3600");
/// cache.put(.{ .request = request }, &resp);
/// ```
pub fn put(self: *const Cache, key: Key, response: *const Response) void {
    switch (key) {
        .url => |u| js.cache_put(self.handle, u.ptr, @intCast(u.len), response.handle),
        .request => |r| js.cache_put_request(self.handle, r.handle, response.handle),
    }
}

/// Delete a key from the cache.  Returns true if the entry was found and
/// deleted.  JSPI-suspending.
pub fn delete(self: *const Cache, key: Key) bool {
    const v = switch (key) {
        .url => |u| js.cache_delete(self.handle, u.ptr, @intCast(u.len)),
        .request => |r| js.cache_delete_request(self.handle, r.handle),
    };
    return v != 0;
}
