const std = @import("std");
const js = @import("js.zig");

// ===========================================================================
// Hyperdrive — database connection pooling proxy.
// ===========================================================================

handle: js.Handle,
allocator: std.mem.Allocator,

const Hyperdrive = @This();

pub fn init(handle: js.Handle, allocator: std.mem.Allocator) Hyperdrive {
    return .{ .handle = handle, .allocator = allocator };
}

/// A valid DB connection string (e.g. "postgres://user:pass@host:port/db").
/// This is typically the easiest way to use Hyperdrive — pass it directly
/// to your DB client library.
pub fn connectionString(self: *const Hyperdrive) ![]const u8 {
    const h = js.hyperdrive_connection_string(self.handle);
    return js.readString(h, self.allocator);
}

/// The database host.
pub fn host(self: *const Hyperdrive) ![]const u8 {
    const h = js.hyperdrive_host(self.handle);
    return js.readString(h, self.allocator);
}

/// The database port.
pub fn port(self: *const Hyperdrive) u32 {
    return js.hyperdrive_port(self.handle);
}

/// The database user.
pub fn user(self: *const Hyperdrive) ![]const u8 {
    const h = js.hyperdrive_user(self.handle);
    return js.readString(h, self.allocator);
}

/// The database password.
pub fn password(self: *const Hyperdrive) ![]const u8 {
    const h = js.hyperdrive_password(self.handle);
    return js.readString(h, self.allocator);
}

/// The database name.
pub fn database(self: *const Hyperdrive) ![]const u8 {
    const h = js.hyperdrive_database(self.handle);
    return js.readString(h, self.allocator);
}
