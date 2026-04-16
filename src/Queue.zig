const std = @import("std");
const js = @import("js.zig");

// ===========================================================================
// Queue Producer — send messages to a Cloudflare Queue.
// ===========================================================================

handle: js.Handle,
allocator: std.mem.Allocator,

const Queue = @This();

pub fn init(handle: js.Handle, allocator: std.mem.Allocator) Queue {
    return .{ .handle = handle, .allocator = allocator };
}

/// Content type hint for message serialization.
pub const ContentType = enum {
    json,
    text,
    bytes,
    v8,
};

/// Options for sending a single message.
pub const SendOptions = struct {
    content_type: ?ContentType = null,
    delay_seconds: ?u32 = null,
};

/// A single message in a sendBatch call.
pub const SendRequest = struct {
    /// Message body as a JSON string.
    body: []const u8,
    content_type: ?ContentType = null,
    delay_seconds: ?u32 = null,
};

/// Send a single message to the queue. The body is a JSON string.
/// JSPI-suspending — resolves when the message is confirmed written to disk.
pub fn send(self: *const Queue, body: []const u8, options: SendOptions) void {
    const ct: u32 = if (options.content_type) |ct| @intFromEnum(ct) else 0xFF;
    const delay: u32 = options.delay_seconds orelse 0;
    js.queue_send(self.handle, body.ptr, @intCast(body.len), ct, delay);
}

/// Options that apply to an entire sendBatch call.
pub const SendBatchOptions = struct {
    delay_seconds: ?u32 = null,
};

/// Send a batch of messages to the queue.
/// JSPI-suspending — resolves when all messages are confirmed written to disk.
pub fn sendBatch(self: *const Queue, messages: []const SendRequest, options: SendBatchOptions) !void {
    // Serialize the batch as a JSON array for the shim.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(self.allocator);

    try w.writeByte('[');
    for (messages, 0..) |msg, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"body\":");
        try w.writeAll(msg.body); // raw JSON pass-through
        if (msg.content_type) |ct| {
            try w.writeAll(",\"contentType\":");
            try writeContentType(w, ct);
        }
        if (msg.delay_seconds) |d| {
            try w.writeAll(",\"delaySeconds\":");
            try std.fmt.format(w, "{d}", .{d});
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');
    const json = try buf.toOwnedSlice(self.allocator);

    const delay: u32 = options.delay_seconds orelse 0;
    js.queue_send_batch(self.handle, json.ptr, @intCast(json.len), delay);
}

fn writeContentType(w: anytype, ct: ContentType) !void {
    switch (ct) {
        .json => try w.writeAll("\"json\""),
        .text => try w.writeAll("\"text\""),
        .bytes => try w.writeAll("\"bytes\""),
        .v8 => try w.writeAll("\"v8\""),
    }
}

// ===========================================================================
// Queue Consumer — receive and process message batches.
// ===========================================================================

/// A batch of messages delivered to a queue consumer handler.
///
/// ```zig
/// pub fn queue(batch: *workers.Queue.MessageBatch, env: *workers.Env, _: *workers.Context) !void {
///     workers.log("queue={s} count={d}", .{ batch.queueName(), batch.len() });
///     var iter = batch.iterator();
///     while (iter.next()) |msg| {
///         workers.log("msg id={s} body={s}", .{ msg.id(), msg.body() });
///         msg.ack();
///     }
/// }
/// ```
pub const MessageBatch = struct {
    handle: js.Handle,
    allocator: std.mem.Allocator,

    pub fn init(handle: js.Handle, allocator: std.mem.Allocator) MessageBatch {
        return .{ .handle = handle, .allocator = allocator };
    }

    /// The name of the queue this batch belongs to.
    pub fn queueName(self: *const MessageBatch) ![]const u8 {
        const h = js.queue_batch_queue_name(self.handle);
        return js.readString(h, self.allocator);
    }

    /// Number of messages in the batch.
    pub fn len(self: *const MessageBatch) u32 {
        return js.queue_batch_len(self.handle);
    }

    /// Get a message by index.
    pub fn get(self: *const MessageBatch, index: u32) Message {
        const h = js.queue_batch_msg(self.handle, index);
        return .{ .handle = h, .allocator = self.allocator };
    }

    /// Iterate over all messages in the batch.
    pub fn iterator(self: *const MessageBatch) Iterator {
        return .{ .batch = self, .index = 0, .count = self.len() };
    }

    /// Acknowledge all messages in the batch. Messages will not be retried
    /// regardless of whether the handler succeeds or fails.
    pub fn ackAll(self: *const MessageBatch) void {
        js.queue_batch_ack_all(self.handle);
    }

    /// Mark all messages for retry. They will be re-delivered in a future batch.
    pub fn retryAll(self: *const MessageBatch, delay_seconds: ?u32) void {
        js.queue_batch_retry_all(self.handle, delay_seconds orelse 0);
    }

    pub const Iterator = struct {
        batch: *const MessageBatch,
        index: u32,
        count: u32,

        pub fn next(self: *Iterator) ?Message {
            if (self.index >= self.count) return null;
            const msg = self.batch.get(self.index);
            self.index += 1;
            return msg;
        }
    };
};

