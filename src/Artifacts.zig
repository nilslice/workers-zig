const std = @import("std");
const js = @import("js.zig");
const Fetch = @import("Fetch.zig");

// ===========================================================================
// Artifacts — durable Git repos on demand.
// ===========================================================================

handle: js.Handle,
allocator: std.mem.Allocator,

const Artifacts = @This();

pub fn init(handle: js.Handle, allocator: std.mem.Allocator) Artifacts {
    return .{ .handle = handle, .allocator = allocator };
}

// ---- Namespace-level operations -------------------------------------------

pub const CreateOptions = struct {
    read_only: ?bool = null,
    description: ?[]const u8 = null,
    set_default_branch: ?[]const u8 = null,
};

pub const CreateResult = struct {
    name: []const u8,
    remote: []const u8,
    token: ?[]const u8,
    expires_at: ?[]const u8,
    default_branch: ?[]const u8,
    repo: Repo,
};

/// Create a new repo in this namespace.
pub fn create(self: *const Artifacts, name: []const u8, options: CreateOptions) !CreateResult {
    const opts_json = try buildCreateOptionsJson(self.allocator, options);
    const h = js.artifacts_create(
        self.handle,
        name.ptr,
        @intCast(name.len),
        opts_json.ptr,
        @intCast(opts_json.len),
    );
    if (h == js.null_handle) return error.ArtifactsCreateFailed;
    const json_str = try js.readString(h, self.allocator);
    return parseCreateResult(self.allocator, json_str);
}

/// Get a repo handle by name. Returns null if the repo does not exist.
pub fn get(self: *const Artifacts, name: []const u8) !?Repo {
    const h = js.artifacts_get(self.handle, name.ptr, @intCast(name.len));
    if (h == js.null_handle) return null;
    return Repo{ .handle = h, .allocator = self.allocator };
}

pub const ListOptions = struct {
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
};

/// List repos in this namespace. Returns a JSON string with repos array and cursor.
pub fn list(self: *const Artifacts, options: ListOptions) ![]const u8 {
    const opts_json = try buildListOptionsJson(self.allocator, options);
    const h = js.artifacts_list(self.handle, opts_json.ptr, @intCast(opts_json.len));
    if (h == js.null_handle) return error.ArtifactsListFailed;
    return js.readString(h, self.allocator);
}

/// Delete a repo by name. Returns true if the repo was deleted.
pub fn delete(self: *const Artifacts, name: []const u8) bool {
    return js.artifacts_delete(self.handle, name.ptr, @intCast(name.len)) != 0;
}

pub const ImportOptions = struct {
    url: []const u8,
    branch: ?[]const u8 = null,
    depth: ?u32 = null,
    read_only: ?bool = null,
};

