const std = @import("std");
const js = @import("js.zig");

// ===========================================================================
// SendEmail — Cloudflare Email Service send binding.
//
// Send emails directly from Workers using a configured send_email binding.
//
// ```zig
// const email = try env.sendEmail("EMAIL");
// const result = try email.send(.{
//     .to = "user@example.com",
//     .from = "noreply@yourdomain.com",
//     .subject = "Hello",
//     .text = "Hello from Workers!",
// });
// workers.log("sent: {s}", .{result.message_id});
// ```
// ===========================================================================

handle: js.Handle,
allocator: std.mem.Allocator,

const SendEmail = @This();

pub fn init(handle: js.Handle, allocator: std.mem.Allocator) SendEmail {
    return .{ .handle = handle, .allocator = allocator };
}

/// Email message options.
pub const Message = struct {
    /// Recipient(s). Single address or comma-separated list.
    to: []const u8,
    /// Sender address or "Name <address>" format.
    from: []const u8,
    /// Email subject.
    subject: []const u8,
    /// Plain text body.
    text: ?[]const u8 = null,
    /// HTML body.
    html: ?[]const u8 = null,
    /// CC recipients (comma-separated).
    cc: ?[]const u8 = null,
    /// BCC recipients (comma-separated).
    bcc: ?[]const u8 = null,
    /// Reply-to address.
    reply_to: ?[]const u8 = null,
    /// Attachments as JSON array string (use buildAttachment helper).
    attachments_json: ?[]const u8 = null,
};

pub const SendResult = struct {
    message_id: []const u8,
};

pub const Attachment = struct {
    /// Base64-encoded content or raw bytes.
    content: []const u8,
    /// Filename.
    filename: []const u8,
    /// MIME type.
    content_type: []const u8,
    /// "attachment" or "inline".
    disposition: []const u8 = "attachment",
    /// Content-ID for inline attachments (without angle brackets).
    content_id: ?[]const u8 = null,
};

/// Send an email. JSPI-suspending.
pub fn send(self: SendEmail, message: Message) !SendResult {
    var w = std.Io.Writer.Allocating.init(self.allocator);
    try buildMessageJson(&w.writer, message);
    const json = w.toOwnedSlice() catch return error.OutOfMemory;
    defer self.allocator.free(json);

    const h = js.send_email(self.handle, json.ptr, @intCast(json.len));
    if (h == js.null_handle) return error.SendEmailFailed;

    const result_json = try js.readString(h, self.allocator);
    defer self.allocator.free(result_json);

    return parseSendResult(self.allocator, result_json);
}

fn buildMessageJson(writer: *std.Io.Writer, message: Message) !void {
    try writer.writeAll("{");

    // to — check for comma to decide array vs string
    try writer.writeAll("\"to\":");
    if (std.mem.indexOf(u8, message.to, ",") != null) {
        try writeStringArray(writer, message.to);
    } else {
        try writeJsonString(writer, message.to);
    }

    // from
    try writer.writeAll(",\"from\":");
    try writeJsonString(writer, message.from);

    // subject
    try writer.writeAll(",\"subject\":");
    try writeJsonString(writer, message.subject);

    if (message.text) |text| {
        try writer.writeAll(",\"text\":");
        try writeJsonString(writer, text);
    }
    if (message.html) |html| {
        try writer.writeAll(",\"html\":");
        try writeJsonString(writer, html);
    }
    if (message.cc) |cc| {
        try writer.writeAll(",\"cc\":");
        if (std.mem.indexOf(u8, cc, ",") != null) {
            try writeStringArray(writer, cc);
        } else {
            try writeJsonString(writer, cc);
        }
    }
    if (message.bcc) |bcc| {
        try writer.writeAll(",\"bcc\":");
        if (std.mem.indexOf(u8, bcc, ",") != null) {
            try writeStringArray(writer, bcc);
        } else {
            try writeJsonString(writer, bcc);
        }
    }
    if (message.reply_to) |reply_to| {
        try writer.writeAll(",\"replyTo\":");
        try writeJsonString(writer, reply_to);
    }
    if (message.attachments_json) |att| {
        try writer.writeAll(",\"attachments\":");
        try writer.writeAll(att);
    }

    try writer.writeAll("}");
}

