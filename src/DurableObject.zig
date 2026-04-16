const std = @import("std");
const js = @import("js.zig");
const Fetch = @import("Fetch.zig");
const Response = @import("Response.zig");
const D1Database = @import("D1Database.zig");
const ContainerMod = @import("Container.zig");

// ===========================================================================
// Client-side types — for calling Durable Objects from a regular Worker.
// ===========================================================================

/// A Durable Object namespace binding, used to create IDs and get stubs.
///
/// ```zig
/// const ns = try env.durableObject("COUNTER");
/// const id = ns.idFromName("room-123");
/// const stub = ns.get(id);
/// var resp = try stub.fetch(allocator, "/increment", .{});
/// ```
pub const Namespace = struct {
    handle: js.Handle,
    allocator: std.mem.Allocator,

    pub fn init(handle: js.Handle, allocator: std.mem.Allocator) Namespace {
        return .{ .handle = handle, .allocator = allocator };
    }

    /// Create a deterministic ID from a string name.
    pub fn idFromName(self: *const Namespace, name: []const u8) Id {
        return .{
            .handle = js.do_ns_id_from_name(self.handle, name.ptr, @intCast(name.len)),
            .allocator = self.allocator,
        };
    }

    /// Recreate an ID from its hex string representation.
    pub fn idFromString(self: *const Namespace, id_str: []const u8) Id {
        return .{
            .handle = js.do_ns_id_from_string(self.handle, id_str.ptr, @intCast(id_str.len)),
            .allocator = self.allocator,
        };
    }

    /// Generate a new unique ID.
    pub fn newUniqueId(self: *const Namespace) Id {
        return .{
            .handle = js.do_ns_new_unique_id(self.handle),
            .allocator = self.allocator,
        };
    }

    /// Get a stub for a specific Durable Object instance.
    pub fn get(self: *const Namespace, id: Id) Stub {
        return .{
            .handle = js.do_ns_get(self.handle, id.handle),
            .allocator = self.allocator,
        };
    }
};

/// A Durable Object ID — identifies a specific instance.
pub const Id = struct {
    handle: js.Handle,
    allocator: std.mem.Allocator,

    /// Get the hex string representation of this ID.
    pub fn toString(self: *const Id) ![]const u8 {
        const h = js.do_id_to_string(self.handle);
        return try js.readString(h, self.allocator);
    }

    /// Check if two IDs refer to the same Durable Object instance.
    pub fn equals(self: *const Id, other: Id) bool {
        return js.do_id_equals(self.handle, other.handle) != 0;
    }

    /// Get the name this ID was created from (if it was created via idFromName).
    /// Returns null for unique IDs.
    pub fn name(self: *const Id) !?[]const u8 {
        const h = js.do_id_name(self.handle);
        if (h == js.null_handle) return null;
        return try js.readString(h, self.allocator);
    }
};

/// A stub (proxy) for a specific Durable Object instance.
/// Use `fetch()` to send requests to the DO.
pub const Stub = struct {
    handle: js.Handle,
    allocator: std.mem.Allocator,

    /// Send a request to the Durable Object. JSPI-suspending.
    /// Returns a Fetch.Response (same as outbound fetch).
    pub fn fetch(self: *const Stub, url: []const u8, options: Fetch.Options) !Fetch.Response {
        const req_h = Fetch.buildRequest(url, options);
        const resp_h = js.do_stub_fetch(self.handle, req_h);
        if (resp_h == js.null_handle) return error.NullHandle;
        return Fetch.Response.init(resp_h, self.allocator);
    }
};

// ===========================================================================
// Server-side types — for implementing Durable Objects in Zig.
// ===========================================================================

