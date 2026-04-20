const std = @import("std");
const js = @import("js.zig");
const Fetch = @import("Fetch.zig");
const Response = @import("Response.zig");

/// A WebSocket connection — either server-side (from `init()` + `accept()`)
/// or client-side (from `connect()`).
///
/// ## Server-side (accepting incoming connections)
///
/// ```zig
/// var ws = WebSocket.init(allocator);
/// ws.accept();
///
/// ws.sendText("hello");
///
/// while (ws.receive()) |event| {
///     switch (event.type()) {
///         .text => ws.sendText(try event.text()),
///         .binary => ws.sendBinary(try event.data()),
///         .close => { ws.close(1000, "bye"); break; },
///         .err => break,
///     }
/// }
///
/// return ws.response();
/// ```
///
/// ## Client-side (connecting to an external WebSocket server)
///
/// ```zig
/// var ws = try WebSocket.connect(allocator, "wss://echo.example.com");
///
/// ws.sendText("ping");
///
/// if (ws.receive()) |event| {
///     // event.text() == "ping" (echoed back)
/// }
///
/// ws.close(1000, "done");
/// ```
handle: js.Handle,
allocator: std.mem.Allocator,

const WebSocket = @This();

/// A single WebSocket event (message, close, or error).
pub const Event = struct {
    handle: js.Handle,
    allocator: std.mem.Allocator,

    pub const Type = enum(u32) {
        text = 0,
        binary = 1,
        close = 2,
        err = 3,
    };

    /// The kind of event.
    pub fn @"type"(self: *const Event) Type {
        return @enumFromInt(js.ws_event_type(self.handle));
    }

    /// Read the text payload (only valid for `.text` events).
    pub fn text(self: *const Event) ![]const u8 {
        const len = js.ws_event_text_len(self.handle);
        if (len == 0) return "";
        const buf = try self.allocator.alloc(u8, len);
        js.ws_event_text_read(self.handle, buf.ptr);
        return buf;
    }

    /// Read the binary payload (only valid for `.binary` events).
    pub fn data(self: *const Event) ![]const u8 {
        const len = js.ws_event_binary_len(self.handle);
        if (len == 0) return "";
        const buf = try self.allocator.alloc(u8, len);
        js.ws_event_binary_read(self.handle, buf.ptr);
        return buf;
    }

    /// The close code (only valid for `.close` events). Defaults to 1005
    /// (no status code present) if the peer didn't send one.
    pub fn closeCode(self: *const Event) u16 {
        return @intCast(js.ws_event_close_code(self.handle));
    }

    /// The close reason string (only valid for `.close` events).
    pub fn closeReason(self: *const Event) ![]const u8 {
        const len = js.ws_event_close_reason_len(self.handle);
        if (len == 0) return "";
        const buf = try self.allocator.alloc(u8, len);
        js.ws_event_close_reason_read(self.handle, buf.ptr);
        return buf;
    }
};

/// Create a new WebSocket pair for server-side upgrade.  Returns a handle
/// to the server side.  The client side is automatically embedded in the
/// 101 response returned by `response()`.
pub fn init(allocator: std.mem.Allocator) WebSocket {
    return .{
        .handle = js.ws_pair_new(),
        .allocator = allocator,
    };
}

/// Connect to a remote WebSocket server (outbound / client-side).
/// Uses `fetch()` with an `Upgrade: websocket` header under the hood —
/// the same mechanism Cloudflare Workers uses for outbound WS connections.
/// JSPI-suspending.
///
/// ```zig
/// var ws = try WebSocket.connect(allocator, "wss://echo.example.com");
/// ws.sendText("hello");
/// ```
pub fn connect(allocator: std.mem.Allocator, url: []const u8) !WebSocket {
    const req_h = js.fetch_create_request(url.ptr, @intCast(url.len), @intFromEnum(std.http.Method.GET));
    js.fetch_request_set_header(req_h, "Upgrade", 7, "websocket", 9);
    const resp_h = js.fetch_send(req_h);
    if (resp_h == js.null_handle) return error.NullHandle;
    defer js.js_release(resp_h);

    const ws_h = js.fetch_response_websocket(resp_h);
    if (ws_h == js.null_handle) return error.NullHandle;

    // Accept the client-side WebSocket and set up the event queue.
    const handle = js.ws_client_accept(ws_h);
    return .{
        .handle = handle,
        .allocator = allocator,
    };
}

/// Accept the WebSocket connection on the server side.  This also signals
/// the JS fetch handler to return the 101 Switching Protocols response
/// immediately (similar to how `StreamingResponse.start()` triggers an
/// early return for streaming).
///
/// Must be called before `sendText()`, `sendBinary()`, or `receive()`.
pub fn accept(self: *WebSocket) void {
    js.ws_accept(self.handle);
}

/// Send a UTF-8 text message to the client.
pub fn sendText(self: *WebSocket, msg: []const u8) void {
    js.ws_send_text(self.handle, msg.ptr, @intCast(msg.len));
}

/// Send a binary message to the client.
pub fn sendBinary(self: *WebSocket, msg: []const u8) void {
    js.ws_send_binary(self.handle, msg.ptr, @intCast(msg.len));
}

/// Close the WebSocket connection with an optional status code and reason.
pub fn close(self: *WebSocket, code: u16, reason: []const u8) void {
    js.ws_close(self.handle, code, reason.ptr, @intCast(reason.len));
}

/// Receive the next WebSocket event.  Returns `null` when the connection
/// has been closed or errored and there are no more queued events.
/// JSPI-suspending — the Wasm stack is suspended until an event arrives.
pub fn receive(self: *WebSocket) ?Event {
    const h = js.ws_receive(self.handle);
    if (h == js.null_handle) return null;
    return Event{
        .handle = h,
        .allocator = self.allocator,
    };
}

/// Return a sentinel Response that tells the framework the response was
/// already sent via WebSocket upgrade (101 Switching Protocols).
pub fn response(self: *const WebSocket) Response {
    _ = self;
    return .{ .handle = js.null_handle };
}
