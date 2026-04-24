const std = @import("std");
const workers = @import("workers-zig");
const Request = workers.Request;
const Response = workers.Response;
const Env = workers.Env;
const Context = workers.Context;
const Router = workers.Router;
const DurableObject = workers.DurableObject;
const Workflow = workers.Workflow;
const Queue = workers.Queue;
const Ai = workers.Ai;
const WebSocket = workers.WebSocket;
const StreamingResponse = workers.StreamingResponse;
const Cache = workers.Cache;
const Async = workers.Async;
const Crypto = workers.Crypto;
const FormData = workers.FormData;
const HTMLRewriter = workers.HTMLRewriter;
const WorkerLoader = workers.WorkerLoader;
const Container = workers.Container;
const Tail = workers.Tail;
const ScheduledEvent = workers.ScheduledEvent;

// ---------------------------------------------------------------------------
// Durable Object: Counter
// ---------------------------------------------------------------------------
pub const Counter = struct {
    state: DurableObject.State,
    env: Env,

    pub fn fetch(self: *Counter, request: *Request) !Response {
        const alloc = self.state.allocator;
        const url_str = try request.url();
        const path = extractPath(url_str);
        var storage = self.state.storage();

        if (std.mem.eql(u8, path, "/increment")) {
            const current = try storage.get("count");
            var count: i64 = 0;
            if (current) |val| {
                count = std.fmt.parseInt(i64, val, 10) catch 0;
            }
            count += 1;
            var buf: [32]u8 = undefined;
            const num_str = std.fmt.bufPrint(&buf, "{d}", .{count}) catch "0";
            storage.put("count", num_str);

            return Response.ok(num_str);
        }

        if (std.mem.eql(u8, path, "/get")) {
            const current = try storage.get("count");
            return Response.ok(current orelse "0");
        }

        if (std.mem.eql(u8, path, "/set-alarm")) {
            // Set alarm for 100ms from now
            const body = (try request.body()) orelse "100";
            const delay = std.fmt.parseInt(i64, body, 10) catch 100;
            const now_ms = std.Io.Clock.real.now(workers.io()).toMilliseconds();
            storage.setAlarm(@floatFromInt(now_ms + delay));
            return Response.ok("alarm-set");
        }

        if (std.mem.eql(u8, path, "/get-alarm")) {
            const alarm_time = storage.getAlarm();
            if (alarm_time) |ts| {
                var buf: [64]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "alarm={d:.0}", .{ts}) catch "error";
                return Response.ok(msg);
            }
            return Response.ok("no-alarm");
        }

        if (std.mem.eql(u8, path, "/delete-alarm")) {
            storage.deleteAlarm();
            return Response.ok("alarm-deleted");
        }

        if (std.mem.eql(u8, path, "/delete-all")) {
            storage.deleteAll();
            return Response.ok("deleted-all");
        }

        if (std.mem.eql(u8, path, "/list")) {
            const result = try storage.list(.{});
            return Response.json(result);
        }

        // -- SQL routes --------------------------------------------------------
        if (std.mem.startsWith(u8, path, "/sql")) {
            return handleSql(alloc, storage, path);
        }

        // -- Facets routes (spawn dynamic child DO) ----------------------------
        if (std.mem.eql(u8, path, "/facets/get")) {
            const loader = self.env.workerLoader("LOADER") catch {
                return Response.err(.internal_server_error, "FAIL: LOADER binding not found");
            };
            var code = WorkerLoader.WorkerCode.init("2025-04-01", "worker.js");
            code.addJsModule("worker.js",
                \\import { DurableObject } from "cloudflare:workers";
                \\export class App extends DurableObject {
                \\  fetch(request) {
                \\    let counter = this.ctx.storage.kv.get("counter") || 0;
                \\    ++counter;
                \\    this.ctx.storage.kv.put("counter", counter);
                \\    return new Response("count=" + counter);
                \\  }
                \\}
            );
            const worker = loader.load(code);
            const app_class = worker.getDurableObjectClass("App");
            const f = self.state.facets();
            const child = f.get("test-child", app_class, null);
            var resp = try child.fetch("http://facet/", .{});
            defer resp.deinit();
            const body = try resp.text();
            return Response.ok(body);
        }

        if (std.mem.eql(u8, path, "/facets/delete")) {
            const f = self.state.facets();
            f.delete("test-child");
            return Response.ok("facet-deleted");
        }

        return Response.err(.not_found, "unknown DO route");
    }

    fn handleSql(alloc: std.mem.Allocator, storage: DurableObject.Storage, path: []const u8) !Response {
        const db = storage.sql();

        if (std.mem.eql(u8, path, "/sql/setup")) {
            _ = try db.exec("CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, value REAL)", .{});
            return Response.ok("OK");
        }

        if (std.mem.eql(u8, path, "/sql/insert")) {
            const r = try db.exec("INSERT INTO items (name, value) VALUES (?, ?)", .{ "alpha", 1.5 });
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "written={d}", .{r.rows_written}) catch "error";
            return Response.ok(msg);
        }

        if (std.mem.eql(u8, path, "/sql/insert-multi")) {
            _ = try db.exec("INSERT INTO items (name, value) VALUES (?, ?)", .{ "beta", 2.5 });
            _ = try db.exec("INSERT INTO items (name, value) VALUES (?, ?)", .{ "gamma", 3.5 });
            return Response.ok("OK");
        }

        if (std.mem.eql(u8, path, "/sql/select")) {
            const result = try db.exec("SELECT * FROM items ORDER BY id", .{});
            return Response.ok(result.json);
        }

        if (std.mem.eql(u8, path, "/sql/first")) {
            const row = try db.first("SELECT * FROM items WHERE name = ?", .{"alpha"});
            if (row) |r| return Response.ok(r);
            return Response.err(.not_found, "not found");
        }

        if (std.mem.eql(u8, path, "/sql/cursor")) {
            var cur = try db.cursor("SELECT name FROM items ORDER BY id", .{});
            defer cur.close();

            var names: std.ArrayListUnmanaged(u8) = .empty;
            var count: u32 = 0;
            while (try cur.next()) |row_json| {
                if (count > 0) try names.append(alloc, ',');
                try names.appendSlice(alloc, row_json);
                count += 1;
            }

            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "rows={d} data=[{s}]", .{ count, names.items }) catch "error";
            return Response.ok(msg);
        }

        if (std.mem.eql(u8, path, "/sql/columns")) {
            var cur = try db.cursor("SELECT id, name, value FROM items LIMIT 1", .{});
            defer cur.close();
            const cols = try cur.columnNames();
            return Response.ok(cols);
        }

        if (std.mem.eql(u8, path, "/sql/dbsize")) {
            const size = db.databaseSize();
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "size={d}", .{size}) catch "error";
            return Response.ok(msg);
        }

        return Response.err(.not_found, "unknown sql route");
    }

    pub fn alarm(self: *Counter) !void {
        var storage = self.state.storage();
        storage.put("alarm-fired", "true");
    }
};

// ---------------------------------------------------------------------------
// Workflow: MyWorkflow
// ---------------------------------------------------------------------------
pub const MyWorkflow = struct {
    state: Workflow.State,
    env: Env,

    pub fn run(self: *MyWorkflow, event: *Workflow.Event, step: *Workflow.Step) !void {
        _ = self;

        // Step 1: get event payload
        const payload = try event.payload();

        // Step 2: a step that returns a computed value
        const greeting = try step.do("greet", .{}, struct {
            fn run() []const u8 {
                return "hello from workflow";
            }
        }.run);

        // Step 3: another step that uses the greeting
        _ = try step.do("combine", .{ .retries = .{ .limit = 1, .delay = "1 second", .backoff = .constant } }, struct {
            fn run() []const u8 {
                return "combined-result";
            }
        }.run);

        // Step 4: sleep briefly
        step.sleep("pause", "1 second");

        // Log what we got
        workers.log("workflow done: payload={s} greeting={s}", .{ payload, greeting });
    }
};

