const std = @import("std");
const js = @import("js.zig");

// ===========================================================================
// Workflow — Cloudflare Workflows binding and entrypoint API.
//
// Two main use cases:
//
// 1. **Binding** (from env): Create and manage workflow instances.
//    ```zig
//    const wf = try env.workflow("MY_WORKFLOW");
//    var instance = try wf.create(.{ .key = "value" }, .{});
//    const status = try instance.status();
//    ```
//
// 2. **Entrypoint** (define a workflow class): Export a struct with
//    `state: Workflow.State` and a `run` method.
//    ```zig
//    pub const MyWorkflow = struct {
//        state: Workflow.State,
//        env: Env,
//
//        pub fn run(self: *MyWorkflow, event: *Workflow.Event, step: *Workflow.Step) !void {
//            const result = try step.do("fetch", .{}, struct {
//                fn run() []const u8 {
//                    // Only runs on first execution — skipped on replay.
//                    return "hello world";
//                }
//            }.run);
//            try step.sleep("cooldown", "30 seconds");
//        }
//    };
//    ```
//
// **step.do() semantics:** Matches JS behavior exactly — the callback is
// only invoked on first execution. On replay, the callback is skipped
// entirely and the cached result is returned. The callback runs on a
// separate JSPI stack, so it can call async imports (fetch, KV, etc.).
// ===========================================================================

const Workflow = @This();

// ===========================================================================
// Binding API — managing workflow instances from a Worker handler
// ===========================================================================

handle: js.Handle,
allocator: std.mem.Allocator,

pub fn init(handle: js.Handle, allocator: std.mem.Allocator) Workflow {
    return .{ .handle = handle, .allocator = allocator };
}

/// Create a new workflow instance with typed parameters.
///
/// ```zig
/// var instance = try wf.create(.{ .input = "test" }, .{});
/// var instance2 = try wf.create(.{ .key = "value" }, .{ .id = "my-id" });
/// ```
pub fn create(self: Workflow, params: anytype, options: CreateOptions) !Instance {
    const id_ptr: ?[*]const u8 = if (options.id) |id| id.ptr else null;
    const id_len: u32 = if (options.id) |id| @intCast(id.len) else 0;

    // Serialize params to JSON.
    var w = std.Io.Writer.Allocating.init(self.allocator);
    std.json.fmt(params, .{}).format(&w.writer) catch return error.JsonSerializationFailed;
    const params_json = w.toOwnedSlice() catch return error.OutOfMemory;
    defer self.allocator.free(params_json);

    const h = js.workflow_create(self.handle, id_ptr, id_len, params_json.ptr, @intCast(params_json.len));
    if (h == js.null_handle) return error.WorkflowCreateFailed;
    return Instance{ .handle = h, .allocator = self.allocator };
}

/// Get a handle to an existing workflow instance by ID.
pub fn get(self: Workflow, instance_id: []const u8) !Instance {
    const h = js.workflow_get(self.handle, instance_id.ptr, @intCast(instance_id.len));
    if (h == js.null_handle) return error.WorkflowInstanceNotFound;
    return Instance{ .handle = h, .allocator = self.allocator };
}

pub const CreateOptions = struct {
    /// Unique instance ID. Auto-generated if null.
    id: ?[]const u8 = null,
};

// ===========================================================================
// Instance — a handle to a running or completed workflow instance
// ===========================================================================

pub const Instance = struct {
    handle: js.Handle,
    allocator: std.mem.Allocator,

    /// Get the instance ID.
    pub fn id(self: Instance) ![]const u8 {
        const h = js.workflow_instance_id(self.handle);
        if (h == js.null_handle) return error.WorkflowError;
        return js.readString(h, self.allocator);
    }

    /// Pause the instance.
    pub fn pause(self: Instance) void {
        js.workflow_instance_pause(self.handle);
    }

    /// Resume a paused instance.
    pub fn @"resume"(self: Instance) void {
        js.workflow_instance_resume(self.handle);
    }

    /// Terminate the instance.
    pub fn terminate(self: Instance) void {
        js.workflow_instance_terminate(self.handle);
    }

    /// Restart the instance from the beginning.
    pub fn restart(self: Instance) void {
        js.workflow_instance_restart(self.handle);
    }

    /// Get the current instance status.
    pub fn status(self: Instance) !InstanceStatus {
        const h = js.workflow_instance_status(self.handle);
        if (h == js.null_handle) return error.WorkflowError;
        const json = try js.readString(h, self.allocator);
        return parseInstanceStatus(self.allocator, json);
    }

    /// Send an event to this instance (resumes waitForEvent steps).
    pub fn sendEvent(self: Instance, event_type: []const u8, payload: []const u8) void {
        js.workflow_instance_send_event(
            self.handle,
            event_type.ptr,
            @intCast(event_type.len),
            payload.ptr,
            @intCast(payload.len),
        );
    }
};

