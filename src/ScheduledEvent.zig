const std = @import("std");
const js = @import("js.zig");

handle: js.Handle,
allocator: std.mem.Allocator,

const ScheduledEvent = @This();

pub fn init(handle: js.Handle, allocator: std.mem.Allocator) ScheduledEvent {
    return .{ .handle = handle, .allocator = allocator };
}

/// The cron pattern that triggered this event (e.g. "0 * * * *").
pub fn cron(self: *const ScheduledEvent) ![]const u8 {
    const h = js.scheduled_cron(self.handle);
    return js.readString(h, self.allocator);
}

/// The scheduled time as milliseconds since the Unix epoch.
pub fn scheduledTime(self: *const ScheduledEvent) f64 {
    return js.scheduled_time(self.handle);
}