// ---------------------------------------------------------------------------
// Main worker fetch handler
// ---------------------------------------------------------------------------
pub fn fetch(request: *Request, env: *Env, ctx: *Context) !Response {
    const url_str = try request.url();
    const method = request.method();

    workers.log("{s} {s}", .{ @tagName(method), url_str });

    // Simple path routing
    const path = extractPath(url_str);

    if (std.mem.eql(u8, path, "/")) {
        return Response.ok("workers-zig test harness");
    }

    // -- Request/Response feature tests ----------------------------------------
    if (std.mem.eql(u8, path, "/request/cf")) {
        if (try request.cf()) |cf| {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "colo={s} country={s} asn={?d} http={s} tls={s}", .{
                cf.colo orelse "?",
                cf.country orelse "?",
                cf.asn,
                cf.httpProtocol orelse "?",
                cf.tlsVersion orelse "?",
            }) catch "format-error";
            return Response.ok(msg);
        }
        // Fallback: check raw JSON is available
        if (try request.cfJson()) |raw| {
            return Response.ok(raw);
        }
        return Response.ok("cf=null");
    }

    if (std.mem.eql(u8, path, "/request/headers")) {
        const hdrs = try request.headers();
        var buf: [2048]u8 = undefined;
        var pos: usize = 0;
        for (hdrs) |h| {
            const entry = std.fmt.bufPrint(buf[pos..], "{s}={s}\n", .{ h.name, h.value }) catch break;
            pos += entry.len;
        }
        return Response.ok(buf[0..pos]);
    }

    if (std.mem.eql(u8, path, "/response/redirect")) {
        return Response.redirect("/target", null);
    }

    if (std.mem.eql(u8, path, "/response/redirect-301")) {
        return Response.redirect("/target", .moved_permanently);
    }

    // -- Stdlib tests (verify WASI shim works) --------------------------------
    if (std.mem.startsWith(u8, path, "/stdlib")) {
        return handleStdlib(request, env, path);
    }

    // -- Filesystem (WASI -> node:fs VFS) -------------------------------------
    if (std.mem.startsWith(u8, path, "/fs")) {
        return handleFs(path);
    }

    // -- WASI environ (backed by process.env) ---------------------------------
    if (std.mem.startsWith(u8, path, "/env-wasi")) {
        return handleEnvWasi(path);
    }

    // -- node:tls-backed TCP socket -------------------------------------------
    if (std.mem.startsWith(u8, path, "/tls")) {
        return handleTls(path);
    }

    // -- KV tests -----------------------------------------------------------
    if (std.mem.startsWith(u8, path, "/kv")) {
        return handleKv(request, env, path);
    }

    // -- R2 tests -----------------------------------------------------------
    if (std.mem.startsWith(u8, path, "/r2")) {
        return handleR2(request, env, path);
    }

    // -- D1 tests -----------------------------------------------------------
    if (std.mem.startsWith(u8, path, "/d1")) {
        return handleD1(request, env, path);
    }

    // -- Fetch tests --------------------------------------------------------
    if (std.mem.startsWith(u8, path, "/fetch")) {
        return handleFetch(request, env, path);
    }

    // -- Streaming tests -------------------------------------------------------
    if (std.mem.startsWith(u8, path, "/stream")) {
        return handleStream(request, env, path);
    }

    // -- Cache tests -----------------------------------------------------------
    if (std.mem.startsWith(u8, path, "/cache")) {
        return handleCache(request, env, path);
    }

    // -- Scheduled verification ------------------------------------------------
    if (std.mem.startsWith(u8, path, "/scheduled")) {
        return handleScheduledVerify(request, env, path);
    }

    // -- WebSocket tests -------------------------------------------------------
    if (std.mem.startsWith(u8, path, "/ws")) {
        return handleWebSocket(request, env, path);
    }

    // -- Durable Object tests --------------------------------------------------
    if (std.mem.startsWith(u8, path, "/do")) {
        return handleDO(request, env, path);
    }

    // -- Worker Loader tests ---------------------------------------------------
    if (std.mem.startsWith(u8, path, "/loader")) {
        return handleLoader(request, env, path);
    }

    // -- Container tests -------------------------------------------------------
    if (std.mem.startsWith(u8, path, "/container")) {
        return handleContainer(request, env, path);
    }

    // -- Queue tests -----------------------------------------------------------
    if (std.mem.startsWith(u8, path, "/queue")) {
        return handleQueue(request, env, path);
    }

    // -- Async tests --------------------------------------------------------
    if (std.mem.startsWith(u8, path, "/async")) {
        return handleAsync(request, env, path);
    }

    // -- AI tests -----------------------------------------------------------
    if (std.mem.startsWith(u8, path, "/ai")) {
        return handleAi(request, env, path);
    }

    // -- Crypto tests -------------------------------------------------------
    if (std.mem.startsWith(u8, path, "/crypto")) {
        return handleCrypto(request, env, path);
    }

    // -- FormData tests -----------------------------------------------------
    if (std.mem.startsWith(u8, path, "/formdata")) {
        return handleFormData(request, env, path);
    }

    // -- HTMLRewriter tests -------------------------------------------------
    if (std.mem.startsWith(u8, path, "/rewriter")) {
        return handleRewriter(request, env, path);
    }

    // -- Workflow tests -----------------------------------------------------
    if (std.mem.startsWith(u8, path, "/workflow")) {
        return handleWorkflow(request, env, path);
    }

    // -- Artifacts tests -------------------------------------------------------
    if (std.mem.startsWith(u8, path, "/artifacts")) {
        return handleArtifacts(request, env, path);
    }

    // -- Tail verification tests ---------------------------------------------
    if (std.mem.startsWith(u8, path, "/tail")) {
        return handleTailVerify(request, env, path);
    }

    // -- Router tests -------------------------------------------------------
    if (std.mem.startsWith(u8, path, "/router")) {
        return handleRouter(request, env, ctx);
    }

    return Response.err(.not_found,"Not Found");
}

// ---------------------------------------------------------------------------
// KV handlers
// ---------------------------------------------------------------------------
fn handleKv(request: *Request, env: *Env, path: []const u8) !Response {
    const kv = try env.kv("TEST_KV");

    if (std.mem.eql(u8, path, "/kv/put")) {
        const body = (try request.body()) orelse return Response.err(.bad_request,"missing body");
        kv.put("test-key", body);
        return Response.ok("OK");
    }

    if (std.mem.eql(u8, path, "/kv/get")) {
        const value = try kv.getText("test-key");
        if (value) |v| {
            return Response.ok(v);
        }
        return Response.err(.not_found,"key not found");
    }

    if (std.mem.eql(u8, path, "/kv/delete")) {
        kv.delete("test-key");
        return Response.ok("OK");
    }

    if (std.mem.eql(u8, path, "/kv/list")) {
        const result = try kv.list(.{});
        return Response.json(result);
    }

    return Response.err(.not_found,"unknown kv route");
}

// ---------------------------------------------------------------------------
// R2 handlers
// ---------------------------------------------------------------------------
fn handleR2(request: *Request, env: *Env, path: []const u8) !Response {
    const bucket = try env.r2("TEST_R2");

    if (std.mem.eql(u8, path, "/r2/put")) {
        const body = (try request.body()) orelse return Response.err(.bad_request,"missing body");
        const meta = try bucket.put("test-object", body, .{ .content_type = "text/plain" });
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "stored {d} bytes, etag={s}", .{ meta.size, meta.etag }) catch "stored";
        return Response.ok(msg);
    }

    if (std.mem.eql(u8, path, "/r2/get")) {
        const result = try bucket.get("test-object");
        if (result) |r| {
            var resp = Response.new();
            resp.setStatus(.ok);
            resp.setHeader("content-type", "application/octet-stream");
            resp.setBody(r.body);
            return resp;
        }
        return Response.err(.not_found,"object not found");
    }

    if (std.mem.eql(u8, path, "/r2/head")) {
        const meta = try bucket.head("test-object");
        if (meta) |m| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "key={s} size={d}", .{ m.key, m.size }) catch "found";
            return Response.ok(msg);
        }
        return Response.err(.not_found,"object not found");
    }

    if (std.mem.eql(u8, path, "/r2/delete")) {
        bucket.delete("test-object");
        return Response.ok("OK");
    }

    if (std.mem.eql(u8, path, "/r2/list")) {
        const result = try bucket.listObjects(.{});
        return Response.json(result);
    }

    return Response.err(.not_found,"unknown r2 route");
}

// ---------------------------------------------------------------------------
// D1 handlers
// ---------------------------------------------------------------------------
fn handleD1(request: *Request, env: *Env, path: []const u8) !Response {
    _ = request;
    const db = try env.d1("TEST_D1");

    if (std.mem.eql(u8, path, "/d1/setup")) {
        _ = try db.exec("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, email TEXT NOT NULL)");
        return Response.ok("OK");
    }

    if (std.mem.eql(u8, path, "/d1/insert")) {
        _ = try db.run("INSERT INTO users (name, email) VALUES (?, ?)", .{ "alice", "alice@example.com" });
        return Response.ok("OK");
    }

    if (std.mem.eql(u8, path, "/d1/select")) {
        const result = try db.all("SELECT * FROM users", .{});
        return Response.json(result.json);
    }

    if (std.mem.eql(u8, path, "/d1/first")) {
        const row = try db.first("SELECT * FROM users WHERE name = ?", .{"alice"});
        if (row) |r| {
            return Response.json(r);
        }
        return Response.err(.not_found,"not found");
    }

    return Response.err(.not_found,"unknown d1 route");
}

// ---------------------------------------------------------------------------
// Fetch handlers
// ---------------------------------------------------------------------------
fn handleFetch(_: *Request, env: *Env, path: []const u8) !Response {
    const alloc = env.allocator;

    // -- Simple GET ---------------------------------------------------------
    if (std.mem.eql(u8, path, "/fetch/get")) {
        var resp = try workers.fetch(alloc, "https://example.com", .{});
        defer resp.deinit();
        const code = resp.status();
        const body = try resp.text();
        const has_html = std.mem.indexOf(u8, body, "Example Domain") != null;
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "status={d} html={}", .{ @intFromEnum(code), has_html }) catch "error";
        return Response.ok(msg);
    }

    // -- Response headers ---------------------------------------------------
    if (std.mem.eql(u8, path, "/fetch/headers")) {
        var resp = try workers.fetch(alloc, "https://example.com", .{});
        defer resp.deinit();
        const ct = (try resp.header("content-type")) orelse "none";
        const has_html = std.mem.indexOf(u8, ct, "text/html") != null;
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "has_html_ct={}", .{has_html}) catch "error";
        return Response.ok(msg);
    }

    // -- POST with headers and body -----------------------------------------
    if (std.mem.eql(u8, path, "/fetch/post")) {
        var resp = try workers.fetch(alloc, "https://httpbin.org/post", .{
            .method = .POST,
            .headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "x-test-header", .value = "zig-workers" },
            },
            .body = .{ .bytes = "{\"hello\":\"world\"}" },
        });
        defer resp.deinit();
        const code = resp.status();
        const body = try resp.text();
        const has_echo = std.mem.indexOf(u8, body, "zig-workers") != null;
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "status={d} echo={}", .{ @intFromEnum(code), has_echo }) catch "error";
        return Response.ok(msg);
    }

    // -- Concurrent async fetches -------------------------------------------
    if (std.mem.eql(u8, path, "/fetch/async")) {
        var group = Async.init(alloc);
        defer group.deinit();

        const f1 = group.fetch("https://example.com", .{});
        const f2 = group.fetch("https://example.com", .{});
        group.@"await"();

        var r1 = try f1.fetchResponse();
        defer r1.deinit();
        var r2 = try f2.fetchResponse();
        defer r2.deinit();

        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "s1={d} s2={d}", .{ @intFromEnum(r1.status()), @intFromEnum(r2.status()) }) catch "error";
        return Response.ok(msg);
    }

    // -- Io.Reader integration -------------------------------------------------
    if (std.mem.eql(u8, path, "/fetch/reader")) {
        var resp = try workers.fetch(alloc, "https://example.com", .{});
        defer resp.deinit();

        // Get an std.Io.Reader over the response body
        var r = try resp.reader();

        // Use Reader.peek to read first bytes
        const peeked = r.peek(15) catch return Response.err(.internal_server_error,"peek failed");
        const starts_with_doctype = std.mem.startsWith(u8, peeked, "<!doctype") or
            std.mem.startsWith(u8, peeked, "<!DOCTYPE");

        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "reader_ok={} len={d}", .{ starts_with_doctype, peeked.len }) catch "error";
        return Response.ok(msg);
    }

    return Response.err(.not_found,"unknown fetch route");
}