pub const InstanceStatus = struct {
    status: Status,
    error_name: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    output: ?[]const u8 = null,
};

pub const Status = enum {
    queued,
    running,
    paused,
    errored,
    terminated,
    complete,
    waiting,
    waiting_for_pause,
    unknown,

    pub fn fromString(s: []const u8) Status {
        const map = .{
            .{ "queued", .queued },
            .{ "running", .running },
            .{ "paused", .paused },
            .{ "errored", .errored },
            .{ "terminated", .terminated },
            .{ "complete", .complete },
            .{ "waiting", .waiting },
            .{ "waitingForPause", .waiting_for_pause },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, s, entry[0])) return entry[1];
        }
        return .unknown;
    }
};

fn parseInstanceStatus(allocator: std.mem.Allocator, json: []const u8) !InstanceStatus {
    var result: InstanceStatus = .{ .status = .unknown };

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch {
        return result;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    if (obj.get("status")) |s| {
        if (s == .string) {
            result.status = Status.fromString(s.string);
        }
    }
    if (obj.get("error")) |err_val| {
        if (err_val == .object) {
            if (err_val.object.get("name")) |n| {
                if (n == .string) result.error_name = try allocator.dupe(u8, n.string);
            }
            if (err_val.object.get("message")) |m| {
                if (m == .string) result.error_message = try allocator.dupe(u8, m.string);
            }
        }
    }
    if (obj.get("output")) |out| {
        if (out == .string) {
            result.output = try allocator.dupe(u8, out.string);
        } else if (out != .null) {
            // For non-string outputs, re-serialize the raw JSON slice.
            // The status JSON is already in memory, so we store a
            // placeholder. Full re-serialization of dynamic values is
            // complex; callers needing structured output should parse
            // the raw status JSON directly.
            result.output = try allocator.dupe(u8, "{}");
        }
    }

    return result;
}

// ===========================================================================
// Entrypoint API — for defining workflow classes in Zig
// ===========================================================================

/// Marker type for workflow entrypoint detection.
/// A workflow class must have `state: Workflow.State` as a field.
pub const State = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }
};

/// Workflow event data passed to the run() method.
pub const Event = struct {
    handle: js.Handle,
    allocator: std.mem.Allocator,

    pub fn init(handle: js.Handle, allocator: std.mem.Allocator) Event {
        return .{ .handle = handle, .allocator = allocator };
    }

    /// Get the event payload as a JSON string.
    pub fn payload(self: Event) ![]const u8 {
        const h = js.workflow_event_payload(self.handle);
        if (h == js.null_handle) return error.NoPayload;
        return js.readString(h, self.allocator);
    }

    /// Get the event timestamp (milliseconds since epoch).
    pub fn timestamp(self: Event) f64 {
        return js.workflow_event_timestamp(self.handle);
    }

    /// Get the workflow instance ID.
    pub fn instanceId(self: Event) ![]const u8 {
        const h = js.workflow_event_instance_id(self.handle);
        if (h == js.null_handle) return error.NoInstanceId;
        return js.readString(h, self.allocator);
    }
};