/// Durable Object state, passed to every DO method call.
/// Provides access to the object's persistent storage and identity.
pub const State = struct {
    handle: js.Handle,
    allocator: std.mem.Allocator,

    pub fn init(handle: js.Handle, allocator: std.mem.Allocator) State {
        return .{ .handle = handle, .allocator = allocator };
    }

    /// Get the DurableObjectId for this instance.
    pub fn id(self: *const State) Id {
        const h = js.do_state_id(self.handle);
        return .{ .handle = h, .allocator = self.allocator };
    }

    /// Get the persistent storage interface.
    pub fn storage(self: *const State) Storage {
        return .{ .handle = self.handle, .allocator = self.allocator };
    }

    /// Access the facets interface for spawning child DOs.
    pub fn facets(self: *const State) Facets {
        return .{ .state_handle = self.handle, .allocator = self.allocator };
    }

    /// Access the container interface (for DOs with containers enabled).
    pub fn container(self: *const State) ContainerMod {
        return .{ .state_handle = self.handle, .allocator = self.allocator };
    }

    /// Keep the DO alive until the promise-like work completes.
    /// In practice, this is rarely needed from Zig since the handler
    /// runs synchronously via JSPI.
    pub fn blockConcurrencyWhile(self: *const State) void {
        _ = self;
        // Note: blockConcurrencyWhile requires a callback pattern that
        // doesn't map well to JSPI's synchronous model. The DO runtime
        // already serializes requests, so this is rarely needed.
    }
};

// ===========================================================================
// Facets — run dynamically-loaded code with isolated persistent storage.
// ===========================================================================

/// A DurableObjectClass obtained from a dynamically-loaded worker via
/// `WorkerStub.getDurableObjectClass()`. Pass this to `Facets.get()`.
pub const DurableObjectClass = struct {
    handle: js.Handle,
};

/// Interface for managing DO facets (child DOs loaded via Dynamic Workers).
///
/// ```zig
/// // Load dynamic code via WorkerLoader
/// const worker = try loader.get("code-v1", code);
/// const app_class = worker.getDurableObjectClass("App");
///
/// // Create a facet from the dynamic class
/// const f = self.state.facets();
/// const child = f.get("my-facet", app_class, null);
/// var resp = try child.fetch("http://child/hello", .{});
/// ```
pub const Facets = struct {
    state_handle: js.Handle,
    allocator: std.mem.Allocator,

    /// Get or create a facet by name.
    /// `class` is a DurableObjectClass from `WorkerStub.getDurableObjectClass()`.
    /// `id_str` is an optional DurableObjectId hex string; null lets the facet
    /// inherit the parent DO's ID.
    /// Returns a Fetcher for sending requests to the facet.
    pub fn get(self: *const Facets, facet_name: []const u8, class: DurableObjectClass, id_str: ?[]const u8) Fetcher {
        const id_p = if (id_str) |s| s.ptr else @as([*]const u8, "");
        const id_l: u32 = if (id_str) |s| @intCast(s.len) else 0;
        const h = js.do_facets_get(
            self.state_handle,
            facet_name.ptr,
            @intCast(facet_name.len),
            class.handle,
            id_p,
            id_l,
        );
        return .{ .handle = h, .allocator = self.allocator };
    }

    /// Abort a facet, terminating it with the given reason.
    /// Storage is preserved — call get() again to restart with new or same code.
    pub fn abort(self: *const Facets, facet_name: []const u8, reason: []const u8) void {
        js.do_facets_abort(
            self.state_handle,
            facet_name.ptr,
            @intCast(facet_name.len),
            reason.ptr,
            @intCast(reason.len),
        );
    }

    /// Delete a facet and permanently erase its SQLite database.
    pub fn delete(self: *const Facets, facet_name: []const u8) void {
        js.do_facets_delete(
            self.state_handle,
            facet_name.ptr,
            @intCast(facet_name.len),
        );
    }
};

/// A Fetcher handle — returned from facets.get() and WorkerStub.getEntrypoint().
/// Supports the same fetch interface as Stub.
pub const Fetcher = struct {
    handle: js.Handle,
    allocator: std.mem.Allocator,

    /// Send a request to the target. JSPI-suspending.
    pub fn fetch(self: *const Fetcher, url: []const u8, options: Fetch.Options) !Fetch.Response {
        const req_h = Fetch.buildRequest(url, options);
        const resp_h = js.wl_stub_fetch(self.handle, req_h);
        if (resp_h == js.null_handle) return error.NullHandle;
        return Fetch.Response.init(resp_h, self.allocator);
    }
};