// ---------------------------------------------------------------------------
// Async handlers
// ---------------------------------------------------------------------------
fn handleAsync(_: *Request, env: *Env, path: []const u8) !Response {
    const kv = try env.kv("TEST_KV");
    const bucket = try env.r2("TEST_R2");
    const db = try env.d1("TEST_D1");
    const alloc = env.allocator;

    // -- KV text: concurrent put then concurrent get ------------------------
    if (std.mem.eql(u8, path, "/async/kv")) {
        var puts = Async.init(alloc);
        defer puts.deinit();
        const p1 = puts.kvPut(&kv, "async-a", "value-a");
        const p2 = puts.kvPut(&kv, "async-b", "value-b");
        puts.@"await"();
        p1.check();
        p2.check();

        var gets = Async.init(alloc);
        defer gets.deinit();
        const g1 = gets.kvGetText(&kv, "async-a");
        const g2 = gets.kvGetText(&kv, "async-b");
        gets.@"await"();

        const v1 = (try g1.text()) orelse "null";
        const v2 = (try g2.text()) orelse "null";

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s},{s}", .{ v1, v2 }) catch "error";
        return Response.ok(msg);
    }

    // -- KV bytes: put text then read back as bytes -------------------------
    if (std.mem.eql(u8, path, "/async/kv-bytes")) {
        kv.put("async-blob", "binary-data");

        var g = Async.init(alloc);
        defer g.deinit();
        const f = g.kvGetBytes(&kv, "async-blob");
        g.@"await"();

        const b = (try f.bytes()) orelse "null";
        return Response.ok(b);
    }

    // -- KV delete: concurrent delete then verify gone ----------------------
    if (std.mem.eql(u8, path, "/async/kv-delete")) {
        kv.put("async-del-1", "x");
        kv.put("async-del-2", "y");

        var dels = Async.init(alloc);
        defer dels.deinit();
        const d1 = dels.kvDelete(&kv, "async-del-1");
        const d2 = dels.kvDelete(&kv, "async-del-2");
        dels.@"await"();
        d1.check();
        d2.check();

        var gets = Async.init(alloc);
        defer gets.deinit();
        const g1 = gets.kvGetText(&kv, "async-del-1");
        const g2 = gets.kvGetText(&kv, "async-del-2");
        gets.@"await"();

        const v1 = (try g1.text()) orelse "gone";
        const v2 = (try g2.text()) orelse "gone";

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s},{s}", .{ v1, v2 }) catch "error";
        return Response.ok(msg);
    }

    // -- R2 head: put then concurrent head ----------------------------------
    if (std.mem.eql(u8, path, "/async/r2-head")) {
        _ = try bucket.put("async-r2-obj", "r2-payload", .{ .content_type = "text/plain" });

        var g = Async.init(alloc);
        defer g.deinit();
        const f = g.r2Head(&bucket, "async-r2-obj");
        g.@"await"();

        const meta = try f.r2Meta();
        if (meta) |m| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "key={s} size={d}", .{ m.key, m.size }) catch "error";
            return Response.ok(msg);
        }
        return Response.err(.not_found,"not found");
    }

    // -- R2 delete: concurrent delete then verify gone ----------------------
    if (std.mem.eql(u8, path, "/async/r2-delete")) {
        _ = try bucket.put("async-r2-del", "temp", .{});

        var dels = Async.init(alloc);
        defer dels.deinit();
        const d = dels.r2Delete(&bucket, "async-r2-del");
        dels.@"await"();
        d.check();

        const after = try bucket.head("async-r2-del");
        if (after != null) {
            return Response.ok("still-exists");
        }
        return Response.ok("gone");
    }

    // -- R2 get: concurrent put then concurrent get with .r2Object() --------
    if (std.mem.eql(u8, path, "/async/r2-get")) {
        var puts = Async.init(alloc);
        defer puts.deinit();
        const rp = puts.r2Put(&bucket, "async-r2-a", "alpha", .{ .content_type = "text/plain" });
        puts.@"await"();
        rp.check();

        var gets = Async.init(alloc);
        defer gets.deinit();
        const f = gets.r2Get(&bucket, "async-r2-a");
        gets.@"await"();

        const result = try f.r2Object();
        if (result) |r| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "key={s} body={s}", .{ r.meta.key, r.body }) catch "error";
            return Response.ok(msg);
        }
        return Response.err(.not_found,"not found");
    }

    // -- D1 async: concurrent setup + insert + select -----------------------
    if (std.mem.eql(u8, path, "/async/d1")) {
        // Setup table (sync, since later ops depend on it)
        _ = try db.exec("CREATE TABLE IF NOT EXISTS async_test (id INTEGER PRIMARY KEY AUTOINCREMENT, val TEXT NOT NULL)");

        // Concurrent inserts
        var ins = Async.init(alloc);
        defer ins.deinit();
        const ins_a = try ins.d1Run(&db, "INSERT INTO async_test (val) VALUES (?)", .{"one"});
        const ins_b = try ins.d1Run(&db, "INSERT INTO async_test (val) VALUES (?)", .{"two"});
        ins.@"await"();

        const res_a = try ins_a.d1Result();
        const res_b = try ins_b.d1Result();
        if (!res_a.success or !res_b.success) {
            return Response.err(.internal_server_error,"insert failed");
        }

        // Concurrent queryAll + queryFirst
        var q = Async.init(alloc);
        defer q.deinit();
        const fa = try q.d1All(&db, "SELECT * FROM async_test", .{});
        const ff = try q.d1First(&db, "SELECT * FROM async_test WHERE val = ?", .{"one"});
        q.@"await"();

        const all_result = try fa.d1Result();
        const first_row = try ff.d1First();

        const has_all = std.mem.indexOf(u8, all_result.json, "one") != null and
            std.mem.indexOf(u8, all_result.json, "two") != null;
        const has_first = if (first_row) |r| std.mem.indexOf(u8, r, "one") != null else false;

        if (has_all and has_first) {
            return Response.ok("d1-ok");
        }
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "all={s} first={s}", .{ all_result.json, first_row orelse "null" }) catch "error";
        return Response.ok(msg);
    }

    // -- Mixed: KV + R2 concurrent ------------------------------------------
    if (std.mem.eql(u8, path, "/async/mixed")) {
        var puts = Async.init(alloc);
        defer puts.deinit();
        const pk = puts.kvPut(&kv, "async-mix", "from-kv");
        const pr = puts.r2Put(&bucket, "async-mix", "from-r2", .{ .content_type = "text/plain" });
        puts.@"await"();
        pk.check();
        pr.check();

        var gets = Async.init(alloc);
        defer gets.deinit();
        const gk = gets.kvGetText(&kv, "async-mix");
        const gr = gets.r2Get(&bucket, "async-mix");
        gets.@"await"();

        const kv_val = (try gk.text()) orelse "null";
        const r2_result = try gr.r2Object();
        const r2_val = if (r2_result) |r| r.body else "null";

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s},{s}", .{ kv_val, r2_val }) catch "error";
        return Response.ok(msg);
    }

    return Response.err(.not_found,"unknown async route");
}

// ---------------------------------------------------------------------------
// Streaming handlers
// ---------------------------------------------------------------------------
fn handleStream(_: *Request, _: *Env, path: []const u8) !Response {
    // -- Basic: stream multiple chunks ----------------------------------------
    if (std.mem.eql(u8, path, "/stream/basic")) {
        var stream = StreamingResponse.start(.{ .status = .ok });
        stream.setHeader("content-type", "text/plain");

        stream.write("chunk1,");
        stream.write("chunk2,");
        stream.write("chunk3");
        stream.close();

        return stream.response();
    }

    // -- Headers: verify status and custom headers come through ---------------
    if (std.mem.eql(u8, path, "/stream/headers")) {
        var stream = StreamingResponse.start(.{ .status = .created });
        stream.setHeader("content-type", "application/json");
        stream.setHeader("x-stream-test", "yes");

        stream.write("{\"streamed\":true}");
        stream.close();

        return stream.response();
    }

    // -- Large: many chunks to verify no truncation ---------------------------
    if (std.mem.eql(u8, path, "/stream/large")) {
        var stream = StreamingResponse.start(.{ .status = .ok });
        stream.setHeader("content-type", "text/plain");

        for (0..100) |i| {
            _ = i;
            stream.write("AAAAAAAAAA"); // 10 bytes x 100 = 1000 bytes
        }
        stream.close();

        return stream.response();
    }

    // -- Timed: prove chunks arrive incrementally with delays -----------------
    if (std.mem.eql(u8, path, "/stream/timed")) {
        var stream = StreamingResponse.start(.{ .status = .ok });
        stream.setHeader("content-type", "text/plain");

        stream.write("A");
        workers.sleep(200);
        stream.write("B");
        workers.sleep(200);
        stream.write("C");
        stream.close();

        return stream.response();
    }

    return Response.err(.not_found, "unknown stream route");
}

// ---------------------------------------------------------------------------
// Cache handlers
// ---------------------------------------------------------------------------
fn handleCache(request: *Request, _: *Env, path: []const u8) !Response {
    const cache = Cache.default();

    // -- Put: store a response in cache then verify it's there ----------------
    if (std.mem.eql(u8, path, "/cache/put")) {
        var resp = Response.ok("cached-body");
        resp.setHeader("cache-control", "max-age=60");
        resp.setHeader("x-custom", "hello");
        cache.put(.{ .url = "/test-cache-key" }, &resp);
        return Response.ok("OK");
    }

    // -- Match: retrieve a cached response ------------------------------------
    if (std.mem.eql(u8, path, "/cache/match")) {
        if (cache.match(.{ .url = "/test-cache-key" })) |cached| {
            return cached;
        }
        return Response.err(.not_found, "cache miss");
    }

    // -- Delete: remove from cache --------------------------------------------
    if (std.mem.eql(u8, path, "/cache/delete")) {
        const deleted = cache.delete(.{ .url = "/test-cache-key" });
        if (deleted) {
            return Response.ok("deleted");
        }
        return Response.ok("not-found");
    }

    // -- Miss: confirm a key that was never stored returns null ----------------
    if (std.mem.eql(u8, path, "/cache/miss")) {
        if (cache.match(.{ .url = "/nonexistent-key" })) |_| {
            return Response.ok("unexpected-hit");
        }
        return Response.ok("miss");
    }

    // -- Request-based: put+match using the same Request URL ------------------
    // Both /cache/req-test routes share the same cache key "/cache/req-test".
    // First call puts, second call matches.
    if (std.mem.eql(u8, path, "/cache/req-test")) {
        // Try match first — if cached, return it
        if (cache.match(.{ .request = request })) |cached| {
            return cached;
        }
        // Not cached — store and confirm
        var resp = Response.ok("req-cached");
        resp.setHeader("cache-control", "max-age=60");
        cache.put(.{ .request = request }, &resp);
        return Response.ok("stored");
    }

    return Response.err(.not_found, "unknown cache route");
}

