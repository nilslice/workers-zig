const std = @import("std");
const workers = @import("workers-zig");

/// TCP echo server — incoming connections get their data echoed back.
/// Also demonstrates outbound fetch from the main HTTP handler.
pub fn connect(socket: *workers.Socket, _: *workers.Env, _: *workers.Context) !void {
    const info = try socket.opened();
    workers.log("TCP connection from {s}", .{info.remoteAddress orelse "unknown"});

    while (try socket.read()) |chunk| {
        socket.write(chunk);
    }

    socket.close();
}

/// HTTP handler — shows basic info and demonstrates outbound fetch.
pub fn fetch(request: *workers.Request, _: *workers.Env, _: *workers.Context) !workers.Response {
    const url = try request.url();
    const path = workers.Router.extractPath(url);

    if (std.mem.eql(u8, path, "/")) {
        return workers.Response.ok("TCP Echo Server + HTTP handler. Connect via TCP or GET /fetch-example");
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

    return workers.Response.err(.not_found, "not found");
}
