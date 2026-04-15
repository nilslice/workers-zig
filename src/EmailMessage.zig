const std = @import("std");
const js = @import("js.zig");

// ===========================================================================
// Email Message — Cloudflare Email Routing handler API.
//
// Define `pub fn email(message: *EmailMessage, env, ctx)` in your
// worker module to handle incoming emails.
//
// ```zig
// pub fn email(message: *workers.EmailMessage, env: *workers.Env, _: *workers.Context) !void {
//     const from = try message.from();
//     const to = try message.to();
//     workers.log("email from={s} to={s} size={d}", .{ from, to, message.rawSize() });
//
//     // Forward to another address
//     try message.forward("admin@example.com");
//
//     // Or read the raw email body
//     // const body = try message.rawBody();
// }
// ```
// ===========================================================================

handle: js.Handle,
allocator: std.mem.Allocator,

const EmailMessage = @This();

pub fn init(handle: js.Handle, allocator: std.mem.Allocator) EmailMessage {
    return .{ .handle = handle, .allocator = allocator };
}

/// Get the sender address (envelope MAIL FROM).
pub fn from(self: *const EmailMessage) ![]const u8 {
    const h = js.email_from(self.handle);
    if (h == js.null_handle) return error.EmailError;
    return js.readString(h, self.allocator);
}

/// Get the recipient address (envelope RCPT TO).
pub fn to(self: *const EmailMessage) ![]const u8 {
    const h = js.email_to(self.handle);
    if (h == js.null_handle) return error.EmailError;
    return js.readString(h, self.allocator);
}

/// Get the raw email size in bytes.
pub fn rawSize(self: *const EmailMessage) u32 {
    return js.email_raw_size(self.handle);
}

/// Get an email header value by name. Returns null if not present.
pub fn header(self: *const EmailMessage, name: []const u8) !?[]const u8 {
    const h = js.email_header(self.handle, name.ptr, @intCast(name.len));
    if (h == js.null_handle) return null;
    return js.readString(h, self.allocator);
}

/// Read the full raw email body as bytes. JSPI-suspending.
pub fn rawBody(self: *const EmailMessage) ![]const u8 {
    const h = js.email_raw_body(self.handle);
    if (h == js.null_handle) return error.EmailError;
    return js.readBytes(h, self.allocator);
}

/// Reject the email with a reason string.
pub fn setReject(self: *const EmailMessage, reason: []const u8) void {
    js.email_set_reject(self.handle, reason.ptr, @intCast(reason.len));
}

/// Forward the email to another address. JSPI-suspending.
pub fn forward(self: *const EmailMessage, rcpt_to: []const u8) void {
    js.email_forward(self.handle, rcpt_to.ptr, @intCast(rcpt_to.len));
}

/// Reply to the email with a raw RFC 5322 message. JSPI-suspending.
pub fn reply(self: *const EmailMessage, raw_message: []const u8) void {
    js.email_reply(self.handle, raw_message.ptr, @intCast(raw_message.len));
}