// ---------------------------------------------------------------------------
// Scheduled handler
// ---------------------------------------------------------------------------
pub fn scheduled(event: *ScheduledEvent, env: *Env, _: *Context) !void {
    const cron_str = try event.cron();
    const time = event.scheduledTime();

    workers.log("scheduled: cron={s} time={d}", .{ cron_str, time });

    // Write a marker to KV so the fetch-based test can verify the handler ran.
    const kv = try env.kv("TEST_KV");
    var buf: [256]u8 = undefined;
    const marker = std.fmt.bufPrint(&buf, "cron={s} time={d:.0}", .{ cron_str, time }) catch "error";
    kv.put("scheduled-marker", marker);
}

fn handleScheduledVerify(_: *Request, env: *Env, path: []const u8) !Response {
    const kv = try env.kv("TEST_KV");

    if (std.mem.eql(u8, path, "/scheduled/verify")) {
        const value = try kv.getText("scheduled-marker");
        if (value) |v| {
            return Response.ok(v);
        }
        return Response.err(.not_found, "no scheduled marker found");
    }

    if (std.mem.eql(u8, path, "/scheduled/clear")) {
        kv.delete("scheduled-marker");
        return Response.ok("OK");
    }

    return Response.err(.not_found, "unknown scheduled route");
}

// ---------------------------------------------------------------------------
// Durable Object handlers (client-side — calls the Counter DO)
// ---------------------------------------------------------------------------
fn handleDO(_: *Request, env: *Env, path: []const u8) !Response {
    const ns = try env.durableObject("COUNTER");
    const id = ns.idFromName("test-counter");
    const stub = ns.get(id);

    if (std.mem.eql(u8, path, "/do/increment")) {
        var resp = try stub.fetch("http://do/increment", .{});
        defer resp.deinit();
        const body = try resp.text();
        return Response.ok(body);
    }

    if (std.mem.eql(u8, path, "/do/get")) {
        var resp = try stub.fetch("http://do/get", .{});
        defer resp.deinit();
        const body = try resp.text();
        return Response.ok(body);
    }

    if (std.mem.eql(u8, path, "/do/reset")) {
        var resp = try stub.fetch("http://do/delete-all", .{});
        defer resp.deinit();
        const body = try resp.text();
        return Response.ok(body);
    }

    if (std.mem.eql(u8, path, "/do/list")) {
        var resp = try stub.fetch("http://do/list", .{});
        defer resp.deinit();
        const body = try resp.text();
        return Response.ok(body);
    }

    if (std.mem.eql(u8, path, "/do/id")) {
        const id_str = try id.toString();
        const name_str = (try id.name()) orelse "unnamed";
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "id={s} name={s}", .{ id_str[0..@min(id_str.len, 16)], name_str }) catch "error";
        return Response.ok(msg);
    }

    if (std.mem.eql(u8, path, "/do/id-equals")) {
        const id2 = ns.idFromName("test-counter");
        const id3 = ns.idFromName("other-counter");
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "same={} diff={}", .{ id.equals(id2), id.equals(id3) }) catch "error";
        return Response.ok(msg);
    }

    if (std.mem.eql(u8, path, "/do/set-alarm")) {
        var resp = try stub.fetch("http://do/set-alarm", .{ .method = .POST, .body = .{ .bytes = "500" } });
        defer resp.deinit();
        return Response.ok(try resp.text());
    }

    if (std.mem.eql(u8, path, "/do/check-alarm")) {
        // Check if alarm-fired marker exists
        var resp = try stub.fetch("http://do/get-alarm", .{});
        defer resp.deinit();
        return Response.ok(try resp.text());
    }

    // -- Generic DO sub-path proxy (handles /do/sql/* and any future routes) ---
    // Forwards /do/<sub-path> to the DO as http://do/<sub-path>.
    {
        const do_path = path[3..]; // strip "/do" prefix → "/sql/setup", etc.
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "http://do{s}", .{do_path}) catch
            return Response.err(.internal_server_error, "url too long");
        var resp = try stub.fetch(url, .{});
        defer resp.deinit();
        return Response.ok(try resp.text());
    }
}

// ---------------------------------------------------------------------------
// WebSocket handlers
// ---------------------------------------------------------------------------
fn handleWebSocket(request: *Request, _: *Env, path: []const u8) !Response {
    _ = request;
    const alloc = std.heap.wasm_allocator;

    // -- Echo: echoes text and binary messages back to the client -------------
    if (std.mem.eql(u8, path, "/ws/echo")) {
        var ws = WebSocket.init(alloc);
        ws.accept();

        while (ws.receive()) |event| {
            switch (event.type()) {
                .text => {
                    const msg = try event.text();
                    ws.sendText(msg);
                },
                .binary => {
                    const msg = try event.data();
                    ws.sendBinary(msg);
                },
                .close => {
                    ws.close(1000, "echo-close");
                    break;
                },
                .err => break,
            }
        }

        return ws.response();
    }

    // -- Greeting: sends a welcome message, echoes one, then server-closes ---
    if (std.mem.eql(u8, path, "/ws/greeting")) {
        var ws = WebSocket.init(alloc);
        ws.accept();

        ws.sendText("welcome");

        if (ws.receive()) |event| {
            if (event.type() == .text) {
                const msg = try event.text();
                var buf: [256]u8 = undefined;
                const reply = std.fmt.bufPrint(&buf, "hello, {s}!", .{msg}) catch "hello!";
                ws.sendText(reply);
            }
        }

        ws.close(1000, "goodbye");
        return ws.response();
    }

    // -- Binary: echoes binary data with a prefix byte -----------------------
    if (std.mem.eql(u8, path, "/ws/binary")) {
        var ws = WebSocket.init(alloc);
        ws.accept();

        while (ws.receive()) |event| {
            switch (event.type()) {
                .binary => {
                    const msg = try event.data();
                    const reply = try alloc.alloc(u8, msg.len + 1);
                    reply[0] = 0xFF;
                    @memcpy(reply[1..], msg);
                    ws.sendBinary(reply);
                },
                .close => {
                    ws.close(event.closeCode(), try event.closeReason());
                    break;
                },
                else => {},
            }
        }

        return ws.response();
    }

    // -- Close code: accepts, waits for client close, echoes the code back ---
    if (std.mem.eql(u8, path, "/ws/close-code")) {
        var ws = WebSocket.init(alloc);
        ws.accept();

        while (ws.receive()) |event| {
            switch (event.type()) {
                .close => {
                    var buf: [64]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "code={d}", .{event.closeCode()}) catch "error";
                    ws.sendText(msg);
                    ws.close(event.closeCode(), try event.closeReason());
                    break;
                },
                else => {},
            }
        }

        return ws.response();
    }

    // -- Connect: outbound WS client to an external echo server ---------------
    if (std.mem.eql(u8, path, "/ws/connect")) {
        var ws = WebSocket.connect(alloc, "wss://echo.websocket.events") catch {
            return Response.ok("connect-failed");
        };

        ws.sendText("outbound-ping");

        // Read messages until we see our echo (skip any welcome/info messages).
        var got_echo = false;
        var attempts: u32 = 0;
        while (attempts < 10) : (attempts += 1) {
            if (ws.receive()) |event| {
                switch (event.type()) {
                    .text => {
                        const msg = try event.text();
                        if (std.mem.eql(u8, msg, "outbound-ping")) {
                            got_echo = true;
                            break;
                        }
                    },
                    .close, .err => break,
                    else => {},
                }
            } else break;
        }

        ws.close(1000, "done");

        if (got_echo) {
            return Response.ok("outbound-ping");
        }
        // Still connected and received messages — outbound WS works.
        return Response.ok("connected-ok");
    }

    return Response.err(.not_found, "unknown ws route");
}

// ---------------------------------------------------------------------------
// Worker Loader handlers
// ---------------------------------------------------------------------------
fn handleLoader(_: *Request, env: *Env, path: []const u8) !Response {
    // Worker Loader may not be available in local dev — handle gracefully.
    const loader = env.workerLoader("LOADER") catch {
        return Response.ok("loader-not-available");
    };

    if (std.mem.eql(u8, path, "/loader/basic")) {
        // Load a minimal JS worker that responds with "hello from dynamic worker"
        var code = WorkerLoader.WorkerCode.init("2025-04-01", "index.js");
        code.addJsModule("index.js",
            \\export default {
            \\  async fetch(req) { return new Response("hello from dynamic worker"); }
            \\};
        );

        const stub = loader.load(code);
        const fetcher = stub.getEntrypoint(null);
        var resp = try fetcher.fetch("http://fake-host/", .{});
        defer resp.deinit();
        return Response.ok(try resp.text());
    }

    if (std.mem.eql(u8, path, "/loader/with-env")) {
        var code = WorkerLoader.WorkerCode.init("2025-04-01", "index.js");
        code.addJsModule("index.js",
            \\export default {
            \\  async fetch(req, env) { return new Response("greeting=" + env.MSG); }
            \\};
        );
        code.setEnvJson("{\"MSG\":\"hi from zig\"}");

        const stub = loader.load(code);
        var resp = try stub.fetch("http://fake-host/", .{});
        defer resp.deinit();
        return Response.ok(try resp.text());
    }

    if (std.mem.eql(u8, path, "/loader/with-limits")) {
        var code = WorkerLoader.WorkerCode.init("2025-04-01", "index.js");
        code.addJsModule("index.js",
            \\export default {
            \\  async fetch(req) { return new Response("limited"); }
            \\};
        );
        code.setCpuMs(50);
        code.setSubRequests(5);

        const stub = loader.load(code);
        var resp = try stub.fetch("http://fake-host/", .{});
        defer resp.deinit();
        return Response.ok(try resp.text());
    }

    return Response.err(.not_found, "unknown loader route");
}

