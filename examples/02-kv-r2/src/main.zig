const std = @import("std");
const workers = @import("workers-zig");

/// KV + R2 example — no router, bare path matching.
pub fn fetch(request: *workers.Request, env: *workers.Env, _: *workers.Context) !workers.Response {
    const url = try request.url();
    const path = workers.Router.extractPath(url);

    // -- KV --
    if (std.mem.eql(u8, path, "/kv/put")) {
        const body = (try request.body()) orelse return workers.Response.err(.bad_request, "missing body");
        const kv = try env.kv("STORE");
        kv.put("my-key", body);
        return workers.Response.ok("stored");
    }

    if (std.mem.eql(u8, path, "/kv/get")) {
        const kv = try env.kv("STORE");
        const value = try kv.getText("my-key");
        return workers.Response.ok(value orelse "not found");
    }

    if (std.mem.eql(u8, path, "/kv/list")) {
        const kv = try env.kv("STORE");
        const result = try kv.list(.{});
        return workers.Response.json(result);
    }

    // -- R2 --
    if (std.mem.eql(u8, path, "/r2/put")) {
        const body = (try request.body()) orelse return workers.Response.err(.bad_request, "missing body");
        const bucket = try env.r2("BUCKET");
        _ = try bucket.put("my-object", body, .{ .content_type = "text/plain" });
        return workers.Response.ok("uploaded");
    }

    if (std.mem.eql(u8, path, "/r2/get")) {
        const bucket = try env.r2("BUCKET");
        const result = try bucket.get("my-object");
        if (result) |r| {
            var resp = workers.Response.new();
            resp.setHeader("content-type", "application/octet-stream");
            resp.setBody(r.body);
            return resp;
        }
        return workers.Response.err(.not_found, "object not found");
    }

    return workers.Response.err(.not_found, "not found");
}
