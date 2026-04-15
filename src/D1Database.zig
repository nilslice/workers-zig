const std = @import("std");
const js = @import("js.zig");

handle: js.Handle,
allocator: std.mem.Allocator,

const D1Database = @This();

pub fn init(handle: js.Handle, allocator: std.mem.Allocator) D1Database {
    return .{ .handle = handle, .allocator = allocator };
}

/// Result of a run/all query – mirrors D1Result.
pub const QueryResult = struct {
    /// Raw JSON string of the results array.
    json: []const u8,
    /// Whether the operation was successful.
    success: bool,
    /// Number of rows read.
    rows_read: u64,
    /// Number of rows written.
    rows_written: u64,
};

// ---------------------------------------------------------------------------
// High-level API – comptime-typed parameters
// ---------------------------------------------------------------------------

/// Run a query for side-effects (INSERT/UPDATE/DELETE).
///
/// ```zig
/// _ = try db.run("INSERT INTO users (name, age) VALUES (?, ?)", .{ "alice", 30 });
/// ```
pub fn run(self: *const D1Database, sql: []const u8, args: anytype) !QueryResult {
    const params = try serializeParams(args, self.allocator);
    return self.queryRun(sql, params);
}

/// Run a query and return all matching rows as a JSON string.
///
/// ```zig
/// const result = try db.all("SELECT * FROM users WHERE age > ?", .{21});
/// ```
pub fn all(self: *const D1Database, sql: []const u8, args: anytype) !QueryResult {
    const params = try serializeParams(args, self.allocator);
    return self.queryAll(sql, params);
}

/// Run a query and return only the first row as a JSON string.
/// Returns null if no rows match.
///
/// ```zig
/// const row = try db.first("SELECT * FROM users WHERE name = ?", .{"alice"});
/// ```
pub fn first(self: *const D1Database, sql: []const u8, args: anytype) !?[]const u8 {
    const params = try serializeParams(args, self.allocator);
    return self.queryFirst(sql, params);
}

// ---------------------------------------------------------------------------
// Low-level API – raw JSON parameter strings
// ---------------------------------------------------------------------------

/// Execute a raw SQL string (no parameters, no results – for DDL, multi-statement).
pub fn exec(self: *const D1Database, sql: []const u8) !QueryResult {
    const h = js.d1_exec(self.handle, sql.ptr, @intCast(sql.len));
    defer js.js_release(h);
    return readResult(h, self.allocator);
}

/// Run a parameterised query and return all matching rows as a JSON string.
///
/// `params` is a JSON array string, e.g. `"[42, \"alice\"]"`.
/// Pass `"[]"` for queries with no parameters.
pub fn queryAll(self: *const D1Database, sql: []const u8, params: []const u8) !QueryResult {
    const p = if (params.len > 0) params else "[]";
    const h = js.d1_query_all(
        self.handle,
        sql.ptr,
        @intCast(sql.len),
        p.ptr,
        @intCast(p.len),
    );
    defer js.js_release(h);
    return readResult(h, self.allocator);
}

/// Run a parameterised query and return only the first row as a JSON string.
/// Returns null if no rows match.
pub fn queryFirst(self: *const D1Database, sql: []const u8, params: []const u8) !?[]const u8 {
    const p = if (params.len > 0) params else "[]";
    const h = js.d1_query_first(
        self.handle,
        sql.ptr,
        @intCast(sql.len),
        p.ptr,
        @intCast(p.len),
    );
    if (h == js.null_handle) return null;
    const str = try js.readString(h, self.allocator);
    return str;
}

/// Run a parameterised query for side-effects (INSERT/UPDATE/DELETE).
/// Returns metadata about rows affected.
pub fn queryRun(self: *const D1Database, sql: []const u8, params: []const u8) !QueryResult {
    const p = if (params.len > 0) params else "[]";
    const h = js.d1_query_run(
        self.handle,
        sql.ptr,
        @intCast(sql.len),
        p.ptr,
        @intCast(p.len),
    );
    defer js.js_release(h);
    return readResult(h, self.allocator);
}

// -- internal ---------------------------------------------------------------

fn readResult(h: js.Handle, allocator: std.mem.Allocator) !QueryResult {
    const json_str = (try js.getStringProp(h, "results", allocator)) orelse "[]";
    const success = js.getIntProp(h, "success") != 0;
    const rows_read: u64 = @intCast(@max(0, js.getIntProp(h, "rows_read")));
    const rows_written: u64 = @intCast(@max(0, js.getIntProp(h, "rows_written")));
    return .{
        .json = json_str,
        .success = success,
        .rows_read = rows_read,
        .rows_written = rows_written,
    };
}

/// Serialize a comptime-known tuple of parameters into a JSON array string.
/// Supports: integers, floats, bools, strings ([]const u8), null (optionals),
/// and enum literals.
pub fn serializeParams(args: anytype, allocator: std.mem.Allocator) ![]const u8 {
    const T = @TypeOf(args);
    const info = @typeInfo(T);

    if (info != .@"struct" or !info.@"struct".is_tuple) {
        @compileError("D1 params must be a tuple, e.g. .{ \"alice\", 30 }");
    }

    const fields = info.@"struct".fields;
    if (fields.len == 0) return "[]";

    var w = std.Io.Writer.Allocating.init(allocator);
    try w.writer.writeAll(&.{'['});

    inline for (fields, 0..) |field, i| {
        if (i > 0) try w.writer.writeAll(&.{','});
        const val = @field(args, field.name);
        try writeJsonValue(&w.writer, val);
    }

    try w.writer.writeAll(&.{']'});
    return try w.toOwnedSlice();
}

fn writeJsonValue(writer: *std.Io.Writer, val: anytype) !void {
    const T = @TypeOf(val);
    const info = @typeInfo(T);

    switch (info) {
        .int, .comptime_int => try writer.print("{d}", .{val}),
        .float, .comptime_float => try writer.print("{d}", .{val}),
        .bool => try writer.writeAll(if (val) "true" else "false"),
        .null => try writer.writeAll("null"),
        .optional => {
            if (val) |v| {
                try writeJsonValue(writer, v);
            } else {
                try writer.writeAll("null");
            }
        },
        .pointer => |ptr| {
            // Handle []const u8 and *const [N]u8 (string literals)
            if (ptr.size == .slice and ptr.child == u8) {
                try writeJsonString(writer, val);
            } else if (ptr.size == .one and @typeInfo(ptr.child) == .array and @typeInfo(ptr.child).array.child == u8) {
                try writeJsonString(writer, val);
            } else {
                @compileError("unsupported D1 param type: " ++ @typeName(T));
            }
        },
        .enum_literal => {
            try writeJsonString(writer, @tagName(val));
        },
        else => @compileError("unsupported D1 param type: " ++ @typeName(T)),
    }
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