// ---------------------------------------------------------------------------
// Container tests — verify Container API builds and types are correct.
// Containers require special wrangler config, so these routes test the Zig
// API surface (builder, options) without actually starting a container.
// ---------------------------------------------------------------------------
fn handleContainer(_: *Request, _: *Env, path: []const u8) !Response {
    // Test: StartupOptions builder constructs without error.
    if (std.mem.eql(u8, path, "/container/options")) {
        const opts = Container.StartupOptions{
            .enable_internet = true,
            .entrypoint_json = "[\"python\", \"app.py\"]",
            .env = &.{
                .{ .key = "PORT", .value = "8080" },
                .{ .key = "ENV", .value = "production" },
            },
            .labels = &.{
                .{ .key = "app", .value = "myservice" },
            },
        };
        // Build the JS options object to verify FFI round-trip
        const h = opts.build();
        if (h == 0) return Response.err(.internal_server_error, "opts build returned null");
        return Response.ok("options:ok");
    }

    // Test: Container API surface is accessible from DO state.
    // This exercises the type wiring (State -> Container) without needing
    // a real container runtime. We just verify the methods exist and the
    // types compile correctly.
    if (std.mem.eql(u8, path, "/container/api-check")) {
        // Verify Container type has all expected methods by referencing them.
        // These won't be called (no container binding in test), just type-checked.
        const CT = Container;
        const has_running = @hasDecl(CT, "running");
        const has_start = @hasDecl(CT, "start");
        const has_monitor = @hasDecl(CT, "monitor");
        const has_destroy = @hasDecl(CT, "destroy");
        const has_signal = @hasDecl(CT, "signal");
        const has_get_tcp_port = @hasDecl(CT, "getTcpPort");
        const has_set_timeout = @hasDecl(CT, "setInactivityTimeout");
        const has_intercept = @hasDecl(CT, "interceptOutboundHttp");
        const has_intercept_all = @hasDecl(CT, "interceptAllOutboundHttp");
        const has_intercept_https = @hasDecl(CT, "interceptOutboundHttps");
        const has_snap_dir = @hasDecl(CT, "snapshotDirectory");
        const has_snap_ct = @hasDecl(CT, "snapshotContainer");

        const all_ok = has_running and has_start and has_monitor and has_destroy and
            has_signal and has_get_tcp_port and has_set_timeout and has_intercept and
            has_intercept_all and has_intercept_https and has_snap_dir and has_snap_ct;

        if (all_ok) {
            return Response.ok("api:12/12");
        }
        return Response.err(.internal_server_error, "missing methods");
    }

    return Response.err(.not_found, "unknown container route");
}

// ---------------------------------------------------------------------------
// Stdlib tests — verify Zig standard library works via WASI shim
// ---------------------------------------------------------------------------
fn handleStdlib(_: *Request, _: *Env, path: []const u8) !Response {
    // -- std.Io clock (compiles to WASI clock_time_get) --
    if (std.mem.eql(u8, path, "/stdlib/time")) {
        const ms = std.Io.Clock.real.now(workers.io()).toMilliseconds();
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "ms={d}", .{ms}) catch "error";
        return Response.ok(msg);
    }

    // -- random bytes via std.Io (compiles to WASI random_get) --
    if (std.mem.eql(u8, path, "/stdlib/random")) {
        var bytes: [16]u8 = undefined;
        workers.io().random(&bytes);
        // Verify it's not all zeros (astronomically unlikely for real randomness)
        var all_zero = true;
        for (bytes) |b| {
            if (b != 0) { all_zero = false; break; }
        }
        if (all_zero) return Response.ok("random=FAIL");
        var hex: [32]u8 = undefined;
        for (bytes, 0..) |b, i| {
            hex[i * 2] = "0123456789abcdef"[b >> 4];
            hex[i * 2 + 1] = "0123456789abcdef"[b & 0xf];
        }
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "random={s}", .{hex[0..]}) catch "error";
        return Response.ok(msg);
    }

    return Response.err(.not_found, "unknown stdlib route");
}

// ---------------------------------------------------------------------------
// Filesystem tests — verify WASI path_open/fd_read/fd_write round-trip
// through the shim's node:fs bridge against Cloudflare's virtual FS.
// ---------------------------------------------------------------------------
fn handleFs(path: []const u8) !Response {
    const io = workers.io();
    const Dir = std.Io.Dir;

    // -- /tmp round-trip: write then read, expected to succeed ----------------
    if (std.mem.eql(u8, path, "/fs/tmp-roundtrip")) {
        const payload = "hello from zig wasi via node:fs";
        Dir.cwd().writeFile(io, .{
            .sub_path = "/tmp/houston-spike.txt",
            .data = payload,
        }) catch |err| {
            return fsErrResponse("write", err);
        };

        var buf: [256]u8 = undefined;
        const bytes = Dir.cwd().readFile(io, "/tmp/houston-spike.txt", &buf) catch |err| {
            return fsErrResponse("read", err);
        };
        return Response.ok(bytes);
    }

    // -- /tmp mkdir + nested file + readdir -----------------------------------
    if (std.mem.eql(u8, path, "/fs/tmp-mkdir-list")) {
        Dir.cwd().createDirPath(io, "/tmp/houston-spike-dir") catch |err| {
            return fsErrResponse("mkdir", err);
        };
        Dir.cwd().writeFile(io, .{
            .sub_path = "/tmp/houston-spike-dir/nested.txt",
            .data = "nested-ok",
        }) catch |err| {
            return fsErrResponse("write-nested", err);
        };
        var buf: [256]u8 = undefined;
        const bytes = Dir.cwd().readFile(io, "/tmp/houston-spike-dir/nested.txt", &buf) catch |err| {
            return fsErrResponse("read-nested", err);
        };
        return Response.ok(bytes);
    }

    // -- Write to root (/), a non-/tmp path. Cloudflare's VFS is read-only
    //    outside /tmp, so we expect a clean error, not a crash. --------------
    if (std.mem.eql(u8, path, "/fs/root-write")) {
        Dir.cwd().writeFile(io, .{
            .sub_path = "/houston-spike-root.txt",
            .data = "should-fail",
        }) catch |err| {
            return fsErrResponse("root-write", err);
        };
        return Response.ok("unexpected-success");
    }

    // -- Write to a new top-level dir (also outside /tmp, /bundle, /dev) -----
    if (std.mem.eql(u8, path, "/fs/custom-dir-write")) {
        Dir.cwd().createDirPath(io, "/data") catch |err| {
            // Report the mkdir error — we don't get to writing.
            return fsErrResponse("custom-mkdir", err);
        };
        Dir.cwd().writeFile(io, .{
            .sub_path = "/data/houston-spike.txt",
            .data = "should-fail",
        }) catch |err| {
            return fsErrResponse("custom-write", err);
        };
        return Response.ok("unexpected-success");
    }

    // -- Relative path — resolves against cwd. On WASI cwd == first preopen,
    //    which our shim exposes as "/". So "relative.txt" becomes "/relative.txt"
    //    — also outside the writable area. ------------------------------------
    if (std.mem.eql(u8, path, "/fs/relative-write")) {
        Dir.cwd().writeFile(io, .{
            .sub_path = "relative.txt",
            .data = "should-fail",
        }) catch |err| {
            return fsErrResponse("relative-write", err);
        };
        return Response.ok("unexpected-success");
    }

    // -- Stat /bundle (read-only bundled modules) to confirm reads work ------
    if (std.mem.eql(u8, path, "/fs/bundle-stat")) {
        const stat = Dir.cwd().statFile(io, "/bundle", .{}) catch |err| {
            return fsErrResponse("bundle-stat", err);
        };
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "kind={s} size={d}", .{
            @tagName(stat.kind),
            stat.size,
        }) catch "format-error";
        return Response.ok(msg);
    }

    return Response.err(.not_found, "unknown fs route");
}

fn fsErrResponse(comptime op: []const u8, err: anyerror) Response {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, op ++ "-failed: {s}", .{@errorName(err)}) catch op ++ "-failed";
    return Response.ok(msg);
}

// ---------------------------------------------------------------------------
// WASI environ tests — exercise std.posix.getenv through the shim-backed
// environ_get/environ_sizes_get syscalls (which route to process.env).
// ---------------------------------------------------------------------------
fn handleEnvWasi(path: []const u8) !Response {
    const alloc = std.heap.wasm_allocator;
    const env: std.process.Environ = .{ .block = .global };

    if (std.mem.eql(u8, path, "/env-wasi/getenv")) {
        const val = env.getAlloc(alloc, "GREETING") catch |err| switch (err) {
            error.EnvironmentVariableMissing => return Response.ok("<missing>"),
            else => return err,
        };
        defer alloc.free(val);
        return Response.ok(val);
    }
    if (std.mem.eql(u8, path, "/env-wasi/missing")) {
        const val = env.getAlloc(alloc, "NO_SUCH_VAR") catch |err| switch (err) {
            error.EnvironmentVariableMissing => return Response.ok("<missing>"),
            else => return err,
        };
        defer alloc.free(val);
        return Response.ok(val);
    }
    if (std.mem.eql(u8, path, "/env-wasi/list")) {
        var map = try env.createMap(alloc);
        defer map.deinit();
        var w = std.Io.Writer.Allocating.init(alloc);
        defer w.deinit();
        var it = map.iterator();
        while (it.next()) |e| {
            w.writer.print("{s}={s}\n", .{ e.key_ptr.*, e.value_ptr.* }) catch return error.OutOfMemory;
        }
        return Response.ok(w.written());
    }
    return Response.err(.not_found, "unknown env-wasi route");
}

// ---------------------------------------------------------------------------
// node:tls-backed socket — verify the Socket.connectTls path.  Does an
// HTTP/1.0 GET over TLS to example.com:443.
// ---------------------------------------------------------------------------
fn handleTls(path: []const u8) !Response {
    const alloc = std.heap.wasm_allocator;
    const Socket = workers.Socket;

    if (std.mem.eql(u8, path, "/tls/get-example")) {
        var socket = Socket.connectTls(alloc, "example.com", 443, .{
            .servername = "example.com",
        }) catch |err| {
            return tlsErrResponse("connect", err);
        };
        defer socket.close();

        socket.write("GET / HTTP/1.0\r\nHost: example.com\r\nConnection: close\r\n\r\n");

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(alloc);
        while (try socket.read()) |chunk| {
            try body.appendSlice(alloc, chunk);
            alloc.free(chunk);
            if (body.items.len > 8 * 1024) break;
        }

        const status_line_end = std.mem.indexOfScalar(u8, body.items, '\n') orelse body.items.len;
        const status_line = std.mem.trimEnd(u8, body.items[0..status_line_end], "\r");
        return Response.ok(status_line);
    }

    return Response.err(.not_found, "unknown tls route");
}

fn tlsErrResponse(comptime op: []const u8, err: anyerror) Response {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, op ++ "-failed: {s}", .{@errorName(err)}) catch op ++ "-failed";
    return Response.ok(msg);
}

