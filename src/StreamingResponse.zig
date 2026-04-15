const std = @import("std");
const js = @import("js.zig");
const Response = @import("Response.zig");

/// A streaming response that sends chunks to the client in real time.
///
/// Unlike a normal `Response` (which buffers the entire body), a
/// `StreamingResponse` uses a `TransformStream` under the hood so each
/// `write()` call flushes data to the client immediately.
///
/// ```zig
/// var stream = workers.StreamingResponse.start(.{ .status = .ok });
/// stream.setHeader("content-type", "text/event-stream");
///
/// try stream.write("data: hello\n\n");
/// try stream.write("data: world\n\n");
/// stream.close();
///
/// return stream.response();
/// ```
handle: js.Handle,

const StreamingResponse = @This();

pub const StartOptions = struct {
    status: std.http.Status = .ok,
};

/// Create a TransformStream and signal the JS fetch handler to return the
/// Response immediately (with the readable end as the body).
/// After this call, each `write()` flushes to the client in real time.
pub fn start(options: StartOptions) StreamingResponse {
    return .{
        .handle = js.response_stream_start(@intFromEnum(options.status)),
    };
}

/// Set a response header.  Must be called before the first `write()`.
pub fn setHeader(self: *StreamingResponse, name: []const u8, value: []const u8) void {
    js.response_stream_set_header(
        self.handle,
        name.ptr,
        @intCast(name.len),
        value.ptr,
        @intCast(value.len),
    );
}

/// Write a chunk to the stream.  JSPI-suspending – the data is flushed to
/// the client before this call returns.
pub fn write(self: *StreamingResponse, data: []const u8) void {
    js.response_stream_write(self.handle, data.ptr, @intCast(data.len));
}

/// Close the stream.  No more writes are allowed after this.
/// JSPI-suspending.
pub fn close(self: *StreamingResponse) void {
    js.response_stream_close(self.handle);
}

/// Return a sentinel Response that tells the framework the response was
/// already sent via streaming.
pub fn response(self: *const StreamingResponse) Response {
    _ = self;
    return .{ .handle = js.null_handle };
}
