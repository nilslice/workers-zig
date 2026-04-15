const std = @import("std");
const js = @import("js.zig");

// ===========================================================================
// Tail / Trace — Cloudflare Tail Workers API.
//
// A tail worker receives trace data from other workers. Define a
// `pub fn tail(events: []Tail.TraceItem, env: *Env) void` in your
// worker module to handle tail events.
//
// Each TraceItem contains logs, exceptions, outcome, timing, and
// event-specific info (fetch request/response, scheduled cron, etc.).
// ===========================================================================

const Tail = @This();

// ===========================================================================
// TraceItem — one invocation's trace data
// ===========================================================================

pub const TraceItem = struct {
    script_name: ?[]const u8 = null,
    entrypoint: ?[]const u8 = null,
    outcome: []const u8 = "unknown",
    execution_model: ?[]const u8 = null,
    event_timestamp: ?f64 = null,
    cpu_time: f64 = 0,
    wall_time: f64 = 0,
    truncated: bool = false,
    dispatch_namespace: ?[]const u8 = null,
    durable_object_id: ?[]const u8 = null,
    logs: []TraceLog = &.{},
    exceptions: []TraceException = &.{},
    event: ?EventInfo = null,
};

pub const TraceLog = struct {
    timestamp: f64 = 0,
    level: []const u8 = "log",
    message: []const u8 = "",
};

pub const TraceException = struct {
    timestamp: f64 = 0,
    name: []const u8 = "",
    message: []const u8 = "",
};

pub const EventInfo = union(enum) {
    fetch: FetchEventInfo,
    scheduled: ScheduledEventInfo,
    alarm: AlarmEventInfo,
    queue: QueueEventInfo,
    email: EmailEventInfo,
    tail: TailEventInfo,
    custom: void,
    unknown: void,
};

pub const FetchEventInfo = struct {
    method: []const u8 = "GET",
    url: []const u8 = "",
    status: ?u16 = null,
};

pub const ScheduledEventInfo = struct {
    cron: []const u8 = "",
    scheduled_time: f64 = 0,
};

pub const AlarmEventInfo = struct {
    scheduled_time: f64 = 0,
};

pub const QueueEventInfo = struct {
    queue: []const u8 = "",
    batch_size: u32 = 0,
};

pub const EmailEventInfo = struct {
    mail_from: []const u8 = "",
    rcpt_to: []const u8 = "",
};

pub const TailEventInfo = struct {
    consumed_count: u32 = 0,
};

// ===========================================================================
// Parsing — TraceItem[] from a JS handle containing JSON
// ===========================================================================

/// Parse trace items from a JS handle containing the JSON-serialized array.
pub fn parseTraceItems(handle: js.Handle, allocator: std.mem.Allocator) ![]TraceItem {
    const json = try js.readString(handle, allocator);
    defer allocator.free(json);
    return parseTraceItemsFromJson(allocator, json);
}

fn parseTraceItemsFromJson(allocator: std.mem.Allocator, json: []const u8) ![]TraceItem {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch {
        return try allocator.alloc(TraceItem, 0);
    };
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return try allocator.alloc(TraceItem, 0),
    };

    var items = try allocator.alloc(TraceItem, arr.items.len);
    for (arr.items, 0..) |val, i| {
        items[i] = parseOneTraceItem(allocator, val) catch TraceItem{};
    }
    return items;
}

