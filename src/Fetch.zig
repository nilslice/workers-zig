const std = @import("std");
const http = std.http;
const Io = std.Io;
const js = @import("js.zig");

const FormData = @import("FormData.zig");

/// Request body — either raw bytes or a FormData object.
pub const Body = union(enum) {
    /// Raw bytes (caller sets Content-Type).
    bytes: []const u8,
    /// FormData — the runtime automatically encodes as
    /// multipart/form-data and sets the Content-Type + boundary.
    form: FormData,
    /// No body.
    none,
};

/// Options for an outbound fetch request.
pub const Options = struct {
    method: http.Method = .GET,
    headers: []const http.Header = &.{},
    body: Body = .none,
};

/// Response from an outbound fetch.  Body is lazily read and cached on
/// first access.  The handle is released on `deinit`.
pub const Response = struct {
    handle: js.Handle,
    allocator: std.mem.Allocator,
    _body: ?[]const u8 = null,

    pub fn init(handle: js.Handle, allocator: std.mem.Allocator) Response {
        return .{ .handle = handle, .allocator = allocator };
    }

    pub fn deinit(self: *Response) void {
        if (self.handle != js.null_handle) {
            js.js_release(self.handle);
            self.handle = js.null_handle;
        }
    }

    /// HTTP status code as std.http.Status.
    pub fn status(self: *const Response) http.Status {
        return @enumFromInt(js.fetch_response_status(self.handle));
    }

    /// True if the status code is in the 200–299 range.
    pub fn ok(self: *const Response) bool {
        const s = js.fetch_response_status(self.handle);
        return s >= 200 and s <= 299;
    }

    /// True if the response is the result of a redirect.
    pub fn redirected(self: *const Response) bool {
        return js.fetch_response_redirected(self.handle) != 0;
    }

    /// The final URL of the response (after any redirects).
    pub fn url(self: *const Response) ![]const u8 {
        const h = js.fetch_response_url(self.handle);
        return js.readString(h, self.allocator);
    }

    /// Get a response header by name (case-insensitive).
    pub fn header(self: *const Response, name: []const u8) !?[]const u8 {
        const h = js.fetch_response_header(self.handle, name.ptr, @intCast(name.len));
        if (h == js.null_handle) return null;
        const str = try js.readString(h, self.allocator);
        return str;
    }

    /// Read the response body as bytes.  Cached after first call.
    pub fn bytes(self: *Response) ![]const u8 {
        if (self._body) |cached| return cached;
        const body_h = js.fetch_response_body(self.handle);
        if (body_h == js.null_handle) {
            self._body = "";
            return "";
        }
        const data = try js.readBytes(body_h, self.allocator);
        self._body = data;
        return data;
    }

    /// Read the response body as a UTF-8 string.  Cached after first call.
    pub fn text(self: *Response) ![]const u8 {
        return self.bytes();
    }

    /// Return an `std.Io.Reader` over the response body.
    /// The body is read from JS on first access (lazy), then served from
    /// memory.  This allows passing the response to any Zig code that
    /// accepts an `Io.Reader` (JSON parsers, etc.).
    pub fn reader(self: *Response) !Io.Reader {
        const data = try self.bytes();
        return Io.Reader.fixed(data);
    }
};

/// Build a JS fetch request handle from the given URL and options.
pub fn buildRequest(url: []const u8, options: Options) js.Handle {
    const req_h = js.fetch_create_request(url.ptr, @intCast(url.len), @intFromEnum(options.method));
    for (options.headers) |h| {
        js.fetch_request_set_header(
            req_h,
            h.name.ptr,
            @intCast(h.name.len),
            h.value.ptr,
            @intCast(h.value.len),
        );
    }
    switch (options.body) {
        .bytes => |b| if (b.len > 0) {
            js.fetch_request_set_body(req_h, b.ptr, @intCast(b.len));
        },
        .form => |fd| js.fetch_request_set_form_data(req_h, fd.handle),
        .none => {},
    }
    return req_h;
}

/// Execute an outbound HTTP request (JSPI-suspending).
pub fn send(allocator: std.mem.Allocator, url: []const u8, options: Options) !Response {
    const req_h = buildRequest(url, options);
    const resp_h = js.fetch_send(req_h);
    if (resp_h == js.null_handle) return error.NullHandle;
    return Response.init(resp_h, allocator);
}

/// Schedule an outbound fetch for concurrent execution via an Async group.
/// Returns the future index.  The request handle is consumed by JS.
pub fn schedule(url: []const u8, options: Options) u32 {
    const req_h = buildRequest(url, options);
    return js.async_fetch(req_h);
}
