/// Build tool: parses a compiled Wasm binary's export section to find Durable
/// Object classes (exports matching `do_<Name>_fetch`) and generates the
/// entry.js wrapper with the correct DO class exports.
const std = @import("std");
const wasm = std.wasm;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var arg_iter = init.minimal.args.iterate();
    _ = arg_iter.next(); // skip program name
    const wasm_path = arg_iter.next() orelse {
        std.debug.print("usage: gen_entry <input.wasm> <output.js>\n", .{});
        std.process.exit(1);
    };
    const out_path = arg_iter.next() orelse {
        std.debug.print("usage: gen_entry <input.wasm> <output.js>\n", .{});
        std.process.exit(1);
    };

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, wasm_path, alloc, .limited(50 * 1024 * 1024));
    defer alloc.free(bytes);

    const class_names = try findDOClassesFromWasm(alloc, bytes);
    defer {
        for (class_names) |n| alloc.free(n);
        alloc.free(class_names);
    }

    const wf_names = try findWorkflowClassesFromWasm(alloc, bytes);
    defer {
        for (wf_names) |n| alloc.free(n);
        alloc.free(wf_names);
    }

    // Generate entry.js
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);

    try out.appendSlice(alloc,
        \\/**
        \\ * Auto-generated entry point. Do not edit.
        \\ * Re-exports the default handler and Durable Object/Workflow classes from shim.js.
        \\ */
        \\
    );

    if (class_names.len > 0 or wf_names.len > 0) {
        // Build import statement with needed factories
        try out.appendSlice(alloc, "import _module, { ");
        var needs_comma = false;
        if (class_names.len > 0) {
            try out.appendSlice(alloc, "_makeDOClass");
            needs_comma = true;
        }
        if (wf_names.len > 0) {
            if (needs_comma) try out.appendSlice(alloc, ", ");
            try out.appendSlice(alloc, "_makeWorkflowClass");
        }
        try out.appendSlice(alloc, " } from \"./shim.js\";\n\n");

        for (class_names) |name| {
            try out.appendSlice(alloc, "export const ");
            try out.appendSlice(alloc, name);
            try out.appendSlice(alloc, " = _makeDOClass(\"");
            try out.appendSlice(alloc, name);
            try out.appendSlice(alloc, "\");\n");
        }
        for (wf_names) |name| {
            try out.appendSlice(alloc, "export const ");
            try out.appendSlice(alloc, name);
            try out.appendSlice(alloc, " = _makeWorkflowClass(\"");
            try out.appendSlice(alloc, name);
            try out.appendSlice(alloc, "\");\n");
        }
    } else {
        try out.appendSlice(alloc, "import _module from \"./shim.js\";\n");
    }
    try out.appendSlice(alloc, "\nexport default _module;\n");

    const dirname = std.fs.path.dirname(out_path);
    if (dirname) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out.items });
}

/// Parse the Wasm binary's export section and collect DO class names.
/// Looks for exported functions matching `do_<Name>_fetch` and extracts <Name>.
fn findDOClassesFromWasm(alloc: std.mem.Allocator, bytes: []const u8) ![][]const u8 {
    // Validate magic + version header.
    if (bytes.len < 8) return error.InvalidWasm;
    if (!std.mem.eql(u8, bytes[0..4], &wasm.magic)) return error.InvalidWasm;
    if (!std.mem.eql(u8, bytes[4..8], &wasm.version)) return error.InvalidWasm;

    var pos: usize = 8;

    // Walk sections until we find the export section.
    while (pos < bytes.len) {
        const section_id = bytes[pos];
        pos += 1;
        const section_len = try readU32Leb128(bytes, &pos);
        const section_end = pos + section_len;

        if (section_id == @intFromEnum(wasm.Section.@"export")) {
            return try parseExportSection(alloc, bytes, pos, section_end);
        }

        // Skip to next section.
        pos = section_end;
    }

    // No export section found — no DO classes.
    return try alloc.alloc([]const u8, 0);
}

fn parseExportSection(alloc: std.mem.Allocator, bytes: []const u8, start: usize, end: usize) ![][]const u8 {
    var pos = start;
    const num_exports = try readU32Leb128(bytes, &pos);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }

    const prefix = "do_";
    const suffix = "_fetch";

    for (0..num_exports) |_| {
        const name_len = try readU32Leb128(bytes, &pos);
        if (pos + name_len > end) return error.InvalidWasm;
        const name = bytes[pos..][0..name_len];
        pos += name_len;

        // kind (1 byte) + index (LEB128)
        pos += 1; // skip kind
        _ = try readU32Leb128(bytes, &pos); // skip index

        // Check for do_<Name>_fetch pattern.
        if (name.len > prefix.len + suffix.len and
            std.mem.startsWith(u8, name, prefix) and
            std.mem.endsWith(u8, name, suffix))
        {
            const class_name = name[prefix.len .. name.len - suffix.len];
            try names.append(alloc, try alloc.dupe(u8, class_name));
        }
    }

    return try names.toOwnedSlice(alloc);
}

/// Parse the Wasm binary's export section and collect Workflow class names.
/// Looks for exported functions matching `wf_<Name>_run` and extracts <Name>.
fn findWorkflowClassesFromWasm(alloc: std.mem.Allocator, bytes: []const u8) ![][]const u8 {
    if (bytes.len < 8) return error.InvalidWasm;
    if (!std.mem.eql(u8, bytes[0..4], &wasm.magic)) return error.InvalidWasm;
    if (!std.mem.eql(u8, bytes[4..8], &wasm.version)) return error.InvalidWasm;

    var pos: usize = 8;
    while (pos < bytes.len) {
        const section_id = bytes[pos];
        pos += 1;
        const section_len = try readU32Leb128(bytes, &pos);
        const section_end = pos + section_len;

        if (section_id == @intFromEnum(wasm.Section.@"export")) {
            return try parseWorkflowExportSection(alloc, bytes, pos, section_end);
        }
        pos = section_end;
    }
    return try alloc.alloc([]const u8, 0);
}

fn parseWorkflowExportSection(alloc: std.mem.Allocator, bytes: []const u8, start: usize, end: usize) ![][]const u8 {
    var pos = start;
    const num_exports = try readU32Leb128(bytes, &pos);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }

    const prefix = "wf_";
    const suffix = "_run";

    for (0..num_exports) |_| {
        const name_len = try readU32Leb128(bytes, &pos);
        if (pos + name_len > end) return error.InvalidWasm;
        const name = bytes[pos..][0..name_len];
        pos += name_len;
        pos += 1; // skip kind
        _ = try readU32Leb128(bytes, &pos); // skip index

        if (name.len > prefix.len + suffix.len and
            std.mem.startsWith(u8, name, prefix) and
            std.mem.endsWith(u8, name, suffix))
        {
            const class_name = name[prefix.len .. name.len - suffix.len];
            try names.append(alloc, try alloc.dupe(u8, class_name));
        }
    }
    return try names.toOwnedSlice(alloc);
}

/// Decode an unsigned LEB128-encoded u32 from `bytes` at `pos`, advancing `pos`.
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
