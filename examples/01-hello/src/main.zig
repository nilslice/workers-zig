const std = @import("std");
const workers = @import("workers-zig");
const Request = workers.Request;
const Response = workers.Response;
const Env = workers.Env;
const Context = workers.Context;
const Router = workers.Router;

pub fn fetch(request: *Request, env: *Env, ctx: *Context) !Response {
    return Router.serve(request, env, ctx, &.{
        Router.get("/", handleIndex),
        Router.get("/greet/:name", handleGreet),
        Router.post("/echo", handleEcho),
    }) orelse Response.err(.not_found, "Not Found");
}

fn handleIndex(_: *Request, env: *Env, _: *Context, _: *Router.Params) !Response {
    const greeting = (try env.get("GREETING")) orelse "Hello from Zig on Cloudflare Workers!";
    return Response.ok(greeting);
}

fn handleGreet(_: *Request, _: *Env, _: *Context, params: *Router.Params) !Response {
    const name = params.get("name") orelse "world";
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Hello, {s}!", .{name}) catch "Hello!";
    return Response.ok(msg);
}

fn handleEcho(request: *Request, _: *Env, _: *Context, _: *Router.Params) !Response {
    const body = (try request.body()) orelse "";
    return Response.ok(body);
}