// ---------------------------------------------------------------------------
// AI handlers
// ---------------------------------------------------------------------------
fn handleAi(_: *Request, env: *Env, path: []const u8) !Response {
    if (std.mem.eql(u8, path, "/ai/text-generation")) {
        return testAiTextGeneration(env);
    }
    if (std.mem.eql(u8, path, "/ai/text-generation-messages")) {
        return testAiTextGenerationMessages(env);
    }
    if (std.mem.eql(u8, path, "/ai/translation")) {
        return testAiTranslation(env);
    }
    if (std.mem.eql(u8, path, "/ai/summarization")) {
        return testAiSummarization(env);
    }
    if (std.mem.eql(u8, path, "/ai/text-classification")) {
        return testAiTextClassification(env);
    }
    if (std.mem.eql(u8, path, "/ai/text-embeddings")) {
        return testAiTextEmbeddings(env);
    }
    if (std.mem.eql(u8, path, "/ai/generic-run")) {
        return testAiGenericRun(env);
    }
    if (std.mem.eql(u8, path, "/ai/stream")) {
        return testAiStream(env);
    }
    if (std.mem.eql(u8, path, "/ai/tool-calling")) {
        return testAiToolCalling(env);
    }
    if (std.mem.eql(u8, path, "/ai/json-mode")) {
        return testAiJsonMode(env);
    }
    if (std.mem.eql(u8, path, "/ai/vision")) {
        return testAiVision(env);
    }
    if (std.mem.eql(u8, path, "/ai/gateway-options")) {
        return testAiGatewayOptions(env);
    }
    if (std.mem.eql(u8, path, "/ai/models")) {
        return testAiModels(env);
    }
    if (std.mem.eql(u8, path, "/ai/ws-stt")) {
        return testAiWebSocketStt(env);
    }
    if (std.mem.eql(u8, path, "/ai/ws-tts")) {
        return testAiWebSocketTts(env);
    }
    if (std.mem.eql(u8, path, "/ai/tts-batch")) {
        return testAiTtsBatch(env);
    }
    if (std.mem.eql(u8, path, "/ai/text-to-image")) {
        return testAiTextToImage(env);
    }
    if (std.mem.eql(u8, path, "/ai/ws-raw")) {
        return testAiWebSocketRaw(env);
    }
    return Response.err(.not_found, "unknown ai route");
}

fn testAiTextGeneration(env: *Env) !Response {
    const binding = try env.ai("AI");
    const result = try binding.textGeneration("@cf/meta/llama-3.1-8b-instruct", .{
        .prompt = "Return only the word 'hello'",
        .max_tokens = 10,
    });
    if (result.response == null) return Response.err(.internal_server_error, "FAIL: response was null");
    if (result.response.?.len == 0) return Response.err(.internal_server_error, "FAIL: response was empty");
    return Response.ok("PASS");
}

fn testAiTextGenerationMessages(env: *Env) !Response {
    const binding = try env.ai("AI");
    const messages = [_]Ai.Message{
        .{ .role = "system", .content = "You are a helpful assistant. Be very brief." },
        .{ .role = "user", .content = "Say hello" },
    };
    const result = try binding.textGeneration("@cf/meta/llama-3.1-8b-instruct", .{
        .messages = &messages,
        .max_tokens = 10,
    });
    if (result.response == null) return Response.err(.internal_server_error, "FAIL: response was null");
    return Response.ok("PASS");
}

fn testAiTranslation(env: *Env) !Response {
    const binding = try env.ai("AI");
    const result = try binding.translation("@cf/meta/m2m100-1.2b", .{
        .text = "Hello world",
        .target_lang = "es",
        .source_lang = "en",
    });
    if (result.translated_text == null) return Response.err(.internal_server_error, "FAIL: translated_text was null");
    return Response.ok("PASS");
}

fn testAiSummarization(env: *Env) !Response {
    const binding = try env.ai("AI");
    const result = try binding.summarization("@cf/facebook/bart-large-cnn", .{
        .input_text = "Cloudflare Workers provides a serverless execution environment that allows you to create new applications or augment existing ones without configuring or maintaining infrastructure. Workers runs on the Cloudflare global network in over 300 cities around the world.",
        .max_length = 50,
    });
    if (result.summary == null) return Response.err(.internal_server_error, "FAIL: summary was null");
    return Response.ok("PASS");
}

fn testAiTextClassification(env: *Env) !Response {
    const binding = try env.ai("AI");
    const result = try binding.textClassification("@cf/huggingface/distilbert-sst-2-int8", .{
        .text = "This is wonderful!",
    });
    if (result.len == 0) return Response.err(.internal_server_error, "FAIL: empty result");
    return Response.ok("PASS");
}

fn testAiTextEmbeddings(env: *Env) !Response {
    const binding = try env.ai("AI");
    const texts = [_][]const u8{ "hello world", "goodbye world" };
    const result = try binding.textEmbeddings("@cf/baai/bge-base-en-v1.5", .{
        .text = &texts,
    });
    if (result.shape.len == 0) return Response.err(.internal_server_error, "FAIL: empty shape");
    if (result.data.len == 0) return Response.err(.internal_server_error, "FAIL: empty data");
    return Response.ok("PASS");
}

fn testAiGenericRun(env: *Env) !Response {
    const binding = try env.ai("AI");
    const result = try binding.run(
        "@cf/meta/llama-3.1-8b-instruct",
        "{\"prompt\":\"Say hi\",\"max_tokens\":5}",
    );
    if (result.len == 0) return Response.err(.internal_server_error, "FAIL: empty result");
    return Response.ok("PASS");
}

fn testAiStream(env: *Env) !Response {
    const binding = try env.ai("AI");

    // Start a streaming response to the client.
    var stream = StreamingResponse.start(.{});
    stream.setHeader("content-type", "text/event-stream");

    // Stream text generation chunks from the AI model.
    var reader = try binding.textGenerationStream("@cf/meta/llama-3.1-8b-instruct", .{
        .prompt = "Count from 1 to 5",
        .max_tokens = 30,
    });
    var chunk_count: u32 = 0;
    while (try reader.next()) |chunk| {
        stream.write(chunk);
        chunk_count += 1;
    }
    stream.close();

    // If we got here with chunks, streaming worked.
    if (chunk_count == 0) {
        // Streaming path was taken but no chunks — still return the stream response.
    }
    return stream.response();
}

fn testAiToolCalling(env: *Env) !Response {
    const binding = try env.ai("AI");
    const tools = [_]Ai.ToolDefinition{
        .{
            .function = .{
                .name = "get_weather",
                .description = "Get the current weather for a location",
                .parameters = "{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\"}},\"required\":[\"location\"]}",
            },
        },
    };
    const messages = [_]Ai.Message{
        .{ .role = "user", .content = "What's the weather in San Francisco?" },
    };
    const result = try binding.textGeneration("@cf/meta/llama-3.1-8b-instruct", .{
        .messages = &messages,
        .tools = &tools,
        .max_tokens = 100,
    });
    // Model may return tool_calls or a text response — either is valid.
    if (result.response == null and result.tool_calls == null)
        return Response.err(.internal_server_error, "FAIL: both response and tool_calls null");
    return Response.ok("PASS");
}

fn testAiJsonMode(env: *Env) !Response {
    const binding = try env.ai("AI");
    const messages = [_]Ai.Message{
        .{ .role = "user", .content = "Return a JSON object with a greeting field." },
    };
    const result = try binding.textGeneration("@cf/meta/llama-3.1-8b-instruct", .{
        .messages = &messages,
        .response_format = .{ .type = "json_schema", .json_schema = "{\"name\":\"greeting\",\"schema\":{\"type\":\"object\",\"properties\":{\"greeting\":{\"type\":\"string\"}},\"required\":[\"greeting\"]}}" },
        .max_tokens = 50,
    });
    if (result.response == null) return Response.err(.internal_server_error, "FAIL: response was null");
    return Response.ok("PASS");
}

fn testAiVision(env: *Env) !Response {
    const binding = try env.ai("AI");
    // 1x1 red PNG as a data URI (avoids external URL restrictions).
    const red_pixel = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==";
    const parts = [_]Ai.ContentPart{
        .{ .type = "text", .text = "What color is this image? Reply with just the color name." },
        .{ .type = "image_url", .image_url = .{ .url = red_pixel } },
    };
    const messages = [_]Ai.Message{
        .{ .role = "user", .content_parts = &parts },
    };
    const result = try binding.textGeneration("@cf/google/gemma-4-26b-a4b-it", .{
        .messages = &messages,
        .max_tokens = 200,
    });
    if (result.response == null) return Response.err(.internal_server_error, "FAIL: response was null");
    return Response.ok("PASS");
}

fn testAiGatewayOptions(env: *Env) !Response {
    const binding = try env.ai("AI");
    const result = try binding.textGenerationWithOptions(
        "@cf/meta/llama-3.1-8b-instruct",
        .{
            .prompt = "Say hello",
            .max_tokens = 10,
        },
        .{
            .gateway = .{
                .id = "my-gateway",
                .skip_cache = true,
            },
        },
    );
    if (result.response == null) return Response.err(.internal_server_error, "FAIL: response was null");
    return Response.ok("PASS");
}

fn testAiModels(env: *Env) !Response {
    const binding = try env.ai("AI");
    const result = try binding.models();
    if (result.len == 0) return Response.err(.internal_server_error, "FAIL: empty models response");
    return Response.ok("PASS");
}

fn testAiWebSocketStt(env: *Env) !Response {
    const binding = try env.ai("AI");
    // Returns a 101 WebSocket upgrade response — the client sends audio
    // binary frames and receives JSON transcription events.
    return try binding.speechToTextWebSocket("@cf/deepgram/nova-3", .{
        .encoding = "linear16",
        .sample_rate = "16000",
        .interim_results = true,
    });
}

fn testAiWebSocketTts(env: *Env) !Response {
    const binding = try env.ai("AI");
    // Returns a 101 WebSocket upgrade response — the client sends JSON
    // control messages (Speak, Flush, Close) and receives binary PCM audio.
    return try binding.textToSpeechWebSocket("@cf/deepgram/aura-1");
}

fn testAiWebSocketRaw(env: *Env) !Response {
    const binding = try env.ai("AI");
    // Generic runWebSocket with raw JSON config — for flux (turn-aware STT).
    return try binding.runWebSocket(
        "@cf/deepgram/flux",
        "{\"encoding\":\"linear16\",\"sample_rate\":\"16000\"}",
    );
}

fn testAiTtsBatch(env: *Env) !Response {
    const binding = try env.ai("AI");
    // Batch TTS — returns raw audio bytes.
    const audio = try binding.textToSpeech("@cf/myshell-ai/melotts", .{
        .prompt = "Hello from workers zig!",
    });
    if (audio.len == 0) return Response.err(.internal_server_error, "FAIL: empty audio");
    var resp = Response.new();
    resp.setHeader("content-type", "audio/wav");
    resp.setBody(audio);
    return resp;
}

