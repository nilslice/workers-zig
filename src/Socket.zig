const std = @import("std");
const js = @import("js.zig");

// ===========================================================================
// TCP Sockets — outbound and inbound TCP connections.
//
// Outbound: use `Socket.connect()` to create a connection.
// Inbound: define `pub fn connect(socket, env, ctx)` to handle incoming
// TCP connections (requires `[tcp_workers]` config in wrangler.toml).
// ===========================================================================

handle: js.Handle,
allocator: std.mem.Allocator,
_reader: js.Handle = js.null_handle,
_writer: js.Handle = js.null_handle,

const Socket = @This();

/// TLS transport mode.
pub const SecureTransport = enum(u32) {
    off = 0,
    on = 1,
    starttls = 2,
};

/// Options for creating a TCP socket.
pub const ConnectOptions = struct {
    secure_transport: SecureTransport = .off,
    allow_half_open: bool = false,
};

/// Information about the socket connection endpoints.
pub const SocketInfo = struct {
    remoteAddress: ?[]const u8 = null,
    localAddress: ?[]const u8 = null,
};

/// Create an outbound TCP connection.
///
/// ```zig
/// const socket = try workers.Socket.connect(allocator, "example.com", 5432, .{
///     .secure_transport = .on,
/// });
/// defer socket.close();
///
/// try socket.write("PING\r\n");
/// const chunk = try socket.read();
/// ```
pub fn connect(allocator: std.mem.Allocator, hostname: []const u8, port: u16, options: ConnectOptions) Socket {
    const h = js.socket_connect(
        hostname.ptr,
        @intCast(hostname.len),
        port,
        @intFromEnum(options.secure_transport),
        if (options.allow_half_open) @as(u32, 1) else 0,
    );
    return .{ .handle = h, .allocator = allocator };
}

/// Write data to the socket. JSPI-suspending.
pub fn write(self: *Socket, data: []const u8) void {
    if (self._writer == js.null_handle) {
        self._writer = js.socket_get_writer(self.handle);
    }
    js.socket_write(self._writer, data.ptr, @intCast(data.len));
}

/// Read the next chunk from the socket. Returns null on EOF/stream end.
/// JSPI-suspending.
pub fn read(self: *Socket) !?[]const u8 {
    if (self._reader == js.null_handle) {
        self._reader = js.socket_get_reader(self.handle);
    }
    const h = js.socket_read(self._reader);
    if (h == js.null_handle) return null;
    return try js.readBytes(h, self.allocator);
}

/// Close the socket (both readable and writable sides). JSPI-suspending.
pub fn close(self: *Socket) void {
    if (self._writer != js.null_handle) {
        js.socket_close_writer(self._writer);
        self._writer = js.null_handle;
    }
    js.socket_close(self.handle);
    if (self._reader != js.null_handle) {
        js.js_release(self._reader);
        self._reader = js.null_handle;
    }
}

/// Upgrade an insecure socket to TLS (StartTLS pattern).
/// Returns a new Socket; the original is no longer usable.
/// Only valid if the socket was created with `.secure_transport = .starttls`.
pub fn startTls(self: *Socket) Socket {
    const new_h = js.socket_start_tls(self.handle);
    // Old socket is consumed — clear handles.
    self._reader = js.null_handle;
    self._writer = js.null_handle;
    self.handle = js.null_handle;
    return .{ .handle = new_h, .allocator = self.allocator };
}

/// Wait for the connection to be established and return endpoint info.
/// JSPI-suspending.
pub fn opened(self: *const Socket) !SocketInfo {
    const h = js.socket_opened(self.handle);
    if (h == js.null_handle) return .{};
    const json = try js.readString(h, self.allocator);
    defer self.allocator.free(json);
    const parsed = try std.json.parseFromSlice(SocketInfo, self.allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    return parsed.value;
}
