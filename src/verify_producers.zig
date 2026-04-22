/// CI helper: verifies that a wasm binary contains a `producers` section with
/// an `sdk` field naming `workers-zig`.
///
/// Usage:
///   verify_producers <wasm-path> [--sdk-name <name>] [--sdk-version <version>]
///
/// Defaults checked:
///   sdk-name = "workers-zig"
///   sdk-version = any non-empty string
const std = @import("std");

const Entry = struct {
    field: []const u8,
    name: []const u8,
    version: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var arg_iter = init.minimal.args.iterate();
    _ = arg_iter.next(); // skip program name

    const wasm_path = arg_iter.next() orelse fatal(
        "usage: verify_producers <wasm-path> [--sdk-name <name>] [--sdk-version <version>]\n",
        .{},
    );

    var expected_sdk_name: []const u8 = "workers-zig";
    var expected_sdk_version: ?[]const u8 = null;

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--sdk-name")) {
            expected_sdk_name = arg_iter.next() orelse fatal("missing value for --sdk-name\n", .{});
        } else if (std.mem.eql(u8, arg, "--sdk-version")) {
            expected_sdk_version = arg_iter.next() orelse fatal("missing value for --sdk-version\n", .{});
        } else {
            fatal("unknown argument: {s}\n", .{arg});
        }
    }

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, wasm_path, alloc, .limited(50 * 1024 * 1024));
    defer alloc.free(bytes);

    if (bytes.len < 8) fatal("invalid wasm: too short\n", .{});
    if (!std.mem.eql(u8, bytes[0..4], &std.wasm.magic)) fatal("invalid wasm: bad magic\n", .{});
    if (!std.mem.eql(u8, bytes[4..8], &std.wasm.version)) fatal("invalid wasm: bad version\n", .{});

    const section_bounds = try findProducersSection(bytes) orelse fatal(
        "FAIL: no 'producers' custom section found in {s}\n",
        .{wasm_path},
    );

    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer entries.deinit(alloc);
    try parseProducers(alloc, bytes, section_bounds.content_start, section_bounds.content_end, &entries);

    var found_sdk = false;
    for (entries.items) |e| {
        if (std.mem.eql(u8, e.field, "sdk") and std.mem.eql(u8, e.name, expected_sdk_name)) {
            found_sdk = true;
            if (expected_sdk_version) |ver| {
                if (!std.mem.eql(u8, e.version, ver)) {
                    fatal("FAIL: sdk version mismatch: expected '{s}', got '{s}'\n", .{ ver, e.version });
                }
            } else if (e.version.len == 0) {
                fatal("FAIL: sdk version is empty\n", .{});
            }
            std.log.info("OK: found sdk = {s} {s}\n", .{ e.name, e.version });
            break;
        }
    }

    if (!found_sdk) {
        fatal("FAIL: no sdk '{s}' found in producers section\n", .{expected_sdk_name});
    }
}

const SectionBounds = struct {
    content_start: usize,
    content_end: usize,
};

fn findProducersSection(bytes: []const u8) !?SectionBounds {
    var pos: usize = 8;
    while (pos < bytes.len) {
        const section_id = bytes[pos];
        pos += 1;
        const section_len = try readU32Leb128(bytes, &pos);
        const section_end = pos + section_len;

        if (section_id == 0) {
            const name_len = try readU32Leb128(bytes, &pos);
            const name = bytes[pos..][0..name_len];
            pos += name_len;
            if (std.mem.eql(u8, name, "producers")) {
                return SectionBounds{
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

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}
