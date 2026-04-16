const std = @import("std");
const js = @import("js.zig");
const KvNamespace = @import("KvNamespace.zig");
const R2Bucket = @import("R2Bucket.zig");
const D1Database = @import("D1Database.zig");
const Fetch = @import("Fetch.zig");

/// Async operation group.  Schedule multiple concurrent operations, then
/// `await()` them all with a single JSPI suspension (Promise.all under the
/// hood).  Retrieve results from the returned `Future` handles.
///
/// ```zig
/// var group = workers.Async.init(allocator);
/// defer group.deinit();
///
/// const a = group.kvGetText(kv, "key-1");
/// const b = group.kvGetText(kv, "key-2");
/// group.await();
///
/// const v1 = try a.text();
/// const v2 = try b.text();
/// ```

allocator: std.mem.Allocator,
count: u32 = 0,
results_handle: js.Handle = js.null_handle,

const Async = @This();

pub fn init(allocator: std.mem.Allocator) Async {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Async) void {
    if (self.results_handle != js.null_handle) {
        js.async_release_results(self.results_handle);
        self.results_handle = js.null_handle;
    }
}

/// Await all scheduled operations.  Single JSPI suspension regardless of
/// how many ops were queued.  After this returns, all Futures are ready.
pub fn @"await"(self: *Async) void {
    if (self.count == 0) return;
    self.results_handle = js.async_flush();
    self.count = 0;
}

// ---------------------------------------------------------------------------
// KV scheduling
// ---------------------------------------------------------------------------

pub fn kvGetText(self: *Async, kv: *const KvNamespace, key: []const u8) Future {
    const id = js.async_kv_get(kv.handle, key.ptr, @intCast(key.len));
    self.count += 1;
    return .{ .id = id, .async_group = self };
}

pub fn kvGetBytes(self: *Async, kv: *const KvNamespace, key: []const u8) Future {
    const id = js.async_kv_get_blob(kv.handle, key.ptr, @intCast(key.len));
    self.count += 1;
    return .{ .id = id, .async_group = self };
}

pub fn kvPut(self: *Async, kv: *const KvNamespace, key: []const u8, value: []const u8) Future {
    const id = js.async_kv_put(
        kv.handle,
        key.ptr,
        @intCast(key.len),
        value.ptr,
        @intCast(value.len),
        0,
    );
    self.count += 1;
    return .{ .id = id, .async_group = self };
}

pub fn kvPutWithTtl(self: *Async, kv: *const KvNamespace, key: []const u8, value: []const u8, ttl: i64) Future {
    const id = js.async_kv_put(
        kv.handle,
        key.ptr,
        @intCast(key.len),
        value.ptr,
        @intCast(value.len),
        ttl,
    );
    self.count += 1;
    return .{ .id = id, .async_group = self };
}

pub fn kvDelete(self: *Async, kv: *const KvNamespace, key: []const u8) Future {
    const id = js.async_kv_delete(kv.handle, key.ptr, @intCast(key.len));
    self.count += 1;
    return .{ .id = id, .async_group = self };
}

// ---------------------------------------------------------------------------
// R2 scheduling
// ---------------------------------------------------------------------------

pub fn r2Get(self: *Async, bucket: *const R2Bucket, key: []const u8) Future {
    const id = js.async_r2_get(bucket.handle, key.ptr, @intCast(key.len));
    self.count += 1;
    return .{ .id = id, .async_group = self };
}

pub fn r2Head(self: *Async, bucket: *const R2Bucket, key: []const u8) Future {
    const id = js.async_r2_head(bucket.handle, key.ptr, @intCast(key.len));
    self.count += 1;
    return .{ .id = id, .async_group = self };
}

pub fn r2Put(self: *Async, bucket: *const R2Bucket, key: []const u8, body: []const u8, options: R2Bucket.PutOptions) Future {
    const id = js.async_r2_put(
        bucket.handle,
        key.ptr,
        @intCast(key.len),
        body.ptr,
        @intCast(body.len),
        if (options.content_type.len > 0) options.content_type.ptr else @as([*]const u8, ""),
        @intCast(options.content_type.len),
    );
    self.count += 1;
    return .{ .id = id, .async_group = self };
}

pub fn r2Delete(self: *Async, bucket: *const R2Bucket, key: []const u8) Future {
    const id = js.async_r2_delete(bucket.handle, key.ptr, @intCast(key.len));
    self.count += 1;
    return .{ .id = id, .async_group = self };
}

// ---------------------------------------------------------------------------
// D1 scheduling (high-level – comptime-typed params)
// ---------------------------------------------------------------------------

pub fn d1Run(self: *Async, db: *const D1Database, sql: []const u8, args: anytype) !Future {
    const params = try D1Database.serializeParams(args, self.allocator);
    return self.d1QueryRun(db, sql, params);
}

pub fn d1All(self: *Async, db: *const D1Database, sql: []const u8, args: anytype) !Future {
    const params = try D1Database.serializeParams(args, self.allocator);
    return self.d1QueryAll(db, sql, params);
}

pub fn d1First(self: *Async, db: *const D1Database, sql: []const u8, args: anytype) !Future {
    const params = try D1Database.serializeParams(args, self.allocator);
    return self.d1QueryFirst(db, sql, params);
}

// ---------------------------------------------------------------------------
// D1 scheduling (low-level – raw JSON param strings)
// ---------------------------------------------------------------------------

pub fn d1Exec(self: *Async, db: *const D1Database, sql: []const u8) Future {
    const id = js.async_d1_exec(db.handle, sql.ptr, @intCast(sql.len));
    self.count += 1;
    return .{ .id = id, .async_group = self };
}

