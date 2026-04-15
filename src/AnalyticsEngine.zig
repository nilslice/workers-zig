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
    var w = std.Io.Writer.Allocating.init(self.allocator);

    try w.writer.writeAll(&.{'{'});
    var need_comma = false;

    if (point.indexes) |indexes| {
        if (need_comma) try w.writer.writeAll(&.{','});
        need_comma = true;
        try w.writer.writeAll("\"indexes\":[");
        for (indexes, 0..) |idx, i| {
            if (i > 0) try w.writer.writeAll(&.{','});
            try writeJsonString(&w.writer, idx);
        }
        try w.writer.writeAll(&.{']'});
    }
    if (point.blobs) |blobs| {
        if (need_comma) try w.writer.writeAll(&.{','});
        need_comma = true;
        try w.writer.writeAll("\"blobs\":[");
        for (blobs, 0..) |blob, i| {
            if (i > 0) try w.writer.writeAll(&.{','});
            try writeJsonString(&w.writer, blob);
        }
        try w.writer.writeAll(&.{']'});
    }
    if (point.doubles) |doubles| {
        if (need_comma) try w.writer.writeAll(&.{','});
        try w.writer.writeAll("\"doubles\":[");
        for (doubles, 0..) |d, i| {
            if (i > 0) try w.writer.writeAll(&.{','});
            try w.writer.print("{d}", .{d});
        }
        try w.writer.writeAll(&.{']'});
    }

    try w.writer.writeAll(&.{'}'});
    const json = try w.toOwnedSlice();

    js.ae_write_data_point(self.handle, json.ptr, @intCast(json.len));
}

fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeAll(&.{'"'});
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeAll(&.{c});
                }
            },
        }
    }
    try writer.writeAll(&.{'"'});
}
