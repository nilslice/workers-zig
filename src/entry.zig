const std = @import("std");
const workers = @import("workers-zig");
const user = @import("worker_main");

const wasm_allocator = std.heap.wasm_allocator;

// ---------------------------------------------------------------------------
// Wasm-exported fetch handler.  Called from the JS shim.
// ---------------------------------------------------------------------------
export fn fetch(req_handle: u32, env_handle: u32, ctx_handle: u32) u32 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var request = workers.Request.init(req_handle, alloc);
    var env = workers.Env.init(env_handle, alloc);
    var ctx = workers.Context.init(ctx_handle);

    const response = callFetch(&request, &env, &ctx);
    return response.handle;
}

/// Comptime-dispatch: handles both `!Response` and plain `Response` return types.
fn callFetch(
    request: *workers.Request,
    env: *workers.Env,
    ctx: *workers.Context,
) workers.Response {
    const F = @TypeOf(user.fetch);
    const info = @typeInfo(F).@"fn";
    const ReturnType = info.return_type orelse workers.Response;

    if (comptime @typeInfo(ReturnType) == .error_union) {
        return user.fetch(request, env, ctx) catch {
            return workers.Response.err(.internal_server_error, "Internal Server Error");
        };
    } else {
        return user.fetch(request, env, ctx);
    }
}

// ---------------------------------------------------------------------------
// Wasm-exported scheduled handler.  Only emitted if the user defines
// `pub fn scheduled(...)` in their worker module.
// ---------------------------------------------------------------------------
const has_scheduled = @hasDecl(user, "scheduled");

comptime {
    if (has_scheduled) {
        @export(&scheduledImpl, .{ .name = "scheduled" });
    }
}

fn scheduledImpl(event_handle: u32, env_handle: u32, ctx_handle: u32) callconv(.c) void {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var event = workers.ScheduledEvent.init(event_handle, alloc);
    var env = workers.Env.init(env_handle, alloc);
    var ctx = workers.Context.init(ctx_handle);

    callScheduled(&event, &env, &ctx);
}

fn callScheduled(
    event: *workers.ScheduledEvent,
    env: *workers.Env,
    ctx: *workers.Context,
) void {
    if (!has_scheduled) return;

    const F = @TypeOf(user.scheduled);
    const info = @typeInfo(F).@"fn";
    const ReturnType = info.return_type orelse void;

    if (comptime @typeInfo(ReturnType) == .error_union) {
        user.scheduled(event, env, ctx) catch |e| {
            workers.log("scheduled handler error: {}", .{e});
        };
    } else {
        user.scheduled(event, env, ctx);
    }
}

// ---------------------------------------------------------------------------
// Wasm-exported queue handler.  Only emitted if the user defines
// `pub fn queue(...)` in their worker module.
// ---------------------------------------------------------------------------
const has_queue = @hasDecl(user, "queue");

comptime {
    if (has_queue) {
        @export(&queueImpl, .{ .name = "queue" });
    }
}

fn queueImpl(batch_handle: u32, env_handle: u32, ctx_handle: u32) callconv(.c) void {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var batch = workers.Queue.MessageBatch.init(batch_handle, alloc);
    var env = workers.Env.init(env_handle, alloc);
    var ctx = workers.Context.init(ctx_handle);

    callQueue(&batch, &env, &ctx);
}

fn callQueue(
    batch: *workers.Queue.MessageBatch,
    env: *workers.Env,
    ctx: *workers.Context,
) void {
    if (!has_queue) return;

    const F = @TypeOf(user.queue);
    const info = @typeInfo(F).@"fn";
    const ReturnType = info.return_type orelse void;

    if (comptime @typeInfo(ReturnType) == .error_union) {
        user.queue(batch, env, ctx) catch |e| {
            workers.log("queue handler error: {}", .{e});
        };
    } else {
        user.queue(batch, env, ctx);
    }
}

// ---------------------------------------------------------------------------
// Wasm-exported tail handler.  Only emitted if the user defines
// `pub fn tail(...)` in their worker module.
// ---------------------------------------------------------------------------
const has_tail = @hasDecl(user, "tail");

comptime {
    if (has_tail) {
        @export(&tailImpl, .{ .name = "tail" });
    }
}

fn tailImpl(events_handle: u32, env_handle: u32, ctx_handle: u32) callconv(.c) void {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const events = workers.Tail.parseTraceItems(events_handle, alloc) catch &.{};
    var env = workers.Env.init(env_handle, alloc);
    var ctx = workers.Context.init(ctx_handle);

    callTail(events, &env, &ctx);
}

