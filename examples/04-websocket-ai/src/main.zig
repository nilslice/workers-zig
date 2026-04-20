const std = @import("std");
const workers = @import("workers-zig");
const Request = workers.Request;
const Response = workers.Response;
const Env = workers.Env;
const Context = workers.Context;
const Router = workers.Router;
const WebSocket = workers.WebSocket;
const StreamingResponse = workers.StreamingResponse;

/// WebSocket chat + AI text generation example — bare path matching.
pub fn fetch(request: *Request, env: *Env, _: *Context) !Response {
    const url = try request.url();
    const path = Router.extractPath(url);

    if (std.mem.eql(u8, path, "/")) {
        return Response.html(
            \\<html><body>
            \\<h2>workers-zig: WebSocket + AI</h2>
            \\<p>Connect via WebSocket to <code>/ws</code> for echo.</p>
            \\<p>GET <code>/ai/ask?q=your+question</code> for AI text generation.</p>
            \\</body></html>
        );
    }

    // -- WebSocket echo -------------------------------------------------
    if (std.mem.eql(u8, path, "/ws")) {
        const alloc = std.heap.wasm_allocator;
        var ws = WebSocket.init(alloc);
        ws.accept();
        ws.sendText("connected");

        while (ws.receive()) |event| {
            switch (event.type()) {
                .text => {
                    const msg = try event.text();
                    var buf: [512]u8 = undefined;
                    const reply = std.fmt.bufPrint(&buf, "echo: {s}", .{msg}) catch "echo: ?";
                    ws.sendText(reply);
                },
                .close => {
                    ws.close(1000, "bye");
                    break;
                },
                else => {},
            }
        }

        return ws.response();
    }

    // -- AI text generation ---------------------------------------------
    if (std.mem.eql(u8, path, "/ai/ask")) {
        // Extract query from ?q=...
        const full_path = Router.extractPath(url);
        const query = if (std.mem.indexOf(u8, full_path, "?q=")) |qi|
            full_path[qi + 3 ..]
        else
            "Say hello in one sentence";

        const ai = try env.ai("AI");
        const result = try ai.textGeneration("@cf/meta/llama-3.1-8b-instruct", .{
            .prompt = query,
            .max_tokens = 150,
        });

        if (result.response) |text| {
            return Response.ok(text);
        }
        return Response.err(.internal_server_error, "AI returned no response");
    }

    // -- AI streaming ---------------------------------------------------
    if (std.mem.eql(u8, path, "/ai/stream")) {
        const ai = try env.ai("AI");
        var stream = StreamingResponse.start(.{});
        stream.setHeader("content-type", "text/event-stream");

        var reader = try ai.textGenerationStream("@cf/meta/llama-3.1-8b-instruct", .{
            .prompt = "Write a haiku about systems programming",
            .max_tokens = 60,
        });
        while (try reader.next()) |chunk| {
            stream.write(chunk);
        }
        stream.close();
        return stream.response();
    }

    return Response.err(.not_found, "not found");
}