/// Workflow step context — provides step.do, step.sleep, step.waitForEvent.
pub const Step = struct {
    handle: js.Handle,
    allocator: std.mem.Allocator,

    pub fn init(handle: js.Handle, allocator: std.mem.Allocator) Step {
        return .{ .handle = handle, .allocator = allocator };
    }

    /// Execute a named step with a callback. The callback runs on first
    /// execution and its result is cached. On replay, the callback is
    /// skipped entirely and the cached result is returned — matching the
    /// JS `step.do()` semantics exactly.
    ///
    /// The callback returns `[]const u8` (or `![]const u8`). It can call
    /// any JSPI-suspending function (fetch, KV, etc.).
    ///
    /// ```zig
    /// const result = try step.do("fetch-data", .{}, struct {
    ///     fn run() []const u8 {
    ///         // Only runs on first execution — skipped on replay.
    ///         return "hello world";
    ///     }
    /// }.run);
    /// ```
    pub fn do(self: Step, name: []const u8, config: StepConfig, comptime callback: anytype) ![]const u8 {
        const Wrapper = struct {
            fn invoke() callconv(.c) u32 {
                const ReturnType = @typeInfo(@TypeOf(callback)).@"fn".return_type.?;
                if (comptime @typeInfo(ReturnType) == .error_union) {
                    const result = callback() catch return js.null_handle;
                    return js.createStringHandle(result);
                } else {
                    return js.createStringHandle(callback());
                }
            }
        };

        const config_str = try buildStepConfigJson(self.allocator, config);

        const h = js.workflow_step_do(
            self.handle,
            name.ptr,
            @intCast(name.len),
            config_str.ptr,
            @intCast(config_str.len),
            @intFromPtr(&Wrapper.invoke),
        );
        if (h == js.null_handle) return error.StepFailed;
        return js.readString(h, self.allocator);
    }

    /// Sleep for a duration string (e.g., "30 seconds", "5 minutes", "1 hour").
    pub fn sleep(self: Step, name: []const u8, duration: []const u8) void {
        js.workflow_step_sleep(
            self.handle,
            name.ptr,
            @intCast(name.len),
            duration.ptr,
            @intCast(duration.len),
        );
    }

    /// Sleep until a specific timestamp (milliseconds since epoch).
    pub fn sleepUntil(self: Step, name: []const u8, timestamp_ms: f64) void {
        js.workflow_step_sleep_until(
            self.handle,
            name.ptr,
            @intCast(name.len),
            timestamp_ms,
        );
    }

    /// Wait for an external event. Returns the event payload when received.
    /// Timeout is optional (e.g., "24 hours"). Returns error if timeout expires.
    pub fn waitForEvent(self: Step, name: []const u8, event_type: []const u8, timeout: ?[]const u8) !StepEvent {
        const timeout_ptr: ?[*]const u8 = if (timeout) |t| t.ptr else null;
        const timeout_len: u32 = if (timeout) |t| @intCast(t.len) else 0;

        const h = js.workflow_step_wait_for_event(
            self.handle,
            name.ptr,
            @intCast(name.len),
            event_type.ptr,
            @intCast(event_type.len),
            timeout_ptr,
            timeout_len,
        );
        if (h == js.null_handle) return error.WaitForEventFailed;

        // Parse the event JSON
        const json = try js.readString(h, self.allocator);
        return parseStepEvent(self.allocator, json);
    }
};

pub const StepConfig = struct {
    retries: ?RetryConfig = null,
    timeout: ?[]const u8 = null,
};

pub const RetryConfig = struct {
    limit: u32 = 3,
    delay: []const u8 = "1 second",
    backoff: Backoff = .exponential,
};

pub const Backoff = enum {
    constant,
    linear,
    exponential,

    pub fn toString(self: Backoff) []const u8 {
        return switch (self) {
            .constant => "constant",
            .linear => "linear",
            .exponential => "exponential",
        };
    }
};

pub const StepEvent = struct {
    payload: []const u8,
    timestamp: f64,
    event_type: []const u8,
};