/// Persistent key-value storage for a Durable Object.
///
/// All methods are JSPI-suspending.  Values are stored as strings
/// (use JSON serialization for structured data).
pub const Storage = struct {
    handle: js.Handle,
    allocator: std.mem.Allocator,

    /// Get a value by key.  Returns null if the key does not exist.
    pub fn get(self: *const Storage, key: []const u8) !?[]const u8 {
        const h = js.do_storage_get(self.handle, key.ptr, @intCast(key.len));
        if (h == js.null_handle) return null;
        return try js.readString(h, self.allocator);
    }

    /// Store a string value.
    pub fn put(self: *const Storage, key: []const u8, value: []const u8) void {
        js.do_storage_put(self.handle, key.ptr, @intCast(key.len), value.ptr, @intCast(value.len));
    }

    /// Delete a key.  Returns true if the key existed.
    pub fn delete(self: *const Storage, key: []const u8) bool {
        return js.do_storage_delete(self.handle, key.ptr, @intCast(key.len)) != 0;
    }

    /// Delete all keys in storage.
    pub fn deleteAll(self: *const Storage) void {
        js.do_storage_delete_all(self.handle);
    }

    /// List keys in storage.  Returns a JSON string of the form
    /// `{"key1":"value1","key2":"value2",...}`.
    pub fn list(self: *const Storage, options: ListOptions) ![]const u8 {
        const opts_h = buildListOptions(options);
        const h = js.do_storage_list(self.handle, opts_h);
        if (h == js.null_handle) return "{}";
        return try js.readString(h, self.allocator);
    }

    /// Get the currently scheduled alarm time (ms since epoch), or null.
    pub fn getAlarm(self: *const Storage) ?f64 {
        const result = js.do_storage_get_alarm(self.handle);
        if (result < 0) return null;
        return result;
    }

    /// Set an alarm to fire at the given timestamp (ms since epoch).
    pub fn setAlarm(self: *const Storage, scheduled_time_ms: f64) void {
        js.do_storage_set_alarm(self.handle, scheduled_time_ms);
    }

    /// Delete any scheduled alarm.
    pub fn deleteAlarm(self: *const Storage) void {
        js.do_storage_delete_alarm(self.handle);
    }

    /// Access the SQL (SQLite) storage interface.
    pub fn sql(self: *const Storage) SqlStorage {
        return .{ .handle = self.handle, .allocator = self.allocator };
    }

    fn buildListOptions(options: ListOptions) js.Handle {
        if (options.prefix == null and options.start == null and
            options.end == null and options.limit == null and !options.reverse)
        {
            return js.null_handle;
        }
        return js.do_storage_list_options(
            if (options.prefix) |p| p.ptr else @as([*]const u8, ""),
            if (options.prefix) |p| @as(u32, @intCast(p.len)) else 0,
            if (options.start) |s| s.ptr else @as([*]const u8, ""),
            if (options.start) |s| @as(u32, @intCast(s.len)) else 0,
            if (options.end) |e| e.ptr else @as([*]const u8, ""),
            if (options.end) |e| @as(u32, @intCast(e.len)) else 0,
            if (options.limit) |l| l else 0,
            if (options.reverse) @as(u32, 1) else 0,
        );
    }
};

pub const ListOptions = struct {
    prefix: ?[]const u8 = null,
    start: ?[]const u8 = null,
    end: ?[]const u8 = null,
    limit: ?u32 = null,
    reverse: bool = false,
};

// ===========================================================================
// SQL (SQLite) Storage — accessed via Storage.sql()
// ===========================================================================

/// Result of a materialized SQL query (all rows collected).
pub const SqlResult = struct {
    /// JSON array of row objects, e.g. `[{"id":1,"name":"alice"},...]`.
    json: []const u8,
    /// JSON array of column names, e.g. `["id","name"]`.
    columns: []const u8,
    rows_read: u64,
    rows_written: u64,
};