/// A single message within a MessageBatch.
pub const Message = struct {
    handle: js.Handle,
    allocator: std.mem.Allocator,

    /// Unique system-generated message ID.
    pub fn id(self: *const Message) ![]const u8 {
        const h = js.queue_msg_id(self.handle);
        return js.readString(h, self.allocator);
    }

    /// Timestamp when the message was sent (milliseconds since epoch).
    pub fn timestamp(self: *const Message) f64 {
        return js.queue_msg_timestamp(self.handle);
    }

    /// Message body as a JSON string.
    pub fn body(self: *const Message) ![]const u8 {
        const h = js.queue_msg_body(self.handle);
        return js.readString(h, self.allocator);
    }

    /// Number of delivery attempts (starts at 1).
    pub fn attempts(self: *const Message) u32 {
        return js.queue_msg_attempts(self.handle);
    }

    /// Acknowledge this message. It will not be retried regardless of
    /// whether the handler succeeds or fails.
    pub fn ack(self: *const Message) void {
        js.queue_msg_ack(self.handle);
    }

    /// Mark this message for retry. It will be re-delivered in a future batch.
    pub fn retry(self: *const Message, delay_seconds: ?u32) void {
        js.queue_msg_retry(self.handle, delay_seconds orelse 0);
    }
};

// ===========================================================================
// Unit tests — batch JSON serialization
// ===========================================================================

/// Build batch JSON the same way sendBatch does, but return the string
/// instead of calling FFI. This lets us test serialization in isolation.
fn buildBatchJson(allocator: std.mem.Allocator, messages: []const SendRequest, options: SendBatchOptions) ![]const u8 {
    _ = options;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);

    try w.writeByte('[');
    for (messages, 0..) |msg, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"body\":");
        try w.writeAll(msg.body);
        if (msg.content_type) |ct| {
            try w.writeAll(",\"contentType\":");
            try writeContentType(w, ct);
        }
        if (msg.delay_seconds) |d| {
            try w.writeAll(",\"delaySeconds\":");
            try std.fmt.format(w, "{d}", .{d});
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');
    return try buf.toOwnedSlice(allocator);
}

test "writeContentType — all variants" {
    var buf: [16]u8 = undefined;
    inline for (.{ .{ ContentType.json, "\"json\"" }, .{ ContentType.text, "\"text\"" }, .{ ContentType.bytes, "\"bytes\"" }, .{ ContentType.v8, "\"v8\"" } }) |pair| {
        var fbs = std.io.fixedBufferStream(&buf);
        try writeContentType(fbs.writer(), pair[0]);
        try std.testing.expectEqualStrings(pair[1], fbs.getWritten());
    }
}

test "batch JSON — single message, no options" {
    const msgs = [_]SendRequest{
        .{ .body = "\"hello\"" },
    };
    const json = try buildBatchJson(std.testing.allocator, &msgs, .{});
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("[{\"body\":\"hello\"}]", json);
}

test "batch JSON — multiple messages with content_type" {
    const msgs = [_]SendRequest{
        .{ .body = "{\"a\":1}", .content_type = .json },
        .{ .body = "\"plain text\"", .content_type = .text },
    };
    const json = try buildBatchJson(std.testing.allocator, &msgs, .{});
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "[{\"body\":{\"a\":1},\"contentType\":\"json\"},{\"body\":\"plain text\",\"contentType\":\"text\"}]",
        json,
    );
}

test "batch JSON — message with delay_seconds" {
    const msgs = [_]SendRequest{
        .{ .body = "42", .delay_seconds = 60 },
    };
    const json = try buildBatchJson(std.testing.allocator, &msgs, .{});
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("[{\"body\":42,\"delaySeconds\":60}]", json);
}

test "batch JSON — message with all options" {
    const msgs = [_]SendRequest{
        .{ .body = "true", .content_type = .v8, .delay_seconds = 120 },
    };
    const json = try buildBatchJson(std.testing.allocator, &msgs, .{});
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("[{\"body\":true,\"contentType\":\"v8\",\"delaySeconds\":120}]", json);
}

test "batch JSON — empty batch" {
    const msgs = [_]SendRequest{};
    const json = try buildBatchJson(std.testing.allocator, &msgs, .{});
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("[]", json);
}

test "ContentType enum values" {
    // Verify ordinal values match what shim.js expects (0=json, 1=text, 2=bytes, 3=v8)
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(ContentType.json));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(ContentType.text));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(ContentType.bytes));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(ContentType.v8));
}

test "SendOptions — default content_type sentinel is 0xFF" {
    const opts = SendOptions{};
    const ct: u32 = if (opts.content_type) |ct| @intFromEnum(ct) else 0xFF;
    try std.testing.expectEqual(@as(u32, 0xFF), ct);
}