fn testAiTextToImage(env: *Env) !Response {
    const binding = try env.ai("AI");
    const image = try binding.textToImage("@cf/black-forest-labs/flux-2-dev", .{
        .prompt = "a red circle on a white background",
        .num_steps = 20,
        .multipart = true,
    });
    if (image.len == 0) return Response.err(.internal_server_error, "FAIL: empty image");
    var resp = Response.new();
    resp.setHeader("content-type", "image/jpeg");
    resp.setBody(image);
    return resp;
}

// ---------------------------------------------------------------------------
// Tail handler (receives trace data from other workers)
// ---------------------------------------------------------------------------
pub fn tail(events: []const Tail.TraceItem, env: *Env, _: *Context) !void {
    workers.log("tail: received {d} trace items", .{events.len});

    const kv = try env.kv("TEST_KV");

    var buf: [1024]u8 = undefined;
    var pos: usize = 0;

    for (events, 0..) |item, i| {
        const script = item.script_name orelse "unknown";
        const outcome_str = item.outcome;
        const log_count = item.logs.len;
        const exc_count = item.exceptions.len;

        const entry = std.fmt.bufPrint(buf[pos..], "trace[{d}]:script={s},outcome={s},logs={d},exceptions={d};", .{
            i, script, outcome_str, log_count, exc_count,
        }) catch break;
        pos += entry.len;

        // Log event type if present
        if (item.event) |ev| {
            const event_type: []const u8 = switch (ev) {
                .fetch => "fetch",
                .scheduled => "scheduled",
                .alarm => "alarm",
                .queue => "queue",
                .email => "email",
                .tail => "tail",
                .custom => "custom",
                .unknown => "unknown",
            };
            workers.log("  trace[{d}] event_type={s}", .{ i, event_type });
        }
    }

    kv.put("tail-summary", buf[0..pos]);

    // Store count
    var count_buf: [32]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{events.len}) catch "0";
    kv.put("tail-count", count_str);
}

// ---------------------------------------------------------------------------
// Queue handler (consumer)
// ---------------------------------------------------------------------------
pub fn queue(batch: *Queue.MessageBatch, env: *Env, _: *Context) !void {
    const queue_name = try batch.queueName();
    const count = batch.len();

    workers.log("queue: name={s} count={d}", .{ queue_name, count });

    // Store message details in KV so fetch-based tests can verify.
    const kv = try env.kv("TEST_KV");

    var buf: [1024]u8 = undefined;
    var iter = batch.iterator();
    var i: u32 = 0;
    while (iter.next()) |msg| {
        const msg_body = try msg.body();
        const msg_id = try msg.id();
        const attempts_val = msg.attempts();

        // Store each message body under "queue-msg-N"
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "queue-msg-{d}", .{i}) catch "queue-msg-?";
        kv.put(key, msg_body);

        workers.log("  msg[{d}]: id={s} body={s} attempts={d}", .{ i, msg_id, msg_body, attempts_val });
        i += 1;
    }

    // Store summary
    const summary = std.fmt.bufPrint(&buf, "queue={s} count={d}", .{ queue_name, count }) catch "error";
    kv.put("queue-summary", summary);

    batch.ackAll();
}

// ---------------------------------------------------------------------------
// Queue test handlers (producer + verify)
// ---------------------------------------------------------------------------
fn handleQueue(_: *Request, env: *Env, path: []const u8) !Response {
    if (std.mem.eql(u8, path, "/queue/send")) {
        const q = try env.queue("TEST_QUEUE");
        q.send("{\"hello\":\"world\"}", .{});
        return Response.ok("sent");
    }

    if (std.mem.eql(u8, path, "/queue/send-delay")) {
        const q = try env.queue("TEST_QUEUE");
        q.send("{\"delayed\":true}", .{ .delay_seconds = 5 });
        return Response.ok("sent-delayed");
    }

    if (std.mem.eql(u8, path, "/queue/send-text")) {
        const q = try env.queue("TEST_QUEUE");
        q.send("\"plain text message\"", .{ .content_type = .text });
        return Response.ok("sent-text");
    }

    if (std.mem.eql(u8, path, "/queue/send-batch")) {
        const q = try env.queue("TEST_QUEUE");
        const messages = [_]Queue.SendRequest{
            .{ .body = "{\"item\":1}" },
            .{ .body = "{\"item\":2}" },
            .{ .body = "{\"item\":3}" },
        };
        try q.sendBatch(&messages, .{});
        return Response.ok("batch-sent");
    }

    if (std.mem.eql(u8, path, "/queue/verify")) {
        const kv = try env.kv("TEST_KV");
        const summary = try kv.getText("queue-summary");
        if (summary) |s| {
            return Response.ok(s);
        }
        return Response.err(.not_found, "no queue summary yet");
    }

    if (std.mem.eql(u8, path, "/queue/verify-msg")) {
        const kv = try env.kv("TEST_KV");
        const msg = try kv.getText("queue-msg-0");
        if (msg) |m| {
            return Response.ok(m);
        }
        return Response.err(.not_found, "no queue message yet");
    }

    if (std.mem.eql(u8, path, "/queue/clear")) {
        const kv = try env.kv("TEST_KV");
        kv.delete("queue-summary");
        kv.delete("queue-msg-0");
        kv.delete("queue-msg-1");
        kv.delete("queue-msg-2");
        return Response.ok("cleared");
    }

    return Response.err(.not_found, "unknown queue route");
}

// ---------------------------------------------------------------------------
// Workflow handlers (binding side — create/get/status)
// ---------------------------------------------------------------------------
fn handleWorkflow(_: *Request, env: *Env, path: []const u8) !Response {
    const wf = try env.workflow("MY_WORKFLOW");

    if (std.mem.eql(u8, path, "/workflow/create")) {
        var instance = try wf.create(.{ .input = "test-data" }, .{
            .id = "test-instance-1",
        });
        const id_str = try instance.id();
        return Response.ok(id_str);
    }

    if (std.mem.eql(u8, path, "/workflow/create-auto-id")) {
        var instance = try wf.create(.{ .auto = true }, .{});
        const id_str = try instance.id();
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "id={s}", .{id_str}) catch "error";
        return Response.ok(msg);
    }

    if (std.mem.eql(u8, path, "/workflow/get")) {
        var instance = try wf.get("test-instance-1");
        const id_str = try instance.id();
        return Response.ok(id_str);
    }

    if (std.mem.eql(u8, path, "/workflow/status")) {
        var instance = try wf.get("test-instance-1");
        const s = try instance.status();
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "status={s}", .{@tagName(s.status)}) catch "error";
        return Response.ok(msg);
    }

    if (std.mem.eql(u8, path, "/workflow/pause")) {
        var instance = try wf.get("test-instance-1");
        instance.pause();
        return Response.ok("paused");
    }

    if (std.mem.eql(u8, path, "/workflow/resume")) {
        var instance = try wf.get("test-instance-1");
        instance.@"resume"();
        return Response.ok("resumed");
    }

    if (std.mem.eql(u8, path, "/workflow/terminate")) {
        var instance = try wf.get("test-instance-1");
        instance.terminate();
        return Response.ok("terminated");
    }

    return Response.err(.not_found, "unknown workflow route");
}

// ---------------------------------------------------------------------------
// Tail verification handlers
// ---------------------------------------------------------------------------
fn handleTailVerify(_: *Request, env: *Env, path: []const u8) !Response {
    const kv = try env.kv("TEST_KV");

    if (std.mem.eql(u8, path, "/tail/verify")) {
        const summary = try kv.getText("tail-summary");
        if (summary) |s| {
            return Response.ok(s);
        }
        return Response.err(.not_found, "no tail data yet");
    }

    if (std.mem.eql(u8, path, "/tail/count")) {
        const count = try kv.getText("tail-count");
        if (count) |c| {
            return Response.ok(c);
        }
        return Response.ok("0");
    }

    if (std.mem.eql(u8, path, "/tail/clear")) {
        kv.delete("tail-summary");
        kv.delete("tail-count");
        return Response.ok("cleared");
    }

    return Response.err(.not_found, "unknown tail route");
}

// ---------------------------------------------------------------------------
// Crypto tests
// ---------------------------------------------------------------------------
fn handleCrypto(_: *Request, _: *Env, path: []const u8) !Response {
    const allocator = std.heap.wasm_allocator;

    if (std.mem.eql(u8, path, "/crypto/digest-sha256")) {
        const hash = try Crypto.digest(allocator, .sha256, "hello world");
        const hex = try Crypto.toHex(allocator, hash);
        return Response.ok(hex);
    }

    if (std.mem.eql(u8, path, "/crypto/digest-sha1")) {
        const hash = try Crypto.digest(allocator, .sha1, "hello world");
        const hex = try Crypto.toHex(allocator, hash);
        return Response.ok(hex);
    }

    if (std.mem.eql(u8, path, "/crypto/digest-md5")) {
        const hash = try Crypto.digest(allocator, .md5, "hello world");
        const hex = try Crypto.toHex(allocator, hash);
        return Response.ok(hex);
    }

    if (std.mem.eql(u8, path, "/crypto/hmac")) {
        const sig = try Crypto.hmac(allocator, .sha256, "secret-key", "hello world");
        const hex = try Crypto.toHex(allocator, sig);
        return Response.ok(hex);
    }

    if (std.mem.eql(u8, path, "/crypto/hmac-verify")) {
        const sig = try Crypto.hmac(allocator, .sha256, "secret-key", "hello world");
        const valid = Crypto.hmacVerify(.sha256, "secret-key", sig, "hello world");
        const invalid = Crypto.hmacVerify(.sha256, "wrong-key", sig, "hello world");
        if (valid and !invalid) {
            return Response.ok("verify-ok");
        }
        return Response.err(.internal_server_error, "verify-failed");
    }

    if (std.mem.eql(u8, path, "/crypto/timing-safe")) {
        const a = "same-content";
        const b = "same-content";
        const c = "diff-content";
        const eq = Crypto.timingSafeEqual(a, b);
        const neq = Crypto.timingSafeEqual(a, c);
        if (eq and !neq) {
            return Response.ok("timing-ok");
        }
        return Response.err(.internal_server_error, "timing-failed");
    }

    return Response.err(.not_found, "unknown crypto test");
}

