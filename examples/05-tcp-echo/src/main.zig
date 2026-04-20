const std = @import("std");
const workers = @import("workers-zig");
const Request = workers.Request;
const Response = workers.Response;
const Env = workers.Env;
const Context = workers.Context;
const Router = workers.Router;
const Socket = workers.Socket;

/// HTTP handler — demonstrates outbound TCP socket and outbound HTTP fetch.
pub fn fetch(request: *Request, _: *Env, _: *Context) !Response {
    const url = try request.url();
    const path = Router.extractPath(url);

    if (std.mem.eql(u8, path, "/")) {
        return Response.ok("Outbound TCP + HTTP example. Try GET /fetch-example or GET /tcp-example");
    }

    if (std.mem.eql(u8, path, "/fetch-example")) {
        const alloc = std.heap.wasm_allocator;
        var resp = try workers.fetch(alloc, "https://example.com", .{});
        defer resp.deinit();

        const status = @intFromEnum(resp.status());
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Fetched example.com: status={d}", .{status}) catch "error";
        return Response.ok(msg);
    }

    if (std.mem.eql(u8, path, "/tcp-example")) {
        const alloc = std.heap.wasm_allocator;
        var socket = Socket.connect(alloc, "example.com", 80, .{});
        defer socket.close();

        socket.write("GET / HTTP/1.0\r\nHost: example.com\r\n\r\n");
        if (try socket.read()) |chunk| {
            return Response.ok(chunk);
        }
        return Response.ok("no response from TCP socket");
    }

    return Response.err(.not_found, "not found");
}