fn callTail(
    events: []const workers.Tail.TraceItem,
    env: *workers.Env,
    ctx: *workers.Context,
) void {
    if (!has_tail) return;

    const F = @TypeOf(user.tail);
    const info = @typeInfo(F).@"fn";
    const ReturnType = info.return_type orelse void;

    if (comptime @typeInfo(ReturnType) == .error_union) {
        user.tail(events, env, ctx) catch |e| {
            workers.log("tail handler error: {}", .{e});
        };
    } else {
        user.tail(events, env, ctx);
    }
}

// ---------------------------------------------------------------------------
// Wasm-exported email handler.  Only emitted if the user defines
// `pub fn email(...)` in their worker module.
// ---------------------------------------------------------------------------
const has_email = @hasDecl(user, "email");

comptime {
    if (has_email) {
        @export(&emailImpl, .{ .name = "email" });
    }
}

fn emailImpl(msg_handle: u32, env_handle: u32, ctx_handle: u32) callconv(.c) void {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var message = workers.EmailMessage.init(msg_handle, alloc);
    var env = workers.Env.init(env_handle, alloc);
    var ctx = workers.Context.init(ctx_handle);

    callEmail(&message, &env, &ctx);
}

fn callEmail(
    message: *workers.EmailMessage,
    env: *workers.Env,
    ctx: *workers.Context,
) void {
    if (!has_email) return;

    const F = @TypeOf(user.email);
    const info = @typeInfo(F).@"fn";
    const ReturnType = info.return_type orelse void;

    if (comptime @typeInfo(ReturnType) == .error_union) {
        user.email(message, env, ctx) catch |e| {
            workers.log("email handler error: {}", .{e});
        };
    } else {
        user.email(message, env, ctx);
    }
}

// ---------------------------------------------------------------------------
// Wasm-exported connect handler.  Only emitted if the user defines
// `pub fn connect(...)` in their worker module.
// ---------------------------------------------------------------------------
const has_connect = @hasDecl(user, "connect");

comptime {
    if (has_connect) {
        @export(&connectImpl, .{ .name = "connect" });
    }
}

fn connectImpl(socket_handle: u32, env_handle: u32, ctx_handle: u32) callconv(.c) void {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var socket = workers.Socket{ .handle = socket_handle, .allocator = alloc };
    var env = workers.Env.init(env_handle, alloc);
    var ctx = workers.Context.init(ctx_handle);

    callConnect(&socket, &env, &ctx);
}

fn callConnect(
    socket: *workers.Socket,
    env: *workers.Env,
    ctx: *workers.Context,
) void {
    if (!has_connect) return;

    const F = @TypeOf(user.connect);
    const info = @typeInfo(F).@"fn";
    const ReturnType = info.return_type orelse void;

    if (comptime @typeInfo(ReturnType) == .error_union) {
        user.connect(socket, env, ctx) catch |e| {
            workers.log("connect handler error: {}", .{e});
        };
    } else {
        user.connect(socket, env, ctx);
    }
}

// ---------------------------------------------------------------------------
// Durable Object exports.
//
// Scans the user module for struct declarations that have a
// `state: workers.DurableObject.State` field and a `pub fn fetch` method.
// For each match, exports `do_<Name>_fetch` (and optionally `do_<Name>_alarm`).
// The JS shim discovers these exports and generates DO classes at runtime.
// ---------------------------------------------------------------------------
fn isDurableObjectClass(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    // Must have a `state` field of type DurableObject.State
    if (!@hasField(T, "state")) return false;
    if (@FieldType(T, "state") != workers.DurableObject.State) return false;
    // Must have a `fetch` method
    if (!@hasDecl(T, "fetch")) return false;
    return true;
}

