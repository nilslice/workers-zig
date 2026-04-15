//! A container running inside a Durable Object.
//!
//! Access via `self.state.container()`.
//!
//! ```zig
//! var ct = self.state.container();
//! ct.start(.{ .enable_internet = true });
//! ct.monitor();  // JSPI-suspending: waits until container exits
//! ```
const std = @import("std");
const js = @import("js.zig");
const Fetch = @import("Fetch.zig");
const DurableObject = @import("DurableObject.zig");

const Container = @This();

state_handle: js.Handle,
allocator: std.mem.Allocator,

/// Whether the container is currently running.
pub fn running(self: *const Container) bool {
    return js.ct_running(self.state_handle) != 0;
}

/// Start the container with the given options.
pub fn start(self: *const Container, options: ?StartupOptions) void {
    const opts_h = if (options) |opts| opts.build() else js.null_handle;
    js.ct_start(self.state_handle, opts_h);
}

/// Wait for the container to exit. JSPI-suspending.
pub fn monitor(self: *const Container) void {
    js.ct_monitor(self.state_handle);
}

/// Destroy the container, optionally with a reason. JSPI-suspending.
pub fn destroy(self: *const Container, reason: ?[]const u8) void {
    const p = if (reason) |r| r.ptr else @as([*]const u8, "");
    const l: u32 = if (reason) |r| @intCast(r.len) else 0;
    js.ct_destroy(self.state_handle, p, l);
}

/// Send a signal to the container process.
pub fn signal(self: *const Container, signo: u32) void {
    js.ct_signal(self.state_handle, signo);
}

/// Get a Fetcher for a TCP port exposed by the container.
pub fn getTcpPort(self: *const Container, port: u32) DurableObject.Fetcher {
    const h = js.ct_get_tcp_port(self.state_handle, port);
    return .{ .handle = h, .allocator = self.allocator };
}

/// Set the inactivity timeout (in milliseconds). JSPI-suspending.
pub fn setInactivityTimeout(self: *const Container, duration_ms: u32) void {
    js.ct_set_inactivity_timeout(self.state_handle, duration_ms);
}

/// Intercept outbound HTTP to a specific address. JSPI-suspending.
pub fn interceptOutboundHttp(self: *const Container, addr: []const u8, binding: DurableObject.Fetcher) void {
    js.ct_intercept_outbound_http(self.state_handle, addr.ptr, @intCast(addr.len), binding.handle);
}

/// Intercept all outbound HTTP traffic. JSPI-suspending.
pub fn interceptAllOutboundHttp(self: *const Container, binding: DurableObject.Fetcher) void {
    js.ct_intercept_all_outbound_http(self.state_handle, binding.handle);
}

/// Intercept outbound HTTPS to a specific address. JSPI-suspending.
pub fn interceptOutboundHttps(self: *const Container, addr: []const u8, binding: DurableObject.Fetcher) void {
    js.ct_intercept_outbound_https(self.state_handle, addr.ptr, @intCast(addr.len), binding.handle);
}

/// Snapshot a directory inside the container. JSPI-suspending.
pub fn snapshotDirectory(self: *const Container, dir: []const u8, snap_name: ?[]const u8) !DirectorySnapshot {
    const np = if (snap_name) |n| n.ptr else @as([*]const u8, "");
    const nl: u32 = if (snap_name) |n| @intCast(n.len) else 0;
    const h = js.ct_snapshot_directory(self.state_handle, dir.ptr, @intCast(dir.len), np, nl);
    if (h == js.null_handle) return error.SnapshotFailed;
    return DirectorySnapshot.fromHandle(h, self.allocator);
}

/// Snapshot the entire container. JSPI-suspending.
pub fn snapshotContainer(self: *const Container, snap_name: ?[]const u8) !Snapshot {
    const np = if (snap_name) |n| n.ptr else @as([*]const u8, "");
    const nl: u32 = if (snap_name) |n| @intCast(n.len) else 0;
    const h = js.ct_snapshot_container(self.state_handle, np, nl);
    if (h == js.null_handle) return error.SnapshotFailed;
    return Snapshot.fromHandle(h, self.allocator);
}

/// Options for starting a container.
pub const StartupOptions = struct {
    enable_internet: bool = false,
    entrypoint_json: ?[]const u8 = null,
    env: ?[]const EnvVar = null,
    labels: ?[]const Label = null,
    container_snapshot: ?Snapshot = null,
    directory_snapshots: ?[]const DirSnapshotRestore = null,

    pub const EnvVar = struct { key: []const u8, value: []const u8 };
    pub const Label = struct { key: []const u8, value: []const u8 };

    pub fn build(self: StartupOptions) js.Handle {
        const h = js.ct_opts_new(if (self.enable_internet) @as(u32, 1) else 0);

        if (self.entrypoint_json) |ep| {
            js.ct_opts_set_entrypoint(h, ep.ptr, @intCast(ep.len));
        }
        if (self.env) |vars| {
            for (vars) |v| {
                js.ct_opts_set_env(h, v.key.ptr, @intCast(v.key.len), v.value.ptr, @intCast(v.value.len));
            }
        }
        if (self.labels) |lbls| {
            for (lbls) |l| {
                js.ct_opts_set_label(h, l.key.ptr, @intCast(l.key.len), l.value.ptr, @intCast(l.value.len));
            }
        }
        if (self.container_snapshot) |snap| {
            js.ct_opts_set_container_snapshot(h, snap.handle);
        }
        if (self.directory_snapshots) |snaps| {
            for (snaps) |ds| {
                const mp = if (ds.mount_point) |m| m.ptr else @as([*]const u8, "");
                const ml: u32 = if (ds.mount_point) |m| @intCast(m.len) else 0;
                js.ct_opts_add_dir_snapshot(h, ds.snapshot.handle, mp, ml);
            }
        }
        return h;
    }
};

/// A container snapshot (whole container).
pub const Snapshot = struct {
    handle: js.Handle,
    id: []const u8,
    size: u64,
    name: ?[]const u8,

    pub fn fromHandle(h: js.Handle, allocator: std.mem.Allocator) !Snapshot {
        const id = (try js.getStringProp(h, "id", allocator)) orelse "";
        const size: u64 = @intCast(@max(0, js.getIntProp(h, "size")));
        const snap_name = try js.getStringProp(h, "name", allocator);
        return .{ .handle = h, .id = id, .size = size, .name = snap_name };
    }
};

/// A directory snapshot (single directory within a container).
pub const DirectorySnapshot = struct {
    handle: js.Handle,
    id: []const u8,
    size: u64,
    dir: []const u8,
    name: ?[]const u8,

    pub fn fromHandle(h: js.Handle, allocator: std.mem.Allocator) !DirectorySnapshot {
        const id = (try js.getStringProp(h, "id", allocator)) orelse "";
        const size: u64 = @intCast(@max(0, js.getIntProp(h, "size")));
        const dir = (try js.getStringProp(h, "dir", allocator)) orelse "";
        const snap_name = try js.getStringProp(h, "name", allocator);
        return .{ .handle = h, .id = id, .size = size, .dir = dir, .name = snap_name };
    }
};

/// Parameters for restoring a directory snapshot.
pub const DirSnapshotRestore = struct {
    snapshot: DirectorySnapshot,
    mount_point: ?[]const u8 = null,
};