pub fn d1QueryAll(self: *Async, db: *const D1Database, sql: []const u8, params: []const u8) Future {
    const p = if (params.len > 0) params else "[]";
    const id = js.async_d1_query_all(
        db.handle,
        sql.ptr,
        @intCast(sql.len),
        p.ptr,
        @intCast(p.len),
    );
    self.count += 1;
    return .{ .id = id, .async_group = self };
}

pub fn d1QueryFirst(self: *Async, db: *const D1Database, sql: []const u8, params: []const u8) Future {
    const p = if (params.len > 0) params else "[]";
    const id = js.async_d1_query_first(
        db.handle,
        sql.ptr,
        @intCast(sql.len),
        p.ptr,
        @intCast(p.len),
    );
    self.count += 1;
    return .{ .id = id, .async_group = self };
}

pub fn d1QueryRun(self: *Async, db: *const D1Database, sql: []const u8, params: []const u8) Future {
    const p = if (params.len > 0) params else "[]";
    const id = js.async_d1_query_run(
        db.handle,
        sql.ptr,
        @intCast(sql.len),
        p.ptr,
        @intCast(p.len),
    );
    self.count += 1;
    return .{ .id = id, .async_group = self };
}

// ---------------------------------------------------------------------------
// Fetch scheduling
// ---------------------------------------------------------------------------

pub fn fetch(self: *Async, url: []const u8, options: Fetch.Options) Future {
    const id = Fetch.schedule(url, options);
    self.count += 1;
    return .{ .id = id, .async_group = self };
}

// ---------------------------------------------------------------------------
// Future
// ---------------------------------------------------------------------------

pub const Future = struct {
    id: u32,
    async_group: *Async,

    /// Read the result as a UTF-8 string.  Returns null if the key/object
    /// did not exist.
    pub fn text(self: Future) !?[]const u8 {
        const h = js.async_get_result(self.async_group.results_handle, self.id);
        if (h == js.null_handle) return null;
        const str = try js.readString(h, self.async_group.allocator);
        return str;
    }

    /// Read the result as raw bytes.
    pub fn bytes(self: Future) !?[]const u8 {
        const h = js.async_get_result(self.async_group.results_handle, self.id);
        if (h == js.null_handle) return null;
        const b = try js.readBytes(h, self.async_group.allocator);
        return b;
    }

    /// Read the result as a JSON string (alias for text).
    pub fn json(self: Future) !?[]const u8 {
        return self.text();
    }

    /// Read as R2 GetResult (metadata + body).
    pub fn r2Object(self: Future) !?R2Bucket.GetResult {
        const h = js.async_get_result(self.async_group.results_handle, self.id);
        if (h == js.null_handle) return null;
        defer js.js_release(h);
        const alloc = self.async_group.allocator;

        const meta = R2Bucket.ObjectMeta{
            .key = (try js.getStringProp(h, "key", alloc)) orelse "",
            .version = (try js.getStringProp(h, "version", alloc)) orelse "",
            .size = @intCast(js.getIntProp(h, "size")),
            .etag = (try js.getStringProp(h, "etag", alloc)) orelse "",
            .http_etag = (try js.getStringProp(h, "httpEtag", alloc)) orelse "",
        };

        const body_bytes_handle = js.getIntProp(h, "bodyBytes");
        const body = if (body_bytes_handle > 0)
            try js.readBytes(@intCast(body_bytes_handle), alloc)
        else
            try alloc.alloc(u8, 0);

        return .{ .meta = meta, .body = body };
    }

    /// Read as R2 ObjectMeta (from head).
    pub fn r2Meta(self: Future) !?R2Bucket.ObjectMeta {
        const h = js.async_get_result(self.async_group.results_handle, self.id);
        if (h == js.null_handle) return null;
        defer js.js_release(h);
        const alloc = self.async_group.allocator;
        return R2Bucket.ObjectMeta{
            .key = (try js.getStringProp(h, "key", alloc)) orelse "",
            .version = (try js.getStringProp(h, "version", alloc)) orelse "",
            .size = @intCast(js.getIntProp(h, "size")),
            .etag = (try js.getStringProp(h, "etag", alloc)) orelse "",
            .http_etag = (try js.getStringProp(h, "httpEtag", alloc)) orelse "",
        };
    }

    /// Read as D1 QueryResult.
    pub fn d1Result(self: Future) !D1Database.QueryResult {
        const h = js.async_get_result(self.async_group.results_handle, self.id);
        defer if (h != js.null_handle) js.js_release(h);
        const alloc = self.async_group.allocator;
        const json_val = (try js.getStringProp(h, "results", alloc)) orelse "[]";
        const success = js.getIntProp(h, "success") != 0;
        const rows_read: u64 = @intCast(@max(0, js.getIntProp(h, "rows_read")));
        const rows_written: u64 = @intCast(@max(0, js.getIntProp(h, "rows_written")));
        return .{
            .json = json_val,
            .success = success,
            .rows_read = rows_read,
            .rows_written = rows_written,
        };
    }

    /// Read as first D1 row (JSON string), or null.
    pub fn d1First(self: Future) !?[]const u8 {
        return self.text();
    }

    /// Read as a FetchResponse.
    pub fn fetchResponse(self: Future) !Fetch.Response {
        const h = js.async_get_result(self.async_group.results_handle, self.id);
        if (h == js.null_handle) return error.NullHandle;
        return Fetch.Response.init(h, self.async_group.allocator);
    }

    /// Consume a void result (put, delete).  Releases the handle if any.
    pub fn check(self: Future) void {
        const h = js.async_get_result(self.async_group.results_handle, self.id);
        if (h != js.null_handle) js.js_release(h);
    }
};
