const std = @import("std");
const js = @import("js.zig");

// ===========================================================================
// HTMLRewriter — streaming HTML parser/transformer (Cloudflare-specific).
//
// Uses a declarative rule-based API: add rules with selectors and actions,
// then call transform() to apply them all to a Response.
// ===========================================================================

allocator: std.mem.Allocator,
rules: std.ArrayListUnmanaged(u8),

const HTMLRewriter = @This();

/// Content insertion position.
pub const Content = struct {
    content: []const u8,
    html: bool = false,
};

pub fn init(allocator: std.mem.Allocator) HTMLRewriter {
    return .{
        .allocator = allocator,
        .rules = .empty,
    };
}

// ---- Element actions (by CSS selector) ------------------------------------

/// Set an attribute on matching elements.
pub fn setAttribute(self: *HTMLRewriter, selector: []const u8, name: []const u8, value: []const u8) !void {
    try self.addRule(selector, "setAttribute", .{ .name = name, .value = value, .content = null, .html = false });
}

/// Remove an attribute from matching elements.
pub fn removeAttribute(self: *HTMLRewriter, selector: []const u8, name: []const u8) !void {
    try self.addRule(selector, "removeAttribute", .{ .name = name, .value = null, .content = null, .html = false });
}

/// Set the inner content of matching elements.
pub fn setInnerContent(self: *HTMLRewriter, selector: []const u8, content: Content) !void {
    try self.addRule(selector, "setInnerContent", .{ .name = null, .value = null, .content = content.content, .html = content.html });
}

/// Insert content before matching elements.
pub fn before(self: *HTMLRewriter, selector: []const u8, content: Content) !void {
    try self.addRule(selector, "before", .{ .name = null, .value = null, .content = content.content, .html = content.html });
}

/// Insert content after matching elements.
pub fn after(self: *HTMLRewriter, selector: []const u8, content: Content) !void {
    try self.addRule(selector, "after", .{ .name = null, .value = null, .content = content.content, .html = content.html });
}

/// Prepend content inside matching elements.
pub fn prepend(self: *HTMLRewriter, selector: []const u8, content: Content) !void {
    try self.addRule(selector, "prepend", .{ .name = null, .value = null, .content = content.content, .html = content.html });
}

/// Append content inside matching elements.
pub fn append(self: *HTMLRewriter, selector: []const u8, content: Content) !void {
    try self.addRule(selector, "append", .{ .name = null, .value = null, .content = content.content, .html = content.html });
}

/// Replace matching elements entirely.
pub fn replace(self: *HTMLRewriter, selector: []const u8, content: Content) !void {
    try self.addRule(selector, "replace", .{ .name = null, .value = null, .content = content.content, .html = content.html });
}

/// Remove matching elements.
pub fn remove(self: *HTMLRewriter, selector: []const u8) !void {
    try self.addRule(selector, "remove", .{ .name = null, .value = null, .content = null, .html = false });
}

/// Remove matching elements but keep their children.
pub fn removeAndKeepContent(self: *HTMLRewriter, selector: []const u8) !void {
    try self.addRule(selector, "removeAndKeepContent", .{ .name = null, .value = null, .content = null, .html = false });
}

// ---- Document-level actions -----------------------------------------------

/// Append content to the end of the document.
pub fn docEnd(self: *HTMLRewriter, content: Content) !void {
    try self.addRule("__document_end__", "append", .{ .name = null, .value = null, .content = content.content, .html = content.html });
}

// ---- Transform ------------------------------------------------------------

/// Apply all rules to a Response, returning a new transformed Response.
/// The original response handle is consumed.
///
/// ```zig
/// var rw = workers.HTMLRewriter.init(allocator);
/// try rw.setAttribute("a[href^='http']", "target", "_blank");
/// try rw.remove("script.tracking");
/// try rw.append("body", .{ .content = "<footer>Powered by Zig</footer>", .html = true });
/// const new_resp = rw.transform(response_handle);
/// ```
pub fn transform(self: *HTMLRewriter, response_handle: js.Handle) js.Handle {
    if (self.rules.items.len == 0) {
        return response_handle; // no rules, pass through
    }
    // Close the JSON array (addRule leaves it open for appending).
    self.rules.append(self.allocator, ']') catch {};
    const json = self.rules.toOwnedSlice(self.allocator) catch "";
    defer self.allocator.free(json);

    return js.html_rewriter_transform(response_handle, json.ptr, @intCast(json.len));
}

// ---- Internal rule builder ------------------------------------------------

const RuleFields = struct {
    name: ?[]const u8,
    value: ?[]const u8,
    content: ?[]const u8,
    html: bool,
};

fn addRule(self: *HTMLRewriter, selector: []const u8, action: []const u8, fields: RuleFields) !void {
    const w = self.rules.writer(self.allocator);
    // Emit JSON array opening bracket on first rule, comma separator after.
    if (self.rules.items.len == 0) {
        try w.writeByte('[');
    } else {
        try w.writeByte(',');
    }
    try w.writeAll("{\"selector\":");
    try writeJsonString(w, selector);
    try w.writeAll(",\"action\":");
    try writeJsonString(w, action);
    if (fields.name) |n| {
        try w.writeAll(",\"name\":");
        try writeJsonString(w, n);
    }
    if (fields.value) |v| {
        try w.writeAll(",\"value\":");
        try writeJsonString(w, v);
    }
    if (fields.content) |c| {
        try w.writeAll(",\"content\":");
        try writeJsonString(w, c);
    }
    if (fields.html) {
        try w.writeAll(",\"html\":true");
    }
    try w.writeByte('}');
    // Close the array — we always maintain valid JSON by overwriting the
    // closing bracket on the next addRule call.
    try w.writeByte(']');
    // The next addRule will overwrite this ']' with ',' via the items.len check.
    // Actually, we need to pop the ']' so the next rule can append.
    // Let's use a different strategy: build without the closing bracket,
    // and add it in transform().
    // Revert: remove the trailing ']' we just wrote.
    self.rules.items.len -= 1;
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try std.fmt.format(w, "\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

// ---- Unit tests -----------------------------------------------------------

fn buildTestRules(allocator: std.mem.Allocator, rw: *HTMLRewriter) ![]const u8 {
    // Finalize: add closing bracket
    const w = rw.rules.writer(allocator);
    if (rw.rules.items.len > 0) {
        try w.writeByte(']');
    }
    return rw.rules.toOwnedSlice(allocator);
}

test "single setAttribute rule" {
    var rw = init(std.testing.allocator);
    try rw.setAttribute("a", "target", "_blank");
    const json = try buildTestRules(std.testing.allocator, &rw);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "[{\"selector\":\"a\",\"action\":\"setAttribute\",\"name\":\"target\",\"value\":\"_blank\"}]",
        json,
    );
}

test "multiple rules" {
    var rw = init(std.testing.allocator);
    try rw.remove("script.ads");
    try rw.append("body", .{ .content = "<p>hi</p>", .html = true });
    const json = try buildTestRules(std.testing.allocator, &rw);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "[{\"selector\":\"script.ads\",\"action\":\"remove\"},{\"selector\":\"body\",\"action\":\"append\",\"content\":\"<p>hi</p>\",\"html\":true}]",
        json,
    );
}

test "no rules produces empty" {
    var rw = init(std.testing.allocator);
    const json = try buildTestRules(std.testing.allocator, &rw);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("", json);
}
