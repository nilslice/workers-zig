const std = @import("std");
const js = @import("js.zig");

handle: js.Handle,
allocator: std.mem.Allocator,

const R2Bucket = @This();

pub fn init(handle: js.Handle, allocator: std.mem.Allocator) R2Bucket {
    return .{ .handle = handle, .allocator = allocator };
}

/// Metadata returned from head/get/put operations.
pub const ObjectMeta = struct {
    key: []const u8,
    version: []const u8,
    size: u64,
    etag: []const u8,
    http_etag: []const u8,
};

/// Result of a get operation – metadata + body bytes.
pub const GetResult = struct {
    meta: ObjectMeta,
    body: []const u8,
};

/// Result of a list operation.
pub const ListResult = struct {
    json: []const u8, // raw JSON – caller can parse for objects, cursor, truncated
};

/// Retrieve object metadata only (no body).  Returns null if not found.
pub fn head(self: *const R2Bucket, key: []const u8) !?ObjectMeta {
    const h = js.r2_head(self.handle, key.ptr, @intCast(key.len));
    if (h == js.null_handle) return null;
    defer js.js_release(h);
    return try readMeta(h, self.allocator);
}

/// Get an object (metadata + full body).  Returns null if not found.
pub fn get(self: *const R2Bucket, key: []const u8) !?GetResult {
    const h = js.r2_get(self.handle, key.ptr, @intCast(key.len));
    if (h == js.null_handle) return null;
    defer js.js_release(h);

    const meta = try readMeta(h, self.allocator);

    // The JS shim stores the body as a bytes handle in the "bodyBytes" property.
    const body_bytes_handle = js.getIntProp(h, "bodyBytes");
    const body = if (body_bytes_handle > 0)
        try js.readBytes(@intCast(body_bytes_handle), self.allocator)
    else
        try self.allocator.alloc(u8, 0);

    return .{ .meta = meta, .body = body };
}

/// Upload an object.  Returns metadata of the stored object.
pub fn put(self: *const R2Bucket, key: []const u8, body: []const u8, options: PutOptions) !ObjectMeta {
    const h = js.r2_put(
        self.handle,
        key.ptr,
        @intCast(key.len),
        body.ptr,
        @intCast(body.len),
        if (options.content_type.len > 0) options.content_type.ptr else @as([*]const u8, ""),
        @intCast(options.content_type.len),
    );
    defer js.js_release(h);
    return try readMeta(h, self.allocator);
}

/// Delete one or more objects by key.
pub fn delete(self: *const R2Bucket, key: []const u8) void {
    js.r2_delete(self.handle, key.ptr, @intCast(key.len));
}

/// List objects.  Returns raw JSON for the caller to parse.
pub fn listObjects(self: *const R2Bucket, options: ListOptions) ![]const u8 {
    const h = js.r2_list(
        self.handle,
        if (options.prefix.len > 0) options.prefix.ptr else @as([*]const u8, ""),
        @intCast(options.prefix.len),
        if (options.cursor.len > 0) options.cursor.ptr else @as([*]const u8, ""),
        @intCast(options.cursor.len),
        options.limit,
    );
    return js.readString(h, self.allocator);
}

pub const PutOptions = struct {
    content_type: []const u8 = "",
};

pub const ListOptions = struct {
    prefix: []const u8 = "",
    cursor: []const u8 = "",
    limit: u32 = 1000,
};

// -- internal ---------------------------------------------------------------

fn readMeta(obj_handle: js.Handle, allocator: std.mem.Allocator) !ObjectMeta {
    return .{
        .key = (try js.getStringProp(obj_handle, "key", allocator)) orelse "",
        .version = (try js.getStringProp(obj_handle, "version", allocator)) orelse "",
        .size = @intCast(js.getIntProp(obj_handle, "size")),
        .etag = (try js.getStringProp(obj_handle, "etag", allocator)) orelse "",
        .http_etag = (try js.getStringProp(obj_handle, "httpEtag", allocator)) orelse "",
    };
}
