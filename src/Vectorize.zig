const std = @import("std");
const js = @import("js.zig");

// ===========================================================================
// Vectorize — vector database for AI embeddings.
// ===========================================================================

handle: js.Handle,
allocator: std.mem.Allocator,

const Vectorize = @This();

pub fn init(handle: js.Handle, allocator: std.mem.Allocator) Vectorize {
    return .{ .handle = handle, .allocator = allocator };
}

// ---- Types ----------------------------------------------------------------

pub const DistanceMetric = enum {
    euclidean,
    cosine,
    @"dot-product",
};

pub const MetadataRetrievalLevel = enum {
    all,
    indexed,
    none,
};

/// Information about the index configuration.
pub const IndexInfo = struct {
    vectorCount: u64 = 0,
    dimensions: u32 = 0,
    processedUpToDatetime: f64 = 0,
    processedUpToMutation: f64 = 0,
};

/// A single vector with id, values, and optional metadata/namespace.
pub const Vector = struct {
    id: []const u8,
    values: []const f32,
    namespace: ?[]const u8 = null,
    metadata: ?[]const u8 = null, // JSON string
};

/// A match result from a query — vector with a similarity score.
pub const Match = struct {
    id: []const u8,
    score: f64,
    namespace: ?[]const u8 = null,
    metadata: ?[]const u8 = null, // JSON string
    values: ?[]const f32 = null,
};

/// Query results.
pub const Matches = struct {
    matches: []const Match,
    count: u32,
};

/// Async mutation result (returned by insert/upsert/deleteByIds).
pub const AsyncMutation = struct {
    mutationId: []const u8,
};

/// Options for query operations.
pub const QueryOptions = struct {
    topK: u32 = 10,
    namespace: ?[]const u8 = null,
    returnValues: bool = false,
    returnMetadata: MetadataRetrievalLevel = .none,
    filter: ?[]const u8 = null, // JSON filter string
};

// ---- Operations (all JSPI-suspending) -------------------------------------

/// Get information about this index.
pub fn describe(self: *const Vectorize) !IndexInfo {
    const h = js.vectorize_describe(self.handle);
    const json = try js.readString(h, self.allocator);
    defer self.allocator.free(json);
    const parsed = try std.json.parseFromSlice(IndexInfo, self.allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    return parsed.value;
}

/// Query the index with a vector.
pub fn query(self: *const Vectorize, vector: []const f32, options: QueryOptions) ![]const u8 {
    const opts_json = try buildQueryOptionsJson(self.allocator, options);
    defer self.allocator.free(opts_json);

    const h = js.vectorize_query(
        self.handle,
        @ptrCast(vector.ptr),
        @intCast(vector.len * 4),
        opts_json.ptr,
        @intCast(opts_json.len),
    );
    return js.readString(h, self.allocator);
}

/// Query the index by an existing vector's ID.
pub fn queryById(self: *const Vectorize, vector_id: []const u8, options: QueryOptions) ![]const u8 {
    const opts_json = try buildQueryOptionsJson(self.allocator, options);
    defer self.allocator.free(opts_json);

    const h = js.vectorize_query_by_id(
        self.handle,
        vector_id.ptr,
        @intCast(vector_id.len),
        opts_json.ptr,
        @intCast(opts_json.len),
    );
    return js.readString(h, self.allocator);
}

/// Insert new vectors. Returns a mutation ID for tracking.
pub fn insert(self: *const Vectorize, vectors: []const Vector) !AsyncMutation {
    const json = try buildVectorsJson(self.allocator, vectors);
    defer self.allocator.free(json);

    const h = js.vectorize_insert(self.handle, json.ptr, @intCast(json.len));
    const result = try js.readString(h, self.allocator);
    defer self.allocator.free(result);

    return parseMutation(self.allocator, result);
}

/// Insert or update vectors. Returns a mutation ID for tracking.
pub fn upsert(self: *const Vectorize, vectors: []const Vector) !AsyncMutation {
    const json = try buildVectorsJson(self.allocator, vectors);
    defer self.allocator.free(json);

    const h = js.vectorize_upsert(self.handle, json.ptr, @intCast(json.len));
    const result = try js.readString(h, self.allocator);
    defer self.allocator.free(result);

    return parseMutation(self.allocator, result);
}

/// Delete vectors by their IDs. Returns a mutation ID for tracking.
pub fn deleteByIds(self: *const Vectorize, ids: []const []const u8) !AsyncMutation {
    const json = try buildIdsJson(self.allocator, ids);
    defer self.allocator.free(json);

    const h = js.vectorize_delete_by_ids(self.handle, json.ptr, @intCast(json.len));
    const result = try js.readString(h, self.allocator);
    defer self.allocator.free(result);

    return parseMutation(self.allocator, result);
}

/// Get vectors by their IDs. Returns raw JSON.
pub fn getByIds(self: *const Vectorize, ids: []const []const u8) ![]const u8 {
    const json = try buildIdsJson(self.allocator, ids);
    defer self.allocator.free(json);

    const h = js.vectorize_get_by_ids(self.handle, json.ptr, @intCast(json.len));
    return js.readString(h, self.allocator);
}

// ---- JSON builders (testable pure logic) ----------------------------------

fn buildQueryOptionsJson(allocator: std.mem.Allocator, options: QueryOptions) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(allocator);

    try w.writer.writeAll(&.{'{'});
    try w.writer.print("\"topK\":{d}", .{options.topK});
    if (options.namespace) |ns| {
        try w.writer.writeAll(",\"namespace\":");
        try writeJsonString(&w.writer, ns);
    }
    if (options.returnValues) {
        try w.writer.writeAll(",\"returnValues\":true");
    }
    switch (options.returnMetadata) {
        .all => try w.writer.writeAll(",\"returnMetadata\":\"all\""),
        .indexed => try w.writer.writeAll(",\"returnMetadata\":\"indexed\""),
        .none => {},
    }
    if (options.filter) |f| {
        try w.writer.writeAll(",\"filter\":");
        try w.writer.writeAll(f); // raw JSON pass-through
    }
    try w.writer.writeAll(&.{'}'});
    return w.toOwnedSlice();
}