fn parseOneTraceItem(allocator: std.mem.Allocator, val: std.json.Value) !TraceItem {
    if (val != .object) return TraceItem{};
    const obj = val.object;

    var item = TraceItem{};

    if (obj.get("scriptName")) |v| {
        if (v == .string) item.script_name = try allocator.dupe(u8, v.string);
    }
    if (obj.get("entrypoint")) |v| {
        if (v == .string) item.entrypoint = try allocator.dupe(u8, v.string);
    }
    if (obj.get("outcome")) |v| {
        if (v == .string) item.outcome = try allocator.dupe(u8, v.string);
    }
    if (obj.get("executionModel")) |v| {
        if (v == .string) item.execution_model = try allocator.dupe(u8, v.string);
    }
    if (obj.get("eventTimestamp")) |v| {
        item.event_timestamp = jsonFloat(v);
    }
    if (obj.get("cpuTime")) |v| {
        item.cpu_time = jsonFloat(v) orelse 0;
    }
    if (obj.get("wallTime")) |v| {
        item.wall_time = jsonFloat(v) orelse 0;
    }
    if (obj.get("truncated")) |v| {
        if (v == .bool) item.truncated = v.bool;
    }
    if (obj.get("dispatchNamespace")) |v| {
        if (v == .string) item.dispatch_namespace = try allocator.dupe(u8, v.string);
    }
    if (obj.get("durableObjectId")) |v| {
        if (v == .string) item.durable_object_id = try allocator.dupe(u8, v.string);
    }

    // Parse logs
    if (obj.get("logs")) |v| {
        if (v == .array) {
            var logs = try allocator.alloc(TraceLog, v.array.items.len);
            for (v.array.items, 0..) |log_val, li| {
                logs[li] = parseTraceLog(allocator, log_val) catch TraceLog{};
            }
            item.logs = logs;
        }
    }

    // Parse exceptions
    if (obj.get("exceptions")) |v| {
        if (v == .array) {
            var exceptions = try allocator.alloc(TraceException, v.array.items.len);
            for (v.array.items, 0..) |exc_val, ei| {
                exceptions[ei] = parseTraceException(allocator, exc_val) catch TraceException{};
            }
            item.exceptions = exceptions;
        }
    }

    // Parse event info
    if (obj.get("event")) |v| {
        item.event = parseEventInfo(allocator, v) catch null;
    }

    return item;
}

fn parseTraceLog(allocator: std.mem.Allocator, val: std.json.Value) !TraceLog {
    if (val != .object) return TraceLog{};
    const obj = val.object;
    var log = TraceLog{};
    if (obj.get("timestamp")) |v| log.timestamp = jsonFloat(v) orelse 0;
    if (obj.get("level")) |v| {
        if (v == .string) log.level = try allocator.dupe(u8, v.string);
    }
    if (obj.get("message")) |v| {
        if (v == .string) {
            log.message = try allocator.dupe(u8, v.string);
        } else if (v == .array) {
            // console.log with multiple args — join as JSON array
            log.message = try allocator.dupe(u8, "[multi-arg]");
        }
    }
    return log;
}

fn parseTraceException(allocator: std.mem.Allocator, val: std.json.Value) !TraceException {
    if (val != .object) return TraceException{};
    const obj = val.object;
    var exc = TraceException{};
    if (obj.get("timestamp")) |v| exc.timestamp = jsonFloat(v) orelse 0;
    if (obj.get("name")) |v| {
        if (v == .string) exc.name = try allocator.dupe(u8, v.string);
    }
    if (obj.get("message")) |v| {
        if (v == .string) exc.message = try allocator.dupe(u8, v.string);
    }
    return exc;
}

fn parseEventInfo(allocator: std.mem.Allocator, val: std.json.Value) !EventInfo {
    if (val != .object) return EventInfo{ .unknown = {} };
    const obj = val.object;

    // Detect event type by checking for characteristic fields.
    // Fetch events have "request"
    if (obj.get("request")) |req_val| {
        var info = FetchEventInfo{};
        if (req_val == .object) {
            if (req_val.object.get("method")) |v| {
                if (v == .string) info.method = try allocator.dupe(u8, v.string);
            }
            if (req_val.object.get("url")) |v| {
                if (v == .string) info.url = try allocator.dupe(u8, v.string);
            }
        }
        if (obj.get("response")) |resp_val| {
            if (resp_val == .object) {
                if (resp_val.object.get("status")) |v| {
                    if (v == .integer) info.status = @intCast(v.integer);
                }
            }
        }
        return EventInfo{ .fetch = info };
    }

    // Scheduled events have "cron"
    if (obj.get("cron")) |cron_val| {
        var info = ScheduledEventInfo{};
        if (cron_val == .string) info.cron = try allocator.dupe(u8, cron_val.string);
        if (obj.get("scheduledTime")) |v| info.scheduled_time = jsonFloat(v) orelse 0;
        return EventInfo{ .scheduled = info };
    }

    // Alarm events have "scheduledTime" but no "cron"
    if (obj.get("scheduledTime")) |v| {
        return EventInfo{ .alarm = .{ .scheduled_time = jsonFloat(v) orelse 0 } };
    }

    // Queue events have "queue"
    if (obj.get("queue")) |queue_val| {
        var info = QueueEventInfo{};
        if (queue_val == .string) info.queue = try allocator.dupe(u8, queue_val.string);
        if (obj.get("batchSize")) |v| {
            if (v == .integer) info.batch_size = @intCast(v.integer);
        }
        return EventInfo{ .queue = info };
    }

    // Email events have "mailFrom"
    if (obj.get("mailFrom")) |_| {
        var info = EmailEventInfo{};
        if (obj.get("mailFrom")) |v| {
            if (v == .string) info.mail_from = try allocator.dupe(u8, v.string);
        }
        if (obj.get("rcptTo")) |v| {
            if (v == .string) info.rcpt_to = try allocator.dupe(u8, v.string);
        }
        return EventInfo{ .email = info };
    }

    // Tail events have "consumedEvents"
    if (obj.get("consumedEvents")) |v| {
        var info = TailEventInfo{};
        if (v == .array) info.consumed_count = @intCast(v.array.items.len);
        return EventInfo{ .tail = info };
    }

    return EventInfo{ .unknown = {} };
}