/// SQLite storage interface for Durable Objects.
///
/// All operations are synchronous (no JSPI needed).
///
/// ```zig
/// var storage = self.state.storage();
/// var db = storage.sql();
/// _ = try db.exec("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)", .{});
/// _ = try db.exec("INSERT INTO kv (key, value) VALUES (?, ?)", .{ "hello", "world" });
/// const result = try db.exec("SELECT * FROM kv", .{});
/// ```
pub const SqlStorage = struct {
    handle: js.Handle,
    allocator: std.mem.Allocator,

    /// Execute a SQL query and materialize all results.
    ///
    /// Parameters are serialized as a JSON array (same format as D1).
    /// Returns all rows as a JSON string plus metadata.
    pub fn exec(self: *const SqlStorage, sql_str: []const u8, args: anytype) !SqlResult {
        const params = try D1Database.serializeParams(args, self.allocator);
        return self.execRaw(sql_str, params);
    }

    /// Execute a SQL query with a raw JSON parameter string.
    pub fn execRaw(self: *const SqlStorage, sql_str: []const u8, params: []const u8) !SqlResult {
        const p = if (params.len > 0) params else "[]";
        const h = js.do_sql_exec(self.handle, sql_str.ptr, @intCast(sql_str.len), p.ptr, @intCast(p.len));
        if (h == js.null_handle) return error.SqlExecFailed;
        defer js.js_release(h);
        const json_str = (try js.getStringProp(h, "results", self.allocator)) orelse "[]";
        const columns = (try js.getStringProp(h, "columns", self.allocator)) orelse "[]";
        const rows_read: u64 = @intCast(@max(0, js.getIntProp(h, "rows_read")));
        const rows_written: u64 = @intCast(@max(0, js.getIntProp(h, "rows_written")));
        return .{
            .json = json_str,
            .columns = columns,
            .rows_read = rows_read,
            .rows_written = rows_written,
        };
    }

    /// Execute a SQL query and return the first row as JSON, or null.
    pub fn first(self: *const SqlStorage, sql_str: []const u8, args: anytype) !?[]const u8 {
        const params = try D1Database.serializeParams(args, self.allocator);
        return self.firstRaw(sql_str, params);
    }

    /// Execute a SQL query with raw params and return the first row as JSON.
    pub fn firstRaw(self: *const SqlStorage, sql_str: []const u8, params: []const u8) !?[]const u8 {
        var cur = self.cursorRaw(sql_str, params);
        defer cur.close();
        return try cur.next();
    }

    /// Open a cursor for row-at-a-time iteration.
    pub fn cursor(self: *const SqlStorage, sql_str: []const u8, args: anytype) !SqlCursor {
        const params = try D1Database.serializeParams(args, self.allocator);
        return .{
            .handle = js.do_sql_cursor_open(self.handle, sql_str.ptr, @intCast(sql_str.len), params.ptr, @intCast(params.len)),
            .allocator = self.allocator,
        };
    }

    /// Open a cursor with a raw JSON parameter string.
    pub fn cursorRaw(self: *const SqlStorage, sql_str: []const u8, params: []const u8) SqlCursor {
        const p = if (params.len > 0) params else "[]";
        return .{
            .handle = js.do_sql_cursor_open(self.handle, sql_str.ptr, @intCast(sql_str.len), p.ptr, @intCast(p.len)),
            .allocator = self.allocator,
        };
    }

    /// Get the current database size in bytes.
    pub fn databaseSize(self: *const SqlStorage) u64 {
        const size = js.do_sql_database_size(self.handle);
        return @intFromFloat(@max(0, size));
    }
};

/// A live SQL cursor for iterating rows one at a time.
///
/// ```zig
/// var cur = try db.cursor("SELECT * FROM users WHERE age > ?", .{21});
/// defer cur.close();
/// while (try cur.next()) |row_json| {
///     // row_json is e.g. `{"id":1,"name":"alice","age":30}`
/// }
/// ```
pub const SqlCursor = struct {
    handle: js.Handle,
    allocator: std.mem.Allocator,

    /// Get the next row as a JSON string, or null when exhausted.
    pub fn next(self: *SqlCursor) !?[]const u8 {
        const h = js.do_sql_cursor_next(self.handle);
        if (h == js.null_handle) return null;
        return try js.readString(h, self.allocator);
    }

    /// Get the column names as a JSON array string.
    pub fn columnNames(self: *const SqlCursor) ![]const u8 {
        const h = js.do_sql_cursor_column_names(self.handle);
        if (h == js.null_handle) return "[]";
        return try js.readString(h, self.allocator);
    }

    /// Number of rows read so far.
    pub fn rowsRead(self: *const SqlCursor) u64 {
        const val = js.do_sql_cursor_rows_read(self.handle);
        return @intFromFloat(@max(0, val));
    }

    /// Number of rows written so far.
    pub fn rowsWritten(self: *const SqlCursor) u64 {
        const val = js.do_sql_cursor_rows_written(self.handle);
        return @intFromFloat(@max(0, val));
    }

    /// Release the cursor handle.
    pub fn close(self: *SqlCursor) void {
        if (self.handle != js.null_handle) {
            js.js_release(self.handle);
            self.handle = js.null_handle;
        }
    }
};
