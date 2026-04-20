const std = @import("std");
const js = @import("js.zig");

// ===========================================================================
// EventSource — Server-Sent Events (SSE) client.
// ===========================================================================

handle: js.Handle,
allocator: std.mem.Allocator,

const EventSource = @This();

/// An SSE event received from the server.
pub const Event = struct {
    /// Event type (defaults to "message").
    type: []const u8,
    /// Event data payload.
    data: []const u8,
    /// Last event ID (empty if not set).
    lastEventId: []const u8,
};

/// Connection ready states.
pub const ReadyState = enum(u32) {
    connecting = 0,
    open = 1,
    closed = 2,
};

/// Connect to an SSE endpoint.
///
/// ```zig
/// var es = EventSource.connect(allocator, "https://api.example.com/stream");
/// defer es.close();
///
/// while (try es.next()) |event| {
///     workers.log("type={s} data={s}", .{ event.type, event.data });
/// }
/// ```
pub fn connect(allocator: std.mem.Allocator, url: []const u8) EventSource {
    const h = js.eventsource_connect(url.ptr, @intCast(url.len));
    return .{ .handle = h, .allocator = allocator };
}

/// Create an EventSource from a ReadableStream (Cloudflare extension).
/// Useful for consuming SSE from a fetch response body.
pub fn fromStream(allocator: std.mem.Allocator, stream_handle: js.Handle) EventSource {
    const h = js.eventsource_from_stream(stream_handle);
    return .{ .handle = h, .allocator = allocator };
}

/// Read the next SSE event. Returns null when the connection is closed.
/// JSPI-suspending.
pub fn next(self: *const EventSource) !?Event {
    const h = js.eventsource_next(self.handle);
    if (h == js.null_handle) return null;

    const json = try js.readString(h, self.allocator);
    defer self.allocator.free(json);

    const parsed = try std.json.parseFromSlice(Event, self.allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    // Caller uses the event within the iterator loop; parsed memory is
    // owned by the allocator.
    return parsed.value;
}

/// Current connection state.
pub fn readyState(self: *const EventSource) ReadyState {
    return @enumFromInt(js.eventsource_ready_state(self.handle));
}

/// Close the EventSource connection.
pub fn close(self: *const EventSource) void {
    js.eventsource_close(self.handle);
}
