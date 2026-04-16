const std = @import("std");
const js = @import("js.zig");

handle: js.Handle,
allocator: std.mem.Allocator,

const KvNamespace = @This();

pub fn init(handle: js.Handle, allocator: std.mem.Allocator) KvNamespace {
    return .{ .handle = handle, .allocator = allocator };
}

/// Get a value as a UTF-8 string.  Returns null if the key does not exist.
pub fn getText(self: *const KvNamespace, key: []const u8) !?[]const u8 {
    const h = js.kv_get(self.handle, key.ptr, @intCast(key.len));
    if (h == js.null_handle) return null;
    const str = try js.readString(h, self.allocator);
    return str;
}

/// Get a value as raw bytes.  Returns null if the key does not exist.
pub fn getBytes(self: *const KvNamespace, key: []const u8) !?[]const u8 {
    const h = js.kv_get_blob(self.handle, key.ptr, @intCast(key.len));
    if (h == js.null_handle) return null;
    const bytes = try js.readBytes(h, self.allocator);
    return bytes;
}

/// Get a value as a parsed JSON object (returned as the raw JSON string).
/// The caller can use std.json to parse it further.
pub fn getJson(self: *const KvNamespace, key: []const u8) !?[]const u8 {
    // On the JS side, kv_get returns the text representation; caller parses.
    return self.getText(key);
}

/// Options for put operations.
pub const PutOptions = struct {
    /// Expiration TTL in seconds (relative). 0 = no expiry.
    expiration_ttl: i64 = 0,
    /// Absolute expiration as seconds since Unix epoch. 0 = no expiry.
    expiration: i64 = 0,
    /// Arbitrary JSON metadata to store alongside the value.
    metadata: ?[]const u8 = null,
};

/// Store a UTF-8 string value.  `ttl` is expiration TTL in seconds (0 = no expiry).
pub fn putText(self: *const KvNamespace, key: []const u8, value: []const u8, ttl: i64) void {
    js.kv_put_string(self.handle, key.ptr, @intCast(key.len), value.ptr, @intCast(value.len), ttl, 0, @as([*]const u8, ""), 0);
}

/// Store raw bytes.  `ttl` is expiration TTL in seconds (0 = no expiry).
pub fn putBytes(self: *const KvNamespace, key: []const u8, value: []const u8, ttl: i64) void {
    js.kv_put_blob(self.handle, key.ptr, @intCast(key.len), value.ptr, @intCast(value.len), ttl, 0, @as([*]const u8, ""), 0);
}

/// Convenience – put with no TTL.
pub fn put(self: *const KvNamespace, key: []const u8, value: []const u8) void {
    self.putText(key, value, 0);
}

/// Store a UTF-8 string with full options (TTL, absolute expiration, metadata).
pub fn putTextWithOptions(self: *const KvNamespace, key: []const u8, value: []const u8, options: PutOptions) void {
    const meta = options.metadata orelse "";
    js.kv_put_string(
        self.handle,
        key.ptr,
        @intCast(key.len),
        value.ptr,
        @intCast(value.len),
        options.expiration_ttl,
        options.expiration,
        meta.ptr,
        @intCast(meta.len),
    );
}

/// Store raw bytes with full options (TTL, absolute expiration, metadata).
pub fn putBytesWithOptions(self: *const KvNamespace, key: []const u8, value: []const u8, options: PutOptions) void {
    const meta = options.metadata orelse "";
    js.kv_put_blob(
        self.handle,
        key.ptr,
        @intCast(key.len),
        value.ptr,
        @intCast(value.len),
        options.expiration_ttl,
        options.expiration,
        meta.ptr,
        @intCast(meta.len),
    );
}

/// Result from getWithMetadata — value + optional JSON metadata string.
pub const ValueWithMetadata = struct {
    value: []const u8,
    metadata: ?[]const u8,
};

/// Get a text value along with its metadata. Returns null if key doesn't exist.
pub fn getTextWithMetadata(self: *const KvNamespace, key: []const u8) !?ValueWithMetadata {
    const h = js.kv_get_with_metadata(self.handle, key.ptr, @intCast(key.len));
    if (h == js.null_handle) return null;
    // Shim returns a two-element array handle: [valueHandle, metadataHandle]
    const val_h = js.kv_meta_value(h);
    const meta_h = js.kv_meta_metadata(h);
    js.js_release(h);
    if (val_h == js.null_handle) return null;
    const value = try js.readString(val_h, self.allocator);
    const metadata = if (meta_h != js.null_handle)
        try js.readString(meta_h, self.allocator)
    else
        null;
    return .{ .value = value, .metadata = metadata };
}

/// Delete a key.
pub fn delete(self: *const KvNamespace, key: []const u8) void {
    js.kv_delete(self.handle, key.ptr, @intCast(key.len));
}

/// List keys.  Returns a JSON string with `{keys: [{name, ...}], list_complete, cursor}`.
pub fn list(self: *const KvNamespace, options: ListOptions) ![]const u8 {
    const h = js.kv_list(
        self.handle,
        if (options.prefix.len > 0) options.prefix.ptr else @as([*]const u8, ""),
        @intCast(options.prefix.len),
        if (options.cursor.len > 0) options.cursor.ptr else @as([*]const u8, ""),
        @intCast(options.cursor.len),
        options.limit,
    );
    return js.readString(h, self.allocator);
}

pub const ListOptions = struct {
    prefix: []const u8 = "",
    cursor: []const u8 = "",
    limit: u32 = 1000,
};
