/// Build tool: merges a WebAssembly Tool Conventions `producers` custom section
/// into a wasm binary. If the binary already contains a producers section the
/// entries are merged (existing field/name pairs are preserved and new ones are
/// appended). If no section exists one is appended at the end.
///
/// Usage:
///   inject_producers <input.wasm> <output.wasm> <field> <name> <version>...
///
/// Each triple of positional arguments after the two paths adds one entry.
/// Recognised field names: language, processed-by, sdk.
///
/// Example (adds sdk field for workers-zig):
///   inject_producers worker.wasm out.wasm sdk workers-zig 0.1.0
const std = @import("std");

const Entry = struct {
    field: []const u8,
    name: []const u8,
    version: []const u8,
};

const SectionBounds = struct {
    start: usize, // index of section id byte
    end: usize, // index after last byte of section
    content_start: usize, // index after "producers" name string
    content_end: usize,
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var arg_iter = init.minimal.args.iterate();
    _ = arg_iter.next(); // skip program name

    const in_path = arg_iter.next() orelse fatal(
        "usage: inject_producers <input.wasm> <output.wasm> <field> <name> <version>...\n",
        .{},
    );
    const out_path = arg_iter.next() orelse fatal(
        "usage: inject_producers <input.wasm> <output.wasm> <field> <name> <version>...\n",
        .{},
    );

    var new_entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer new_entries.deinit(alloc);

    while (true) {
        const field = arg_iter.next() orelse break;
        const name = arg_iter.next() orelse fatal("missing name for field '{s}'\n", .{field});
        const version = arg_iter.next() orelse fatal(
            "missing version for field '{s}' name '{s}'\n",
            .{ field, name },
        );
        try new_entries.append(alloc, .{ .field = field, .name = name, .version = version });
    }

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, in_path, alloc, .limited(50 * 1024 * 1024));
    defer alloc.free(bytes);

    if (bytes.len < 8) fatal("invalid wasm: too short\n", .{});
    if (!std.mem.eql(u8, bytes[0..4], &std.wasm.magic)) fatal("invalid wasm: bad magic\n", .{});
    if (!std.mem.eql(u8, bytes[4..8], &std.wasm.version)) fatal("invalid wasm: bad version\n", .{});

    const existing = try findProducersSection(bytes);

    // Collect all entries (existing + new).
    var merged: std.ArrayListUnmanaged(Entry) = .empty;
    defer merged.deinit(alloc);

    if (existing) |e| {
        try parseProducers(alloc, bytes, e.content_start, e.content_end, &merged);
    }

    for (new_entries.items) |new| {
        var dup = false;
        for (merged.items) |m| {
            if (std.mem.eql(u8, m.field, new.field) and std.mem.eql(u8, m.name, new.name)) {
                dup = true;
                break;
            }
        }
        if (!dup) try merged.append(alloc, new);
    }

    // Passthrough if nothing to write.
    if (merged.items.len == 0) {
        const dirname = std.fs.path.dirname(out_path);
        if (dirname) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = bytes });
        return;
    }

    // Build producers payload.
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(alloc);

    try appendU32Leb128(&payload, alloc, @intCast("producers".len));
    try payload.appendSlice(alloc, "producers");

    // Group by field name.
    var fields: std.ArrayListUnmanaged([]const u8) = .empty;
    defer fields.deinit(alloc);
    for (merged.items) |e| {
        var seen = false;
        for (fields.items) |f| {
            if (std.mem.eql(u8, f, e.field)) {
                seen = true;
                break;
            }
        }
        if (!seen) try fields.append(alloc, e.field);
    }

    try appendU32Leb128(&payload, alloc, @intCast(fields.items.len));

    for (fields.items) |field| {
        try appendU32Leb128(&payload, alloc, @intCast(field.len));
        try payload.appendSlice(alloc, field);

        var value_count: u32 = 0;
        for (merged.items) |e| {
            if (std.mem.eql(u8, e.field, field)) value_count += 1;
        }
        try appendU32Leb128(&payload, alloc, value_count);

        for (merged.items) |e| {
            if (!std.mem.eql(u8, e.field, field)) continue;
            try appendU32Leb128(&payload, alloc, @intCast(e.name.len));
            try payload.appendSlice(alloc, e.name);
            try appendU32Leb128(&payload, alloc, @intCast(e.version.len));
            try payload.appendSlice(alloc, e.version);
        }
    }

    // Reconstruct wasm: everything before old section, everything after old section, then new section.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try out.ensureTotalCapacityPrecise(alloc, bytes.len + payload.items.len + 16);

    if (existing) |e| {
        try out.appendSlice(alloc, bytes[0..e.start]);
        try out.appendSlice(alloc, bytes[e.end..]);
    } else {
        try out.appendSlice(alloc, bytes);
    }

    try out.append(alloc, 0); // custom section id
    try appendU32Leb128(&out, alloc, @intCast(payload.items.len));
    try out.appendSlice(alloc, payload.items);

    const dirname = std.fs.path.dirname(out_path);
    if (dirname) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out.items });
}

/// Scan existing custom sections and return bounds of the `producers` section.
fn findProducersSection(bytes: []const u8) !?SectionBounds {
    var pos: usize = 8;
    while (pos < bytes.len) {
        const section_id = bytes[pos];
        const section_start = pos;
        pos += 1;
        const section_len = try readU32Leb128(bytes, &pos);
        const section_end = pos + section_len;

        if (section_id == 0) {
            const name_len = try readU32Leb128(bytes, &pos);
            const name = bytes[pos..][0..name_len];
            pos += name_len;
            if (std.mem.eql(u8, name, "producers")) {
                return SectionBounds{
                    .start = section_start,
                    .end = section_end,
                    .content_start = pos,
                    .content_end = section_end,
                };
            }
        }

        pos = section_end;
    }
    return null;
}

fn parseProducers(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    content_start: usize,
    content_end: usize,
    out: *std.ArrayListUnmanaged(Entry),
) !void {
    var pos = content_start;
    const field_count = try readU32Leb128(bytes, &pos);
    for (0..field_count) |_| {
        const field_len = try readU32Leb128(bytes, &pos);
        const field = bytes[pos..][0..field_len];
        pos += field_len;

        const value_count = try readU32Leb128(bytes, &pos);
        for (0..value_count) |_| {
            const name_len = try readU32Leb128(bytes, &pos);
            const name = bytes[pos..][0..name_len];
            pos += name_len;

            const version_len = try readU32Leb128(bytes, &pos);
            const version = bytes[pos..][0..version_len];
            pos += version_len;

            try out.append(alloc, .{ .field = field, .name = name, .version = version });
        }
    }
    if (pos != content_end) return error.InvalidWasm;
}

fn readU32Leb128(bytes: []const u8, pos: *usize) !u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        if (pos.* >= bytes.len) return error.InvalidWasm;
        const byte = bytes[pos.*];
        pos.* += 1;
        result |= @as(u32, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) break;
        shift = std.math.add(u5, shift, 7) catch return error.Overflow;
    }
    return result;
}

fn appendU32Leb128(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, value: u32) !void {
    var v = value;
    while (true) {
        const byte: u8 = @truncate(v & 0x7f);
        v >>= 7;
        if (v != 0) {
            try list.append(alloc, byte | 0x80);
        } else {
            try list.append(alloc, byte);
            break;
        }
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}