/// Import a public HTTPS remote into this namespace via the REST API.
/// Requires a Cloudflare API token with Artifacts > Edit permission.
/// Returns the raw JSON response body on success.
pub fn importRepo(self: *const Artifacts, name: []const u8, api_token: []const u8, options: ImportOptions) ![]const u8 {
    const allocator = self.allocator;

    // Build the REST API URL
    var url_buf = std.Io.Writer.Allocating.init(allocator);
    url_buf.writer.writeAll("https://artifacts.cloudflare.net/v1/api/namespaces/default/repos/") catch return error.OutOfMemory;
    url_buf.writer.writeAll(name) catch return error.OutOfMemory;
    url_buf.writer.writeAll("/import") catch return error.OutOfMemory;
    const api_url = url_buf.toOwnedSlice() catch return error.OutOfMemory;

    // Build the request body JSON
    var w = std.Io.Writer.Allocating.init(allocator);
    const writer = &w.writer;
    writer.writeAll("{\"url\":\"") catch return error.JsonSerializationFailed;
    writer.writeAll(options.url) catch return error.JsonSerializationFailed;
    writer.writeAll("\"") catch return error.JsonSerializationFailed;
    if (options.branch) |branch| {
        writer.writeAll(",\"branch\":\"") catch return error.JsonSerializationFailed;
        writer.writeAll(branch) catch return error.JsonSerializationFailed;
        writer.writeAll("\"") catch return error.JsonSerializationFailed;
    }
    if (options.depth) |depth| {
        writer.writeAll(",\"depth\":") catch return error.JsonSerializationFailed;
        writer.print("{d}", .{depth}) catch return error.JsonSerializationFailed;
    }
    if (options.read_only) |ro| {
        writer.writeAll(if (ro) ",\"read_only\":true" else ",\"read_only\":false") catch return error.JsonSerializationFailed;
    }
    writer.writeAll("}") catch return error.JsonSerializationFailed;
    const body = w.toOwnedSlice() catch return error.OutOfMemory;

    // Build auth header value
    var auth_buf = std.Io.Writer.Allocating.init(allocator);
    auth_buf.writer.writeAll("Bearer ") catch return error.OutOfMemory;
    auth_buf.writer.writeAll(api_token) catch return error.OutOfMemory;
    const auth_value = auth_buf.toOwnedSlice() catch return error.OutOfMemory;

    var resp = try Fetch.send(allocator, api_url, .{
        .method = .POST,
        .headers = &.{
            .{ .name = "Authorization", .value = auth_value },
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .body = .{ .bytes = body },
    });
    defer resp.deinit();

    return try resp.text();
}

// ---- Repo — handle to a specific repo ------------------------------------

pub const Repo = struct {
    handle: js.Handle,
    allocator: std.mem.Allocator,

    /// Get repo metadata including remote URL. Returns JSON string, or null.
    pub fn info(self: *const Repo) !?[]const u8 {
        const h = js.artifacts_repo_info(self.handle);
        if (h == js.null_handle) return null;
        const str = try js.readString(h, self.allocator);
        return str;
    }

    pub const TokenScope = enum {
        read,
        write,

        pub fn toString(self: TokenScope) []const u8 {
            return switch (self) {
                .read => "read",
                .write => "write",
            };
        }
    };

    /// Create a scoped token for this repo. Returns JSON with id, plaintext, scope, expiresAt.
    pub fn createToken(self: *const Repo, scope: TokenScope, ttl: u32) ![]const u8 {
        const scope_str = scope.toString();
        const h = js.artifacts_repo_create_token(
            self.handle,
            scope_str.ptr,
            @intCast(scope_str.len),
            ttl,
        );
        if (h == js.null_handle) return error.ArtifactsTokenCreateFailed;
        return js.readString(h, self.allocator);
    }

    /// Validate a token against this repo. Returns JSON with validation result.
    pub fn validateToken(self: *const Repo, token: []const u8) ![]const u8 {
        const h = js.artifacts_repo_validate_token(self.handle, token.ptr, @intCast(token.len));
        if (h == js.null_handle) return error.ArtifactsTokenValidateFailed;
        return js.readString(h, self.allocator);
    }

    /// List tokens for this repo. Returns JSON string with total and tokens array.
    pub fn listTokens(self: *const Repo) ![]const u8 {
        const h = js.artifacts_repo_list_tokens(self.handle);
        if (h == js.null_handle) return error.ArtifactsTokenListFailed;
        return js.readString(h, self.allocator);
    }

    /// Revoke a token by token string or ID. Returns true if revoked.
    pub fn revokeToken(self: *const Repo, token_or_id: []const u8) bool {
        return js.artifacts_repo_revoke_token(self.handle, token_or_id.ptr, @intCast(token_or_id.len)) != 0;
    }

    pub const ForkOptions = struct {
        description: ?[]const u8 = null,
        read_only: ?bool = null,
        default_branch_only: ?bool = null,
    };

    /// Fork this repo into a new repo. Returns JSON with name, remote, token, expiresAt.
    pub fn fork(self: *const Repo, name: []const u8, options: ForkOptions) ![]const u8 {
        const opts_json = try buildForkOptionsJson(self.allocator, options);
        const h = js.artifacts_repo_fork(
            self.handle,
            name.ptr,
            @intCast(name.len),
            opts_json.ptr,
            @intCast(opts_json.len),
        );
        if (h == js.null_handle) return error.ArtifactsForkFailed;
        return js.readString(h, self.allocator);
    }
};

// ---- Internal JSON builders -----------------------------------------------

fn buildCreateOptionsJson(allocator: std.mem.Allocator, opts: CreateOptions) ![]const u8 {
    if (opts.read_only == null and opts.description == null and opts.set_default_branch == null) {
        return "";
    }
    var w = std.Io.Writer.Allocating.init(allocator);
    const writer = &w.writer;
    writer.writeAll("{") catch return error.JsonSerializationFailed;
    var has_field = false;
    if (opts.description) |d| {
        writer.writeAll("\"description\":\"") catch return error.JsonSerializationFailed;
        writer.writeAll(d) catch return error.JsonSerializationFailed;
        writer.writeAll("\"") catch return error.JsonSerializationFailed;
        has_field = true;
    }
    if (opts.read_only) |ro| {
        if (has_field) writer.writeAll(",") catch return error.JsonSerializationFailed;
        writer.writeAll(if (ro) "\"readOnly\":true" else "\"readOnly\":false") catch return error.JsonSerializationFailed;
        has_field = true;
    }
    if (opts.set_default_branch) |branch| {
        if (has_field) writer.writeAll(",") catch return error.JsonSerializationFailed;
        writer.writeAll("\"setDefaultBranch\":\"") catch return error.JsonSerializationFailed;
        writer.writeAll(branch) catch return error.JsonSerializationFailed;
        writer.writeAll("\"") catch return error.JsonSerializationFailed;
    }
    writer.writeAll("}") catch return error.JsonSerializationFailed;
    return w.toOwnedSlice() catch return error.OutOfMemory;
}

fn buildListOptionsJson(allocator: std.mem.Allocator, opts: ListOptions) ![]const u8 {
    if (opts.limit == null and opts.cursor == null) {
        return "";
    }
    var w = std.Io.Writer.Allocating.init(allocator);
    const writer = &w.writer;
    writer.writeAll("{") catch return error.JsonSerializationFailed;
    var has_field = false;
    if (opts.limit) |l| {
        writer.writeAll("\"limit\":") catch return error.JsonSerializationFailed;
        writer.print("{d}", .{l}) catch return error.JsonSerializationFailed;
        has_field = true;
    }
    if (opts.cursor) |c| {
        if (has_field) writer.writeAll(",") catch return error.JsonSerializationFailed;
        writer.writeAll("\"cursor\":\"") catch return error.JsonSerializationFailed;
        writer.writeAll(c) catch return error.JsonSerializationFailed;
        writer.writeAll("\"") catch return error.JsonSerializationFailed;
    }
    writer.writeAll("}") catch return error.JsonSerializationFailed;
    return w.toOwnedSlice() catch return error.OutOfMemory;
}

fn buildForkOptionsJson(allocator: std.mem.Allocator, opts: Repo.ForkOptions) ![]const u8 {
    if (opts.description == null and opts.read_only == null and opts.default_branch_only == null) {
        return "";
    }
    var w = std.Io.Writer.Allocating.init(allocator);
    const writer = &w.writer;
    writer.writeAll("{") catch return error.JsonSerializationFailed;
    var has_field = false;
    if (opts.description) |d| {
        writer.writeAll("\"description\":\"") catch return error.JsonSerializationFailed;
        writer.writeAll(d) catch return error.JsonSerializationFailed;
        writer.writeAll("\"") catch return error.JsonSerializationFailed;
        has_field = true;
    }
    if (opts.read_only) |ro| {
        if (has_field) writer.writeAll(",") catch return error.JsonSerializationFailed;
        writer.writeAll(if (ro) "\"readOnly\":true" else "\"readOnly\":false") catch return error.JsonSerializationFailed;
        has_field = true;
    }
    if (opts.default_branch_only) |dbo| {
        if (has_field) writer.writeAll(",") catch return error.JsonSerializationFailed;
        writer.writeAll(if (dbo) "\"defaultBranchOnly\":true" else "\"defaultBranchOnly\":false") catch return error.JsonSerializationFailed;
    }
    writer.writeAll("}") catch return error.JsonSerializationFailed;
    return w.toOwnedSlice() catch return error.OutOfMemory;
}

fn parseCreateResult(allocator: std.mem.Allocator, json: []const u8) !CreateResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch {
        return error.InvalidJson;
    };
    defer parsed.deinit();
    const obj = parsed.value.object;

    const name_val = if (obj.get("name")) |v| switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => "",
    } else "";
    const remote_val = if (obj.get("remote")) |v| switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => "",
    } else "";
    const token_val: ?[]const u8 = if (obj.get("token")) |v| switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    } else null;
    const expires_val: ?[]const u8 = if (obj.get("expiresAt")) |v| switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    } else null;
    const branch_val: ?[]const u8 = if (obj.get("defaultBranch")) |v| switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    } else null;

    var repo_handle: js.Handle = js.null_handle;
    if (obj.get("repoHandle")) |rh| {
        switch (rh) {
            .integer => |i| repo_handle = @intCast(i),
            else => {},
        }
    }

    return .{
        .name = name_val,
        .remote = remote_val,
        .token = token_val,
        .expires_at = expires_val,
        .default_branch = branch_val,
        .repo = .{ .handle = repo_handle, .allocator = allocator },
    };
}
