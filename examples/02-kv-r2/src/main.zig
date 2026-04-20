const std = @import("std");
const workers = @import("workers-zig");
const Request = workers.Request;
const Response = workers.Response;
const Env = workers.Env;
const Context = workers.Context;
const Router = workers.Router;

/// KV + R2 example — no router, bare path matching.
pub fn fetch(request: *Request, env: *Env, _: *Context) !Response {
    const url = try request.url();
    const path = Router.extractPath(url);

    // -- KV --
    if (std.mem.eql(u8, path, "/kv/put")) {
        const body = (try request.body()) orelse return Response.err(.bad_request, "missing body");
        const kv = try env.kv("STORE");
        kv.put("my-key", body);
        return Response.ok("stored");
    }

    if (std.mem.eql(u8, path, "/kv/get")) {
        const kv = try env.kv("STORE");
        const value = try kv.getText("my-key");
        return Response.ok(value orelse "not found");
    }

    if (std.mem.eql(u8, path, "/kv/list")) {
        const kv = try env.kv("STORE");
        const result = try kv.list(.{});
        return Response.json(result);
    }

    // -- R2 --
    if (std.mem.eql(u8, path, "/r2/put")) {
        const body = (try request.body()) orelse return Response.err(.bad_request, "missing body");
        const bucket = try env.r2("BUCKET");
        _ = try bucket.put("my-object", body, .{ .content_type = "text/plain" });
        return Response.ok("uploaded");
    }

    if (std.mem.eql(u8, path, "/r2/get")) {
        const bucket = try env.r2("BUCKET");
        const result = try bucket.get("my-object");
        if (result) |r| {
            var resp = Response.new();
            resp.setHeader("content-type", "application/octet-stream");
            resp.setBody(r.body);
            return resp;
        }
        return Response.err(.not_found, "object not found");
    }

    return Response.err(.not_found, "not found");
}
