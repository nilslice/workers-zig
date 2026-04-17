# workers-zig

A comprehensive Zig SDK for [Cloudflare Workers](https://workers.cloudflare.com). Write Workers, Durable Objects, Workflows, and more — entirely in Zig.

Built on [JSPI](https://v8.dev/blog/jspi) (JavaScript Promise Integration), `workers-zig` lets you call async Workers APIs with normal, synchronous Zig code. No callbacks, no event loops, no allocator gymnastics — just straightforward Zig.

## Features

- **Full Workers platform coverage** — KV, R2, D1, Durable Objects, Queues, AI, Workflows, Vectorize, Hyperdrive, Analytics Engine, Rate Limiting, Service Bindings, Artifacts, and more
- **HTTP Router** — path params, wildcards, method filtering, comptime route tables
- **Durable Objects** — define classes as Zig structs, auto-detected at build time
- **Workflows** — define steps with `step.do()`, `step.sleep()`, `step.waitForEvent()`
- **WebSockets** — server-side accept, send, receive loop
- **TCP Sockets** — outbound TCP connections with TLS and StartTLS
- **Streaming responses** — chunked transfer via `StreamingResponse`
- **Workers AI** — text generation, embeddings, image models, speech, streaming
- **Email** — incoming email routing and outbound email sending
- **Tail Workers** — structured trace/log consumption
- **HTML Rewriter** — streaming HTML transformation
- **Crypto** — Web Crypto API bindings
- **Zero-overhead build integration** — `zig build` produces `worker.wasm` + `entry.js` + `shim.js`, ready for `wrangler deploy`

## Quick Start

### Prerequisites

- [Zig 0.16+](https://ziglang.org/download/)
- [Wrangler](https://developers.cloudflare.com/workers/wrangler/) (for local dev and deployment)

### 1. Create your project

```
mkdir my-worker && cd my-worker
zig init
```

### 2. Add the dependency

```sh
zig fetch --save git+https://github.com/nilslice/workers-zig
```

Or manually add it to your `build.zig.zon`:

```zig
.{
    .name = .my_worker,
    .version = "0.1.0",
    .fingerprint = 0xYOUR_FINGERPRINT,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .@"workers-zig" = .{
            .url = "https://github.com/nilslice/workers-zig/archive/refs/heads/main.tar.gz",
            .hash = "...",  // zig build will tell you the correct hash
        },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

### 3. Set up build.zig

```zig
const std = @import("std");
const workers_zig = @import("workers-zig");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("workers-zig", .{});

    const exe = workers_zig.addWorker(b, dep, b.path("src/main.zig"), .{
        .name = "worker",
        .optimize = optimize,
    });

    b.installArtifact(exe);
}
```

### 4. Write your worker

```zig
// src/main.zig
const workers = @import("workers-zig");

pub fn fetch(request: *workers.Request, env: *workers.Env, _: *workers.Context) !workers.Response {
    _ = request;
    _ = env;
    return workers.Response.ok("Hello from Zig!");
}
```

### 5. Configure Wrangler

Create a `wrangler.toml`:

```toml
name = "my-worker"
main = "zig-out/bin/entry.js"

[build]
command = "zig build -Doptimize=ReleaseSmall"
```

### 6. Run locally

```sh
zig build && npx wrangler dev
```

## How It Works

`workers-zig` uses a 3-layer architecture:

```
Your Zig code
    ↓ imports "workers-zig"
src/entry.zig          — wasm export dispatcher (fetch, scheduled, queue, etc.)
    ↓ calls extern "env" functions
src/js.zig             — FFI declarations (extern fn → JS imports)
    ↓ imported by
js/shim.js             — JS glue: maps FFI calls to Workers runtime APIs
    ↓ wrapped with
JSPI (Suspending/Promising)  — async JS calls appear synchronous to Zig
```

**JSPI** is the key innovation: when your Zig code calls an async API (e.g., `kv.getText()`), the WebAssembly stack suspends, the JS promise resolves, and execution resumes in Zig — all transparently. Your Zig code reads like synchronous, blocking I/O.

**Build-time code generation**: `zig build` compiles your code to wasm, then `gen_entry` parses the wasm export section to discover Durable Object classes (via `do_<Name>_fetch` exports) and Workflow classes (via `wf_<Name>_run` exports), generating the correct `entry.js` with all necessary factory functions.

## Handler Entrypoints

Export these public functions from your `src/main.zig` to handle different event types:

```zig
// HTTP requests (required)
pub fn fetch(request: *workers.Request, env: *workers.Env, ctx: *workers.Context) !workers.Response

// Cron triggers
pub fn scheduled(event: *workers.ScheduledEvent, env: *workers.Env, ctx: *workers.Context) !void

// Queue consumer
pub fn queue(batch: *workers.Queue.Batch, env: *workers.Env, ctx: *workers.Context) !void

// Tail worker (log consumer)
pub fn tail(events: []const workers.Tail.TraceItem, env: *workers.Env, ctx: *workers.Context) !void

// Email routing
pub fn email(message: *workers.EmailMessage, env: *workers.Env, ctx: *workers.Context) !void
```

All handlers are auto-detected at compile time — just export the function and the framework handles the rest.

## Router

The built-in router provides path-parameter extraction and method-based routing with zero allocations:

```zig
const workers = @import("workers-zig");
const router = workers.Router;

pub fn fetch(request: *workers.Request, env: *workers.Env, _: *workers.Context) !workers.Response {
    return router.serve(request, env, &.{
        router.get("/", handleIndex),
        router.get("/users/:id", getUser),
        router.post("/users", createUser),
        router.all("/health", healthCheck),
    }) orelse workers.Response.err(.not_found, "Not Found");
}

fn getUser(_: *workers.Request, _: *workers.Env, params: *router.Params) !workers.Response {
    const id = params.get("id") orelse "unknown";
    return workers.Response.ok(id);
}
```

**Supported patterns:**
- Exact: `/api/users`
- Parameters: `/users/:id/posts/:post_id` (up to 8 params)
- Wildcards: `/static/*`
- Methods: `get`, `post`, `put`, `delete`, `patch`, `head`, `all`

## Bindings

### KV

```zig
const kv = try env.kv("MY_KV");

// Read
const value = try kv.getText("key");

// Write
kv.put("key", "value");

// List
const result = try kv.list(.{ .prefix = "user:" });

// Delete
kv.delete("key");
```

### R2

```zig
const bucket = try env.r2("MY_BUCKET");

// Upload
_ = try bucket.put("file.txt", body, .{ .content_type = "text/plain" });

// Download
if (try bucket.get("file.txt")) |obj| {
    const data = obj.body;
}

// List
const objects = try bucket.listObjects(.{ .prefix = "uploads/" });
```

### D1

```zig
const db = try env.d1("MY_DB");
const results = try db.query("SELECT * FROM users WHERE id = ?", .{42});
```

### Durable Objects

Define a Durable Object as a Zig struct with `fetch` (and optionally `alarm`):

```zig
pub const Counter = struct {
    state: workers.DurableObject.State,
    env: workers.Env,

    pub fn fetch(self: *Counter, request: *workers.Request) !workers.Response {
        var storage = self.state.storage();
        const count = try storage.get("count");
        // ...
        return workers.Response.ok(count orelse "0");
    }

    pub fn alarm(self: *Counter) !void {
        // periodic alarm logic
    }
};
```

Use from your fetch handler:

```zig
const ns = try env.durableObject("COUNTER");
const id = ns.idFromName("my-instance");
const stub = ns.get(id);
var resp = try stub.fetch("http://do/increment", .{});
```

The build system auto-detects DO classes and generates the necessary JS glue. Configure in `wrangler.toml`:

```toml
[durable_objects]
bindings = [{ name = "COUNTER", class_name = "Counter" }]

[[migrations]]
tag = "v1"
new_classes = ["Counter"]
```

### Workers AI

```zig
const ai = try env.ai("AI");

// Text generation
const result = try ai.textGeneration("@cf/meta/llama-3.1-8b-instruct", .{
    .prompt = "Explain WebAssembly in one sentence",
    .max_tokens = 100,
});
const text = result.response orelse "no response";

// Streaming
var reader = try ai.textGenerationStream("@cf/meta/llama-3.1-8b-instruct", .{
    .prompt = "Write a haiku",
    .max_tokens = 60,
});
while (try reader.next()) |chunk| {
    stream.write(chunk);
}

// Embeddings
const embeddings = try ai.textEmbeddings("@cf/baai/bge-base-en-v1.5", .{
    .text = &.{"hello world"},
});
```

### Workflows

Define a workflow class:

```zig
pub const MyWorkflow = struct {
    pub fn run(event: workers.Workflow.Event, step: workers.Workflow.Step) ![]const u8 {
        const result = try step.do("process", .{}, struct {
            fn callback() []const u8 {
                return "computed value";
            }
        }.callback);

        try step.sleep("pause", std.time.ms_per_s * 5);

        return result;
    }
};
```

Create and manage instances from your fetch handler:

```zig
const wf = try env.workflow("MY_WORKFLOW");
const instance = try wf.create(.{ .input = "data" }, .{});
const status = try instance.status();
```

Configure in `wrangler.toml`:

```toml
[[workflows]]
name = "my-workflow"
binding = "MY_WORKFLOW"
class_name = "MyWorkflow"
```

### Artifacts

```zig
const arts = try env.artifacts("ARTIFACTS");

// Create a repo
const result = try arts.create("my-repo", .{});
const remote = result.remote;
const token = result.token;

// Get a repo handle
if (try arts.get("my-repo")) |repo| {
    // Get repo info (JSON)
    const info_json = try repo.info();

    // Mint a read token valid for 1 hour
    const tok_json = try repo.createToken(.read, 3600);

    // Fork into a new repo
    const fork_json = try repo.fork("my-repo-fork", .{
        .description = "Fork for testing",
        .default_branch_only = true,
    });
}

// List repos
const list_json = try arts.list(.{ .limit = 20 });

// Import a public GitHub repo
const result = try arts.import(.{
    .source = .{
        .url = "https://github.com/nilslice/workers-zig",
        .branch = "main",
        .depth = 1,
    },
    .target = .{
        .name = "my-mirror",
    },
});

// Access imported repo via result.repo
const info = try result.repo.info();

// Delete a repo
_ = arts.delete("my-repo");
```

Configure the binding in `wrangler.toml`:

```toml
[[artifacts]]
binding = "ARTIFACTS"
namespace = "default"
```

### WebSockets

```zig
var ws = workers.WebSocket.init(allocator);
ws.accept();
ws.sendText("connected");

while (ws.receive()) |event| {
    switch (event.type()) {
        .text => {
            const msg = try event.text();
            ws.sendText(msg); // echo
        },
        .close => {
            ws.close(1000, "bye");
            break;
        },
        else => {},
    }
}

return ws.response();
```

### TCP Sockets

```zig
var socket = try workers.Socket.connect(allocator, "example.com", 80, .{});
socket.write("GET / HTTP/1.0\r\n\r\n");
const data = try socket.read();
socket.close();
```

### Queues

```zig
// Producer
const queue = try env.queue("MY_QUEUE");
queue.send("message body");

// Consumer (export the handler)
pub fn queue(batch: *workers.Queue.Batch, env: *workers.Env, ctx: *workers.Context) !void {
    for (batch.messages()) |msg| {
        const body = msg.body();
        msg.ack();
    }
}
```

### Streaming Responses

```zig
var stream = workers.StreamingResponse.start(.{});
stream.setHeader("content-type", "text/event-stream");
stream.write("data: hello\n\n");
stream.write("data: world\n\n");
stream.close();
return stream.response();
```

### Email

Incoming email routing:

```zig
pub fn email(message: *workers.EmailMessage, _: *workers.Env, _: *workers.Context) !void {
    const from = message.from();
    const to = message.to();
    const size = message.rawSize();

    // Forward, reply, or reject
    try message.forward("admin@example.com");
}
```

Outbound email:

```zig
const mailer = try env.sendEmail("EMAIL");
try mailer.send(.{
    .from = "noreply@example.com",
    .to = "user@example.com",
    .subject = "Hello from Zig",
    .body_text = "Plain text body",
    .body_html = "<h1>Hello!</h1>",
});
```

### Tail Workers

```zig
pub fn tail(events: []const workers.Tail.TraceItem, env: *workers.Env, _: *workers.Context) !void {
    for (events) |item| {
        for (item.logs) |entry| {
            workers.log("trace: {s}", .{entry.message});
        }
    }
}
```

### Additional Bindings

| Binding | Access | Description |
|---------|--------|-------------|
| **Cache** | `workers.Cache` | Cache API (put, match, delete) |
| **Vectorize** | `env.vectorize("INDEX")` | Vector database for embeddings |
| **Hyperdrive** | `env.hyperdrive("DB")` | Connection pooling for databases |
| **Analytics Engine** | `env.analyticsEngine("AE")` | Write analytics data points |
| **Rate Limiting** | `env.rateLimit("RL")` | Rate limiter binding |
| **Service Bindings** | `env.serviceBinding("SVC")` | Call other Workers |
| **Dispatch Namespace** | `env.dispatchNamespace("NS")` | Workers for Platforms |
| **Crypto** | `workers.Crypto` | Web Crypto (digest, random, sign, verify) |
| **HTMLRewriter** | `workers.HTMLRewriter` | Streaming HTML transformation |
| **FormData** | `workers.FormData` | Multipart form data parsing |
| **EventSource** | `workers.EventSource` | Server-Sent Events (SSE) |
| **Artifacts** | `env.artifacts("ARTIFACTS")` | Durable Git repos (create, fork, tokens) |
| **Container** | `workers.Container` | Container Workers |

### Convenience Functions

```zig
// Outbound HTTP fetch
var resp = try workers.fetch(allocator, "https://api.example.com/data", .{
    .method = .POST,
    .body = "{\"key\": \"value\"}",
});
defer resp.deinit();
const body = try resp.text();

// Current time (milliseconds since epoch)
const timestamp = workers.now();

// Sleep (JSPI-suspending)
workers.sleep(1000);

// Console logging
workers.log("request from {s}", .{request.cf().country orelse "unknown"});
```

## Examples

See the [`examples/`](examples/) directory:

| Example | Description |
|---------|-------------|
| [01-hello](examples/01-hello/) | Router-based hello world with path params |
| [02-kv-r2](examples/02-kv-r2/) | KV and R2 storage operations |
| [03-durable-object](examples/03-durable-object/) | Durable Object counter with increment/get/reset |
| [04-websocket-ai](examples/04-websocket-ai/) | WebSocket echo server + Workers AI text generation |
| [05-tcp-echo](examples/05-tcp-echo/) | Outbound TCP socket + HTTP fetch |

Each example is a standalone project. To run one:

```sh
cd examples/01-hello
zig build && npx wrangler dev
```

## Project Structure

```
workers-zig/
├── build.zig          # Build system with addWorker() helper
├── build.zig.zon      # Package manifest
├── src/
│   ├── root.zig       # Public API surface
│   ├── entry.zig      # Wasm export dispatcher
│   ├── js.zig         # FFI extern declarations
│   ├── gen_entry.zig  # Build tool: wasm → entry.js
│   ├── Router.zig     # HTTP router
│   ├── Workflow.zig   # Workflows API
│   ├── ...            # One file per binding
│   └── Tail.zig       # Tail workers
├── js/
│   └── shim.js        # JS glue layer (JSPI, handle table, API mapping)
└── examples/          # Standalone example workers
```

## Requirements

- **Zig 0.16.0** or later
- **Wrangler** for local development and deployment
- Workers runtime with **JSPI support** (standard on Cloudflare Workers)

## License

MIT
