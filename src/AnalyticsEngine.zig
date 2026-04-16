const std = @import("std");
const js = @import("js.zig");

// ===========================================================================
// Analytics Engine — write custom analytics data points.
// ===========================================================================

handle: js.Handle,
allocator: std.mem.Allocator,

const AnalyticsEngine = @This();

pub fn init(handle: js.Handle, allocator: std.mem.Allocator) AnalyticsEngine {
    return .{ .handle = handle, .allocator = allocator };
}

/// A data point to write to the Analytics Engine dataset.
///
/// - `indexes`: up to 1 index field (string, max 32 bytes)
/// - `blobs`: up to 20 string fields (max 5120 bytes each)
/// - `doubles`: up to 20 numeric fields
pub const DataPoint = struct {
    indexes: ?[]const []const u8 = null,
    blobs: ?[]const []const u8 = null,
    doubles: ?[]const f64 = null,
};

/// Write a data point to the Analytics Engine dataset.
/// This is a non-blocking, fire-and-forget operation.
pub fn writeDataPoint(self: *const AnalyticsEngine, point: DataPoint) !void {
    // Serialize as JSON for the shim.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(self.allocator);

    try w.writeByte('{');
    var need_comma = false;

    if (point.indexes) |indexes| {
        if (need_comma) try w.writeByte(',');
        need_comma = true;
        try w.writeAll("\"indexes\":[");
        for (indexes, 0..) |idx, i| {
            if (i > 0) try w.writeByte(',');
            try writeJsonString(w, idx);
        }
        try w.writeByte(']');
    }
    if (point.blobs) |blobs| {
        if (need_comma) try w.writeByte(',');
        need_comma = true;
        try w.writeAll("\"blobs\":[");
        for (blobs, 0..) |blob, i| {
            if (i > 0) try w.writeByte(',');
            try writeJsonString(w, blob);
        }
        try w.writeByte(']');
    }
    if (point.doubles) |doubles| {
        if (need_comma) try w.writeByte(',');
        try w.writeAll("\"doubles\":[");
        for (doubles, 0..) |d, i| {
            if (i > 0) try w.writeByte(',');
            try std.fmt.format(w, "{d}", .{d});
        }
        try w.writeByte(']');
    }

    try w.writeByte('}');
    const json = try buf.toOwnedSlice(self.allocator);

    js.ae_write_data_point(self.handle, json.ptr, @intCast(json.len));
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
