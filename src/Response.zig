const std = @import("std");
const http = std.http;
const js = @import("js.zig");

pub const Status = http.Status;

handle: js.Handle,

const Response = @This();

/// Create a new empty response (defaults to 200 OK).
pub fn new() Response {
    return .{ .handle = js.response_new() };
}

pub fn setStatus(self: *Response, code: http.Status) void {
    js.response_set_status(self.handle, @intFromEnum(code));
}

pub fn setHeader(self: *Response, name: []const u8, value: []const u8) void {
    js.response_set_header(
        self.handle,
        name.ptr,
        @intCast(name.len),
        value.ptr,
        @intCast(value.len),
    );
}

pub fn setBody(self: *Response, data: []const u8) void {
    js.response_set_body(self.handle, data.ptr, @intCast(data.len));
}

// ---- Convenience constructors ------------------------------------------------

/// 200 OK with a plain-text body.
pub fn ok(text: []const u8) Response {
    var resp = new();
    resp.setStatus(.ok);
    resp.setHeader("content-type", "text/plain; charset=utf-8");
    resp.setBody(text);
    return resp;
}

/// 200 OK with a pre-serialized JSON body.
pub fn json(data: []const u8) Response {
    var resp = new();
    resp.setStatus(.ok);
    resp.setHeader("content-type", "application/json");
    resp.setBody(data);
    return resp;
}

/// 200 OK with a JSON body serialized from any Zig value.
///
/// ```zig
/// return workers.Response.jsonValue(allocator, .{ .ok = true, .count = 42 });
/// ```
pub fn jsonValue(allocator: std.mem.Allocator, data: anytype) !Response {
    const bytes = try std.json.stringifyAlloc(allocator, data, .{});
    var resp = new();
    resp.setStatus(.ok);
    resp.setHeader("content-type", "application/json");
    resp.setBody(bytes);
    return resp;
}

/// 200 OK with an HTML body.
pub fn html(data: []const u8) Response {
    var resp = new();
    resp.setStatus(.ok);
    resp.setHeader("content-type", "text/html; charset=utf-8");
    resp.setBody(data);
    return resp;
}

/// Empty response with the given status code.
pub fn status(code: http.Status) Response {
    var resp = new();
    resp.setStatus(code);
    return resp;
}

/// Error response with a plain-text message.
pub fn err(code: http.Status, message: []const u8) Response {
    var resp = new();
    resp.setStatus(code);
    resp.setHeader("content-type", "text/plain; charset=utf-8");
    resp.setBody(message);
    return resp;
}

/// Redirect response (302 by default, or specify 301/307/308).
///
/// ```zig
/// return workers.Response.redirect("/new-location", null);       // 302
/// return workers.Response.redirect("/moved", .moved_permanently); // 301
/// ```
pub fn redirect(url: []const u8, code: ?http.Status) Response {
    const s: u32 = if (code) |c| @intFromEnum(c) else 302;
    return .{ .handle = js.response_redirect(url.ptr, @intCast(url.len), s) };
}

/// Clone this response. Both the original and the clone can be used
/// independently (e.g. caching one while returning the other).
pub fn clone(self: *const Response) Response {
    return .{ .handle = js.response_clone(self.handle) };
}

/// Static constructor that JSON-serializes a Zig value and returns a
/// 200 JSON response.  `data` must be a pre-serialized JSON string.
/// (Mirrors the JS `Response.json(data)` static method.)
pub fn jsonWithStatus(data: []const u8, code: http.Status) Response {
    var resp = new();
    resp.setStatus(code);
    resp.setHeader("content-type", "application/json");
    resp.setBody(data);
    return resp;
}