fn jsonFloat(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => v.float,
        .integer => @floatFromInt(v.integer),
        else => null,
    };
}

// ===========================================================================
// Unit tests
// ===========================================================================

test "parse empty array" {
    const items = try parseTraceItemsFromJson(std.testing.allocator, "[]");
    defer std.testing.allocator.free(items);
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "parse single fetch trace item" {
    const json =
        \\[{
        \\  "scriptName": "my-worker",
        \\  "outcome": "ok",
        \\  "eventTimestamp": 1700000000000,
        \\  "cpuTime": 5,
        \\  "wallTime": 12,
        \\  "truncated": false,
        \\  "executionModel": "stateless",
        \\  "logs": [
        \\    {"timestamp": 1700000000001, "level": "log", "message": "hello"}
        \\  ],
        \\  "exceptions": [],
        \\  "event": {
        \\    "request": {"method": "GET", "url": "https://example.com/"},
        \\    "response": {"status": 200}
        \\  }
        \\}]
    ;
    const items = try parseTraceItemsFromJson(std.testing.allocator, json);
    defer {
        for (items) |item| {
            if (item.script_name) |s| std.testing.allocator.free(s);
            if (item.outcome.len > 0) std.testing.allocator.free(item.outcome);
            if (item.execution_model) |s| std.testing.allocator.free(s);
            for (item.logs) |log| {
                if (log.level.len > 0) std.testing.allocator.free(log.level);
                if (log.message.len > 0) std.testing.allocator.free(log.message);
            }
            std.testing.allocator.free(item.logs);
            std.testing.allocator.free(item.exceptions);
            if (item.event) |ev| {
                switch (ev) {
                    .fetch => |f| {
                        std.testing.allocator.free(f.method);
                        std.testing.allocator.free(f.url);
                    },
                    else => {},
                }
            }
        }
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 1), items.len);
    const t = items[0];
    try std.testing.expectEqualStrings("my-worker", t.script_name.?);
    try std.testing.expectEqualStrings("ok", t.outcome);
    try std.testing.expectEqual(@as(f64, 5), t.cpu_time);
    try std.testing.expectEqual(@as(f64, 12), t.wall_time);
    try std.testing.expectEqual(false, t.truncated);
    try std.testing.expectEqual(@as(usize, 1), t.logs.len);
    try std.testing.expectEqualStrings("hello", t.logs[0].message);
    try std.testing.expect(t.event != null);
    switch (t.event.?) {
        .fetch => |f| {
            try std.testing.expectEqualStrings("GET", f.method);
            try std.testing.expectEqualStrings("https://example.com/", f.url);
            try std.testing.expectEqual(@as(u16, 200), f.status.?);
        },
        else => return error.UnexpectedEventType,
    }
}

test "parse scheduled event" {
    const json =
        \\[{
        \\  "outcome": "ok",
        \\  "event": {"cron": "0 * * * *", "scheduledTime": 1700000000000}
        \\}]
    ;
    const items = try parseTraceItemsFromJson(std.testing.allocator, json);
    defer {
        for (items) |item| {
            std.testing.allocator.free(item.outcome);
            if (item.event) |ev| {
                switch (ev) {
                    .scheduled => |s| std.testing.allocator.free(s.cron),
                    else => {},
                }
            }
        }
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 1), items.len);
    switch (items[0].event.?) {
        .scheduled => |s| {
            try std.testing.expectEqualStrings("0 * * * *", s.cron);
        },
        else => return error.UnexpectedEventType,
    }
}
