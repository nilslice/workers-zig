const workers = @import("workers-zig");
const router = workers.Router;

pub fn fetch(request: *workers.Request, env: *workers.Env, _: *workers.Context) !workers.Response {
    return router.serve(request, env, &.{
        router.get("/", handleIndex),
        router.get("/greet/:name", handleGreet),
        router.post("/echo", handleEcho),
    }) orelse workers.Response.err(.not_found, "Not Found");
}

fn handleIndex(_: *workers.Request, env: *workers.Env, _: *router.Params) !workers.Response {
    const greeting = (try env.get("GREETING")) orelse "Hello from Zig on Cloudflare Workers!";
    return workers.Response.ok(greeting);
}

fn handleGreet(_: *workers.Request, _: *workers.Env, params: *router.Params) !workers.Response {
    const name = params.get("name") orelse "world";
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Hello, {s}!", .{name}) catch "Hello!";
    return workers.Response.ok(msg);
}

fn handleEcho(request: *workers.Request, _: *workers.Env, _: *router.Params) !workers.Response {
    const body = (try request.body()) orelse "";
    return workers.Response.ok(body);
}

const std = @import("std");