fn buildStepConfigJson(allocator: std.mem.Allocator, config: StepConfig) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(allocator);
    const writer = &w.writer;
    writer.writeAll("{") catch return error.JsonSerializationFailed;
    var has_field = false;

    if (config.retries) |r| {
        writer.writeAll("\"retries\":{\"limit\":") catch return error.JsonSerializationFailed;
        writer.print("{d}", .{r.limit}) catch return error.JsonSerializationFailed;
        writer.writeAll(",\"delay\":\"") catch return error.JsonSerializationFailed;
        writer.writeAll(r.delay) catch return error.JsonSerializationFailed;
        writer.writeAll("\",\"backoff\":\"") catch return error.JsonSerializationFailed;
        writer.writeAll(r.backoff.toString()) catch return error.JsonSerializationFailed;
        writer.writeAll("\"}") catch return error.JsonSerializationFailed;
        has_field = true;
    }
    if (config.timeout) |t| {
        if (has_field) writer.writeAll(",") catch return error.JsonSerializationFailed;
        writer.writeAll("\"timeout\":\"") catch return error.JsonSerializationFailed;
        writer.writeAll(t) catch return error.JsonSerializationFailed;
        writer.writeAll("\"") catch return error.JsonSerializationFailed;
    }
    writer.writeAll("}") catch return error.JsonSerializationFailed;
    return w.toOwnedSlice() catch return error.OutOfMemory;
}

fn parseStepEvent(allocator: std.mem.Allocator, json: []const u8) !StepEvent {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch {
        return error.InvalidEventJson;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    var event_payload: []const u8 = "null";
    if (obj.get("payload")) |p| {
        if (p == .string) {
            event_payload = try allocator.dupe(u8, p.string);
        }
    }

    var event_type: []const u8 = "";
    if (obj.get("type")) |t| {
        if (t == .string) event_type = try allocator.dupe(u8, t.string);
    }

    var timestamp: f64 = 0;
    if (obj.get("timestamp")) |ts| {
        if (ts == .float) timestamp = ts.float;
        if (ts == .integer) timestamp = @floatFromInt(ts.integer);
    }

    return StepEvent{
        .payload = event_payload,
        .timestamp = timestamp,
        .event_type = event_type,
    };
}

// ===========================================================================
// Unit tests
// ===========================================================================

test "StepConfig JSON — empty" {
    const out = try buildStepConfigJson(std.testing.allocator, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{}", out);
}

test "StepConfig JSON — retries only" {
    const out = try buildStepConfigJson(std.testing.allocator, .{
        .retries = .{ .limit = 5, .delay = "10 seconds", .backoff = .linear },
    });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        "{\"retries\":{\"limit\":5,\"delay\":\"10 seconds\",\"backoff\":\"linear\"}}",
        out,
    );
}

test "StepConfig JSON — timeout only" {
    const out = try buildStepConfigJson(std.testing.allocator, .{
        .timeout = "2 minutes",
    });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        "{\"timeout\":\"2 minutes\"}",
        out,
    );
}

test "StepConfig JSON — full" {
    const out = try buildStepConfigJson(std.testing.allocator, .{
        .retries = .{ .limit = 3, .delay = "1 second", .backoff = .exponential },
        .timeout = "30 seconds",
    });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        "{\"retries\":{\"limit\":3,\"delay\":\"1 second\",\"backoff\":\"exponential\"},\"timeout\":\"30 seconds\"}",
        out,
    );
}

test "Status.fromString" {
    try std.testing.expectEqual(Status.queued, Status.fromString("queued"));
    try std.testing.expectEqual(Status.running, Status.fromString("running"));
    try std.testing.expectEqual(Status.waiting_for_pause, Status.fromString("waitingForPause"));
    try std.testing.expectEqual(Status.unknown, Status.fromString("garbage"));
}

test "parseInstanceStatus — complete with string output" {
    const json = "{\"status\":\"complete\",\"output\":\"done\"}";
    const s = try parseInstanceStatus(std.testing.allocator, json);
    defer {
        if (s.output) |o| std.testing.allocator.free(o);
    }
    try std.testing.expectEqual(Status.complete, s.status);
    try std.testing.expect(s.output != null);
    try std.testing.expectEqualStrings("done", s.output.?);
}

test "parseInstanceStatus — errored" {
    const json = "{\"status\":\"errored\",\"error\":{\"name\":\"Error\",\"message\":\"something broke\"}}";
    const s = try parseInstanceStatus(std.testing.allocator, json);
    defer {
        if (s.error_name) |n| std.testing.allocator.free(n);
        if (s.error_message) |m| std.testing.allocator.free(m);
    }
    try std.testing.expectEqual(Status.errored, s.status);
    try std.testing.expectEqualStrings("Error", s.error_name.?);
    try std.testing.expectEqualStrings("something broke", s.error_message.?);
}