fn buildVectorsJson(allocator: std.mem.Allocator, vectors: []const Vector) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(allocator);

    try w.writer.writeAll(&.{'['});
    for (vectors, 0..) |v, i| {
        if (i > 0) try w.writer.writeAll(&.{','});
        try w.writer.writeAll("{\"id\":");
        try writeJsonString(&w.writer, v.id);
        try w.writer.writeAll(",\"values\":[");
        for (v.values, 0..) |val, j| {
            if (j > 0) try w.writer.writeAll(&.{','});
            try w.writer.print("{d}", .{val});
        }
        try w.writer.writeAll(&.{']'});
        if (v.namespace) |ns| {
            try w.writer.writeAll(",\"namespace\":");
            try writeJsonString(&w.writer, ns);
        }
        if (v.metadata) |meta| {
            try w.writer.writeAll(",\"metadata\":");
            try w.writer.writeAll(meta); // raw JSON pass-through
        }
        try w.writer.writeAll(&.{'}'});
    }
    try w.writer.writeAll(&.{']'});
    return w.toOwnedSlice();
}

fn buildIdsJson(allocator: std.mem.Allocator, ids: []const []const u8) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(allocator);

    try w.writer.writeAll(&.{'['});
    for (ids, 0..) |id, i| {
        if (i > 0) try w.writer.writeAll(&.{','});
        try writeJsonString(&w.writer, id);
    }
    try w.writer.writeAll(&.{']'});
    return w.toOwnedSlice();
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

fn parseMutation(allocator: std.mem.Allocator, json: []const u8) !AsyncMutation {
    // Extract mutationId from {"mutationId":"..."}
    const parsed = try std.json.parseFromSlice(AsyncMutation, allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    // Note: caller owns the parsed memory via the allocator; the parsed struct
    // itself holds slices into allocator-managed memory.
    return parsed.value;
}

// ---- Unit tests -----------------------------------------------------------

test "buildQueryOptionsJson — defaults" {
    const json = try buildQueryOptionsJson(std.testing.allocator, .{});
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("{\"topK\":10}", json);
}

test "buildQueryOptionsJson — all options" {
    const json = try buildQueryOptionsJson(std.testing.allocator, .{
        .topK = 5,
        .namespace = "my-ns",
        .returnValues = true,
        .returnMetadata = .all,
        .filter = "{\"genre\":\"comedy\"}",
    });
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"topK\":5,\"namespace\":\"my-ns\",\"returnValues\":true,\"returnMetadata\":\"all\",\"filter\":{\"genre\":\"comedy\"}}",
        json,
    );
}

test "buildVectorsJson — single vector" {
    const vectors = [_]Vector{
        .{ .id = "vec-1", .values = &.{ 0.1, 0.2, 0.3 } },
    };
    const json = try buildVectorsJson(std.testing.allocator, &vectors);
    defer std.testing.allocator.free(json);
    // Check structure (float formatting may vary)
    try std.testing.expect(std.mem.startsWith(u8, json, "[{\"id\":\"vec-1\",\"values\":["));
    try std.testing.expect(std.mem.endsWith(u8, json, "]}]"));
}

test "buildVectorsJson — with namespace and metadata" {
    const vectors = [_]Vector{
        .{ .id = "v1", .values = &.{1.0}, .namespace = "test", .metadata = "{\"key\":\"val\"}" },
    };
    const json = try buildVectorsJson(std.testing.allocator, &vectors);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"namespace\":\"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"metadata\":{\"key\":\"val\"}") != null);
}

test "buildIdsJson — multiple ids" {
    const ids = [_][]const u8{ "id-1", "id-2", "id-3" };
    const json = try buildIdsJson(std.testing.allocator, &ids);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("[\"id-1\",\"id-2\",\"id-3\"]", json);
}

test "buildIdsJson — empty" {
    const ids = [_][]const u8{};
    const json = try buildIdsJson(std.testing.allocator, &ids);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("[]", json);
}