// ---------------------------------------------------------------------------
// FormData tests
// ---------------------------------------------------------------------------
fn handleFormData(request: *Request, _: *Env, path: []const u8) !Response {
    const allocator = std.heap.wasm_allocator;

    if (std.mem.eql(u8, path, "/formdata/parse")) {
        var form = FormData.fromRequest(allocator, request.handle);
        const name = try form.get("name") orelse "missing";
        const email = try form.get("email") orelse "missing";
        var buf: [256]u8 = undefined;
        const result = std.fmt.bufPrint(&buf, "name={s},email={s}", .{ name, email }) catch "format-error";
        return Response.ok(result);
    }

    if (std.mem.eql(u8, path, "/formdata/has")) {
        var form = FormData.fromRequest(allocator, request.handle);
        const has_name = form.has("name");
        const has_missing = form.has("nonexistent");
        if (has_name and !has_missing) {
            return Response.ok("has-ok");
        }
        return Response.err(.internal_server_error, "has-failed");
    }

    if (std.mem.eql(u8, path, "/formdata/build")) {
        // Build a FormData, check it has the right entries
        var form = FormData.init(allocator);
        form.append("key1", "value1");
        form.append("key2", "value2");
        const count = form.len();
        const has1 = form.has("key1");
        const has2 = form.has("key2");
        if (count == 2 and has1 and has2) {
            return Response.ok("build-ok");
        }
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "build-fail count={d} has1={} has2={}", .{ count, has1, has2 }) catch "err";
        return Response.err(.internal_server_error, msg);
    }

    return Response.err(.not_found, "unknown formdata test");
}

// ---------------------------------------------------------------------------
// HTMLRewriter tests
// ---------------------------------------------------------------------------
fn handleRewriter(_: *Request, _: *Env, path: []const u8) !Response {
    const allocator = std.heap.wasm_allocator;

    if (std.mem.eql(u8, path, "/rewriter/set-attr")) {
        // Create an HTML response, then transform it
        const html_resp = Response.html("<html><body><a href=\"/test\">link</a></body></html>");
        var rw = HTMLRewriter.init(allocator);
        try rw.setAttribute("a", "target", "_blank");
        const h = rw.transform(html_resp.handle);
        // Return the transformed response — its body is a native stream
        return .{ .handle = h };
    }

    if (std.mem.eql(u8, path, "/rewriter/remove")) {
        const html_resp = Response.html("<html><body><script>evil()</script><p>content</p></body></html>");
        var rw = HTMLRewriter.init(allocator);
        try rw.remove("script");
        const h = rw.transform(html_resp.handle);
        return .{ .handle = h };
    }

    if (std.mem.eql(u8, path, "/rewriter/append")) {
        const html_resp = Response.html("<html><body><div id=\"main\">hello</div></body></html>");
        var rw = HTMLRewriter.init(allocator);
        try rw.append("div#main", .{ .content = " world", .html = false });
        const h = rw.transform(html_resp.handle);
        return .{ .handle = h };
    }

    if (std.mem.eql(u8, path, "/rewriter/replace")) {
        const html_resp = Response.html("<html><body><span class=\"old\">old text</span></body></html>");
        var rw = HTMLRewriter.init(allocator);
        try rw.replace("span.old", .{ .content = "<strong>new text</strong>", .html = true });
        const h = rw.transform(html_resp.handle);
        return .{ .handle = h };
    }

    return Response.err(.not_found, "unknown rewriter test");
}

// ---------------------------------------------------------------------------
// Router tests — exercises each HTTP verb, path params, and middleware
// ---------------------------------------------------------------------------

fn withRequestId(comptime handler: Router.Handler) Router.Handler {
    return struct {
        fn wrapped(req: *Request, env: *Env, ctx: *Context, params: *Router.Params) !Response {
            var resp = try handler(req, env, ctx, params);
            resp.setHeader("x-request-id", "test-123");
            return resp;
        }
    }.wrapped;
}

fn handleRouter(request: *Request, env: *Env, ctx: *Context) !Response {
    return Router.serve(request, env, ctx, &.{
        Router.get("/router/get", handleRouterGet),
        Router.post("/router/post", handleRouterPost),
        Router.put("/router/put", handleRouterPut),
        Router.delete("/router/delete", handleRouterDelete),
        Router.patch("/router/patch", handleRouterPatch),
        Router.head("/router/head", handleRouterHead),
        Router.all("/router/any", handleRouterAny),
        Router.get("/router/params/:name/:action", handleRouterParams),
        Router.get("/router/wildcard/*", handleRouterWildcard),
        Router.get("/router/middleware", withRequestId(handleRouterMiddleware)),
    }) orelse Response.err(.not_found, "no matching router route");
}

fn handleRouterGet(_: *Request, _: *Env, _: *Context, _: *Router.Params) !Response {
    return Response.ok("method=GET");
}

fn handleRouterPost(req: *Request, _: *Env, _: *Context, _: *Router.Params) !Response {
    const body = (try req.body()) orelse "";
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "method=POST body={s}", .{body}) catch "error";
    return Response.ok(msg);
}

fn handleRouterPut(req: *Request, _: *Env, _: *Context, _: *Router.Params) !Response {
    const body = (try req.body()) orelse "";
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "method=PUT body={s}", .{body}) catch "error";
    return Response.ok(msg);
}

fn handleRouterDelete(_: *Request, _: *Env, _: *Context, _: *Router.Params) !Response {
    return Response.ok("method=DELETE");
}

fn handleRouterPatch(req: *Request, _: *Env, _: *Context, _: *Router.Params) !Response {
    const body = (try req.body()) orelse "";
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "method=PATCH body={s}", .{body}) catch "error";
    return Response.ok(msg);
}

fn handleRouterHead(_: *Request, _: *Env, _: *Context, _: *Router.Params) !Response {
    var resp = Response.ok("");
    resp.setHeader("x-head-test", "yes");
    return resp;
}

fn handleRouterAny(req: *Request, _: *Env, _: *Context, _: *Router.Params) !Response {
    const method = req.method();
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "method={s}", .{@tagName(method)}) catch "error";
    return Response.ok(msg);
}

fn handleRouterParams(_: *Request, _: *Env, _: *Context, params: *Router.Params) !Response {
    const name = params.get("name") orelse "?";
    const action = params.get("action") orelse "?";
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "name={s} action={s}", .{ name, action }) catch "error";
    return Response.ok(msg);
}

fn handleRouterWildcard(_: *Request, _: *Env, _: *Context, _: *Router.Params) !Response {
    return Response.ok("wildcard-matched");
}

fn handleRouterMiddleware(_: *Request, _: *Env, _: *Context, _: *Router.Params) !Response {
    return Response.ok("middleware-ok");
}

// ---------------------------------------------------------------------------
// Artifacts handlers
// ---------------------------------------------------------------------------
fn handleArtifacts(_: *Request, env: *Env, path: []const u8) !Response {
    // Artifacts may not be available in local dev — handle gracefully.
    const arts = env.artifacts("ARTIFACTS") catch {
        return Response.ok("artifacts-not-available");
    };

    if (std.mem.eql(u8, path, "/artifacts/create")) {
        const result = arts.create("test-repo", .{
            .description = "integration test repo",
        }) catch |e| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "create-error: {s}", .{@errorName(e)}) catch "error";
            return Response.ok(msg);
        };
        // Verify we got a name and remote back
        if (result.remote.len > 0 and result.name.len > 0) {
            return Response.ok("created");
        }
        return Response.ok("create-empty");
    }

    if (std.mem.eql(u8, path, "/artifacts/get")) {
        if (arts.get("test-repo") catch null) |repo| {
            const info_json = repo.info() catch {
                return Response.ok("info-error");
            };
            if (info_json) |info| {
                // Just check it's valid JSON containing "remote"
                if (std.mem.indexOf(u8, info, "remote") != null) {
                    return Response.ok("info-ok");
                }
            }
            return Response.ok("info-empty");
        }
        return Response.ok("not-found");
    }

    if (std.mem.eql(u8, path, "/artifacts/token")) {
        if (arts.get("test-repo") catch null) |repo| {
            const tok_json = repo.createToken(.read, 3600) catch {
                return Response.ok("token-error");
            };
            if (std.mem.indexOf(u8, tok_json, "plaintext") != null or std.mem.indexOf(u8, tok_json, "scope") != null) {
                return Response.ok("token-ok");
            }
            return Response.ok("token-unexpected");
        }
        return Response.ok("not-found");
    }

    if (std.mem.eql(u8, path, "/artifacts/list")) {
        const list_json = arts.list(.{ .limit = 10 }) catch {
            return Response.ok("list-error");
        };
        if (std.mem.indexOf(u8, list_json, "repos") != null) {
            return Response.ok("list-ok");
        }
        return Response.ok("list-unexpected");
    }

    if (std.mem.eql(u8, path, "/artifacts/fork")) {
        if (arts.get("test-repo") catch null) |repo| {
            const fork_json = repo.fork("test-repo-fork", .{
                .description = "fork for testing",
                .default_branch_only = true,
            }) catch {
                return Response.ok("fork-error");
            };
            if (std.mem.indexOf(u8, fork_json, "remote") != null) {
                return Response.ok("fork-ok");
            }
            return Response.ok("fork-unexpected");
        }
        return Response.ok("not-found");
    }

    if (std.mem.eql(u8, path, "/artifacts/import")) {
        // Import a public GitHub repo via the REST API.
        const result = arts.import(.{
            .url = "https://github.com/nilslice/workers-zig",
            .branch = "main",
            .depth = 1,
        }, .{
            .name = "workers-zig-import",
        }) catch {
            return Response.ok("import-error");
        };
        // Verify the response contains a remote URL (a successful import)
        if (result.remote.len > 0) {
            // Also verify the repo is accessible via the binding
            if (arts.get("workers-zig-import") catch null) |repo| {
                const info_json = repo.info() catch {
                    return Response.ok("import-ok-no-info");
                };
                if (info_json) |info| {
                    if (std.mem.indexOf(u8, info, "workers-zig-import") != null) {
                        return Response.ok("import-ok");
                    }
                }
                return Response.ok("import-ok-no-name");
            }
            return Response.ok("import-ok-not-found");
        }
        return Response.ok("import-unexpected");
    }

    if (std.mem.eql(u8, path, "/artifacts/cleanup")) {
        // Clean up test repos
        _ = arts.delete("test-repo-fork");
        _ = arts.delete("test-repo");
        _ = arts.delete("workers-zig-import");
        return Response.ok("cleaned");
    }

    return Response.err(.not_found, "unknown artifacts test");
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
fn extractPath(url_str: []const u8) []const u8 {
    // Skip past "http(s)://host"
    var start: usize = 0;
    if (std.mem.indexOf(u8, url_str, "://")) |i| {
        start = i + 3;
        // Skip past host
        if (std.mem.indexOfPos(u8, url_str, start, "/")) |j| {
            return url_str[j..];
        }
    }
    return "/";
}
