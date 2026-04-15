const std = @import("std");
const workers = @import("workers-zig");

/// HTTP handler — demonstrates outbound TCP socket and outbound HTTP fetch.
pub fn fetch(request: *workers.Request, _: *workers.Env, _: *workers.Context) !workers.Response {
    const url = try request.url();
    const path = workers.Router.extractPath(url);

    if (std.mem.eql(u8, path, "/")) {
        return workers.Response.ok("Outbound TCP + HTTP example. Try GET /fetch-example or GET /tcp-example");
    }

    if (std.mem.eql(u8, path, "/fetch-example")) {
        const alloc = std.heap.wasm_allocator;
        var resp = try workers.fetch(alloc, "https://example.com", .{});
        defer resp.deinit();

        const status = @intFromEnum(resp.status());
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Fetched example.com: status={d}", .{status}) catch "error";
        return workers.Response.ok(msg);
    }

    if (std.mem.eql(u8, path, "/tcp-example")) {
        const alloc = std.heap.wasm_allocator;
        var socket = workers.Socket.connect(alloc, "example.com", 80, .{});
        defer socket.close();

        socket.write("GET / HTTP/1.0\r\nHost: example.com\r\n\r\n");
        if (try socket.read()) |chunk| {
            return workers.Response.ok(chunk);
        }
        return workers.Response.ok("no response from TCP socket");
    }

    return workers.Response.err(.not_found, "not found");
}
