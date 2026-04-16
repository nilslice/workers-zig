const std = @import("std");
const workers = @import("workers-zig");
const router = workers.Router;

// ---------------------------------------------------------------------------
// Durable Object: Counter
// ---------------------------------------------------------------------------
pub const Counter = struct {
    state: workers.DurableObject.State,
    env: workers.Env,

    pub fn fetch(self: *Counter, request: *workers.Request) !workers.Response {
        const url = try request.url();
        const path = router.extractPath(url);
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
            return workers.Response.ok(num_str);
        }

        if (std.mem.eql(u8, path, "/get")) {
            const current = try storage.get("count");
            return workers.Response.ok(current orelse "0");
        }

        if (std.mem.eql(u8, path, "/reset")) {
            storage.deleteAll();
            return workers.Response.ok("reset");
        }

        return workers.Response.err(.not_found, "unknown DO route");
    }

    pub fn alarm(self: *Counter) !void {
        var storage = self.state.storage();
        storage.put("alarm-fired", "true");
    }
};

// ---------------------------------------------------------------------------
// Main fetch handler — proxies to the DO
// ---------------------------------------------------------------------------
pub fn fetch(request: *workers.Request, env: *workers.Env, _: *workers.Context) !workers.Response {
    return router.serve(request, env, &.{
        router.get("/", handleIndex),
        router.get("/counter/:action", handleCounter),
        router.post("/counter/:action", handleCounter),
    }) orelse workers.Response.err(.not_found, "Not Found");
}

fn handleIndex(_: *workers.Request, _: *workers.Env, _: *router.Params) !workers.Response {
    return workers.Response.ok("Durable Object Counter example");
}

fn handleCounter(_: *workers.Request, env: *workers.Env, params: *router.Params) !workers.Response {
    const action = params.get("action") orelse "get";
    const ns = try env.durableObject("COUNTER");
    const id = ns.idFromName("main");
    const stub = ns.get(id);

    var url_buf: [128]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://do/{s}", .{action}) catch
        return workers.Response.err(.internal_server_error, "url too long");

    var resp = try stub.fetch(url, .{});
    defer resp.deinit();
    return workers.Response.ok(try resp.text());
}