fn makeDOFetchFn(comptime DO: type) *const fn (u32, u32, u32) callconv(.c) u32 {
    return &struct {
        fn handler(state_h: u32, env_h: u32, req_h: u32) callconv(.c) u32 {
            var arena = std.heap.ArenaAllocator.init(wasm_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            var instance: DO = .{
                .state = workers.DurableObject.State.init(state_h, alloc),
                .env = workers.Env.init(env_h, alloc),
            };
            var request = workers.Request.init(req_h, alloc);

            const resp = callDOFetch(DO, &instance, &request);
            return resp.handle;
        }
    }.handler;
}

fn callDOFetch(comptime DO: type, instance: *DO, request: *workers.Request) workers.Response {
    const F = @TypeOf(DO.fetch);
    const info = @typeInfo(F).@"fn";
    const ReturnType = info.return_type orelse workers.Response;

    if (comptime @typeInfo(ReturnType) == .error_union) {
        return instance.fetch(request) catch {
            return workers.Response.err(.internal_server_error, "Internal Server Error");
        };
    } else {
        return instance.fetch(request);
    }
}

fn makeDOAlarmFn(comptime DO: type) *const fn (u32, u32) callconv(.c) void {
    return &struct {
        fn handler(state_h: u32, env_h: u32) callconv(.c) void {
            var arena = std.heap.ArenaAllocator.init(wasm_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            var instance: DO = .{
                .state = workers.DurableObject.State.init(state_h, alloc),
                .env = workers.Env.init(env_h, alloc),
            };

            callDOAlarm(DO, &instance);
        }
    }.handler;
}

fn callDOAlarm(comptime DO: type, instance: *DO) void {
    const F = @TypeOf(DO.alarm);
    const info = @typeInfo(F).@"fn";
    const ReturnType = info.return_type orelse void;

    if (comptime @typeInfo(ReturnType) == .error_union) {
        instance.alarm() catch |e| {
            workers.log("DO alarm error: {}", .{e});
        };
    } else {
        instance.alarm();
    }
}

// ---------------------------------------------------------------------------
// Workflow exports.
//
// Scans the user module for struct declarations that have a
// `state: workers.Workflow.State` field and a `pub fn run` method.
// For each match, exports `wf_<Name>_run`.
// ---------------------------------------------------------------------------
fn isWorkflowClass(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    if (!@hasField(T, "state")) return false;
    if (@FieldType(T, "state") != workers.Workflow.State) return false;
    if (!@hasDecl(T, "run")) return false;
    return true;
}

fn makeWorkflowRunFn(comptime WF: type) *const fn (u32, u32, u32) callconv(.c) void {
    return &struct {
        fn handler(event_h: u32, step_h: u32, env_h: u32) callconv(.c) void {
            var arena = std.heap.ArenaAllocator.init(wasm_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            var instance: WF = .{
                .state = workers.Workflow.State.init(alloc),
                .env = workers.Env.init(env_h, alloc),
            };
            var event = workers.Workflow.Event.init(event_h, alloc);
            var step = workers.Workflow.Step.init(step_h, alloc);

            callWorkflowRun(WF, &instance, &event, &step);
        }
    }.handler;
}

fn callWorkflowRun(comptime WF: type, instance: *WF, event: *workers.Workflow.Event, step: *workers.Workflow.Step) void {
    const F = @TypeOf(WF.run);
    const info = @typeInfo(F).@"fn";
    const ReturnType = info.return_type orelse void;

    if (comptime @typeInfo(ReturnType) == .error_union) {
        instance.run(event, step) catch |e| {
            workers.log("workflow run error: {}", .{e});
        };
    } else {
        instance.run(event, step);
    }
}

comptime {
    // Scan user module declarations for Durable Object and Workflow classes.
    for (@typeInfo(user).@"struct".decls) |decl| {
        if (@TypeOf(@field(user, decl.name)) == type) {
            const T = @field(user, decl.name);

            // -- Durable Object detection --
            if (isDurableObjectClass(T)) {
                const class_name = if (@hasDecl(T, "override_do_classname"))
                    T.override_do_classname
                else
                    decl.name;

                @export(makeDOFetchFn(T), .{ .name = "do_" ++ class_name ++ "_fetch" });

                if (@hasDecl(T, "alarm")) {
                    @export(makeDOAlarmFn(T), .{ .name = "do_" ++ class_name ++ "_alarm" });
                }
            }

            // -- Workflow detection --
            if (isWorkflowClass(T)) {
                const class_name = if (@hasDecl(T, "override_workflow_classname"))
                    T.override_workflow_classname
                else
                    decl.name;

                @export(makeWorkflowRunFn(T), .{ .name = "wf_" ++ class_name ++ "_run" });
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Memory exports – allow the JS shim to allocate into Wasm linear memory.
// ---------------------------------------------------------------------------
export fn wasm_alloc(len: u32) ?[*]u8 {
    const slice = wasm_allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

export fn wasm_dealloc(ptr: [*]u8, len: u32) void {
    wasm_allocator.free(ptr[0..len]);
}