/// Helper to build an attachments JSON array from a slice of Attachment structs.
pub fn buildAttachmentsJson(allocator: std.mem.Allocator, attachments: []const Attachment) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(allocator);
    try w.writer.writeAll("[");
    for (attachments, 0..) |att, i| {
        if (i > 0) try w.writer.writeAll(",");
        try w.writer.writeAll("{\"content\":");
        try writeJsonString(&w.writer, att.content);
        try w.writer.writeAll(",\"filename\":");
        try writeJsonString(&w.writer, att.filename);
        try w.writer.writeAll(",\"type\":");
        try writeJsonString(&w.writer, att.content_type);
        try w.writer.writeAll(",\"disposition\":");
        try writeJsonString(&w.writer, att.disposition);
        if (att.content_id) |cid| {
            try w.writer.writeAll(",\"contentId\":");
            try writeJsonString(&w.writer, cid);
        }
        try w.writer.writeAll("}");
    }
    try w.writer.writeAll("]");
    return w.toOwnedSlice();
}

fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                const buf = [1]u8{c};
                try writer.writeAll(&buf);
            },
        }
    }
    try writer.writeAll("\"");
}

fn writeStringArray(writer: *std.Io.Writer, csv: []const u8) !void {
    try writer.writeAll("[");
    var first = true;
    var iter = std.mem.splitScalar(u8, csv, ',');
    while (iter.next()) |part| {
        if (!first) try writer.writeAll(",");
        first = false;
        // Trim whitespace around each address
        const trimmed = std.mem.trim(u8, part, " ");
        try writeJsonString(writer, trimmed);
    }
    try writer.writeAll("]");
}

fn parseSendResult(allocator: std.mem.Allocator, json: []const u8) !SendResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch {
        return error.InvalidResponse;
    };
    defer parsed.deinit();

    if (parsed.value == .object) {
        if (parsed.value.object.get("messageId")) |v| {
            if (v == .string) {
                return SendResult{ .message_id = try allocator.dupe(u8, v.string) };
            }
        }
    }
    return SendResult{ .message_id = try allocator.dupe(u8, "") };
}

// ===========================================================================
// Unit tests
// ===========================================================================

test "buildMessageJson — simple" {
    var w = std.Io.Writer.Allocating.init(std.testing.allocator);
    try buildMessageJson(&w.writer, .{
        .to = "user@example.com",
        .from = "noreply@example.com",
        .subject = "Hello",
        .text = "Hi there",
    });
    const json = try w.toOwnedSlice();
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"to\":\"user@example.com\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"from\":\"noreply@example.com\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"subject\":\"Hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"text\":\"Hi there\"") != null);
}

test "buildMessageJson — multiple recipients" {
    var w = std.Io.Writer.Allocating.init(std.testing.allocator);
    try buildMessageJson(&w.writer, .{
        .to = "a@x.com, b@x.com",
        .from = "noreply@x.com",
        .subject = "Test",
    });
    const json = try w.toOwnedSlice();
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"to\":[\"a@x.com\",\"b@x.com\"]") != null);
}

test "buildAttachmentsJson" {
    const attachments = [_]Attachment{
        .{
            .content = "base64data",
            .filename = "doc.pdf",
            .content_type = "application/pdf",
        },
    };
    const json = try buildAttachmentsJson(std.testing.allocator, &attachments);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"filename\":\"doc.pdf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"disposition\":\"attachment\"") != null);
}

test "parseSendResult" {
    const result = try parseSendResult(std.testing.allocator, "{\"messageId\":\"abc-123\"}");
    defer std.testing.allocator.free(result.message_id);
    try std.testing.expectEqualStrings("abc-123", result.message_id);
}
