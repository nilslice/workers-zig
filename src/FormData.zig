const std = @import("std");
const js = @import("js.zig");

// ===========================================================================
// FormData — multipart form parsing.
// ===========================================================================

handle: js.Handle,
allocator: std.mem.Allocator,

const FormData = @This();

/// A single form entry — either a string value or a file.
pub const Entry = struct {
    name: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    text: []const u8,
    file: File,
};

pub const File = struct {
    data: []const u8,
    filename: []const u8,
    content_type: []const u8,
};

/// Parse FormData from a Request handle.
/// JSPI-suspending (reads the request body).
///
/// ```zig
/// var form = try FormData.fromRequest(allocator, request.handle);
/// const name = try form.get("username");
/// ```
pub fn fromRequest(allocator: std.mem.Allocator, request_handle: js.Handle) FormData {
    const h = js.formdata_from_request(request_handle);
    return .{ .handle = h, .allocator = allocator };
}

/// Create an empty FormData for building outbound requests.
pub fn init(allocator: std.mem.Allocator) FormData {
    return .{ .handle = js.formdata_new(), .allocator = allocator };
}

/// Get a string value by name. Returns null if not found or if it's a file.
pub fn get(self: *const FormData, name: []const u8) !?[]const u8 {
    const h = js.formdata_get(self.handle, name.ptr, @intCast(name.len));
    if (h == js.null_handle) return null;
    const s = try js.readString(h, self.allocator);
    return s;
}

/// Get all values for a given name as strings.
/// Returns a JSON array string — caller can parse with std.json.
pub fn getAll(self: *const FormData, name: []const u8) ![]const u8 {
    const h = js.formdata_get_all(self.handle, name.ptr, @intCast(name.len));
    return js.readString(h, self.allocator);
}

/// Check if a key exists.
pub fn has(self: *const FormData, name: []const u8) bool {
    return js.formdata_has(self.handle, name.ptr, @intCast(name.len)) != 0;
}

/// Get all entry names.
pub fn keys(self: *const FormData) ![]const u8 {
    const h = js.formdata_keys(self.handle);
    return js.readString(h, self.allocator);
}

/// Get the number of entries.
pub fn len(self: *const FormData) u32 {
    return js.formdata_len(self.handle);
}

/// Get an entry by index. Returns the name and value (string or file bytes).
pub fn getEntry(self: *const FormData, index: u32) !?Entry {
    const name_h = js.formdata_entry_name(self.handle, index);
    if (name_h == js.null_handle) return null;

    const name = try js.readString(name_h, self.allocator);
    const is_file = js.formdata_entry_is_file(self.handle, index);

    if (is_file != 0) {
        const data_h = js.formdata_entry_file_data(self.handle, index);
        const data = try js.readBytes(data_h, self.allocator);
        const fn_h = js.formdata_entry_file_name(self.handle, index);
        const filename = try js.readString(fn_h, self.allocator);
        const ct_h = js.formdata_entry_file_type(self.handle, index);
        const content_type = if (ct_h != js.null_handle)
            try js.readString(ct_h, self.allocator)
        else
            "";
        return .{
            .name = name,
            .value = .{ .file = .{
                .data = data,
                .filename = filename,
                .content_type = content_type,
            } },
        };
    } else {
        const val_h = js.formdata_entry_value(self.handle, index);
        const value = try js.readString(val_h, self.allocator);
        return .{
            .name = name,
            .value = .{ .text = value },
        };
    }
}

/// Delete a key and all its values.
pub fn delete(self: *const FormData, name: []const u8) void {
    js.formdata_delete(self.handle, name.ptr, @intCast(name.len));
}

/// Set a key's value (replaces existing values for that key).
pub fn set(self: *const FormData, name: []const u8, value: []const u8) void {
    js.formdata_set(self.handle, name.ptr, @intCast(name.len), value.ptr, @intCast(value.len));
}

/// Append a string value.
pub fn append(self: *const FormData, name: []const u8, value: []const u8) void {
    js.formdata_append(self.handle, name.ptr, @intCast(name.len), value.ptr, @intCast(value.len));
}

/// Append a file (blob) value.
pub fn appendFile(self: *const FormData, name: []const u8, data: []const u8, filename: []const u8) void {
    js.formdata_append_file(
        self.handle,
        name.ptr,
        @intCast(name.len),
        data.ptr,
        @intCast(data.len),
        filename.ptr,
        @intCast(filename.len),
    );
}
