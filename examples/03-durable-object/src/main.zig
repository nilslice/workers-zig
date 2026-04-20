const std = @import("std");
const workers = @import("workers-zig");
const Request = workers.Request;
const Response = workers.Response;
const Env = workers.Env;
const Context = workers.Context;
const Router = workers.Router;
const DurableObject = workers.DurableObject;

// ---------------------------------------------------------------------------
// Durable Object: Counter
// ---------------------------------------------------------------------------
pub const Counter = struct {
    state: DurableObject.State,
    env: Env,

    pub fn fetch(self: *Counter, request: *Request) !Response {
        const url = try request.url();
        const path = Router.extractPath(url);
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

        if (std.mem.eql(u8, path, "/reset")) {
            storage.deleteAll();
            return Response.ok("reset");
        }

        return Response.err(.not_found, "unknown DO route");
    }

    pub fn alarm(self: *Counter) !void {
        var storage = self.state.storage();
        storage.put("alarm-fired", "true");
    }
};

// ---------------------------------------------------------------------------
// Main fetch handler — proxies to the DO
// ---------------------------------------------------------------------------
pub fn fetch(request: *Request, env: *Env, ctx: *Context) !Response {
    return Router.serve(request, env, ctx, &.{
        Router.get("/", handleIndex),
        Router.get("/counter/:action", handleCounter),
        Router.post("/counter/:action", handleCounter),
    }) orelse Response.err(.not_found, "Not Found");
}

fn handleIndex(_: *Request, _: *Env, _: *Context, _: *Router.Params) !Response {
    return Response.ok("Durable Object Counter example");
}

fn handleCounter(_: *Request, env: *Env, _: *Context, params: *Router.Params) !Response {
    const action = params.get("action") orelse "get";
    const ns = try env.durableObject("COUNTER");
    const id = ns.idFromName("main");
    const stub = ns.get(id);

    var url_buf: [128]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://do/{s}", .{action}) catch
        return Response.err(.internal_server_error, "url too long");

    var resp = try stub.fetch(url, .{});
    defer resp.deinit();
    return Response.ok(try resp.text());
}
