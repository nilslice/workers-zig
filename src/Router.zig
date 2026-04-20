const std = @import("std");
const Request = @import("Request.zig");
const Response = @import("Response.zig");
const Env = @import("Env.zig");
const Context = @import("Context.zig");

// ===========================================================================
// Router — path-based HTTP routing with param extraction.
//
// Works inside any handler that has a *Request.
//
// **Main fetch handler:**
// ```zig
// const Router = workers.Router;
//
// pub fn fetch(request: *Request, env: *Env, ctx: *Context) !Response {
//     return Router.serve(request, env, ctx, &.{
//         Router.get("/", handleIndex),
//         Router.get("/users/:id", handleGetUser),
//         Router.post("/users", handleCreateUser),
//         Router.get("/posts/:pid/comments/:cid", handleComment),
//     }) orelse Response.err(.not_found, "Not Found");
// }
//
// fn handleGetUser(req: *Request, env: *Env, ctx: *Context, params: *Router.Params) !Response {
//     const id = params.get("id").?;
//     return Response.ok(id);
// }
// ```
//
// **Durable Object fetch (low-level):**
// ```zig
// pub fn fetch(self: *MyDO, request: *Request) !Response {
//     const path = Router.extractPath(try request.url());
//     var params: Router.Params = .{};
//
//     if (Router.matchPath("/items/:id", path, &params))
//         return self.getItem(params.get("id").?);
//
//     return Response.err(.not_found, "Not Found");
// }
// ```
//
// **Middleware (comptime wrapper):**
// ```zig
// fn withAuth(comptime handler: Router.Handler) Router.Handler {
//     return struct {
//         fn wrapped(req: *Request, env: *Env, ctx: *Context, params: *Router.Params) !Response {
//             const token = try req.header("Authorization") orelse
//                 return Response.err(.unauthorized, "missing token");
//             _ = token;
//             return handler(req, env, ctx, params);
//         }
//     }.wrapped;
// }
//
// // Usage:
// Router.get("/admin/:id", withAuth(handleAdmin)),
// ```
// ===========================================================================

pub const MAX_PARAMS = 8;

pub const Handler = *const fn (*Request, *Env, *Context, *Params) anyerror!Response;

pub const Params = struct {
    entries: [MAX_PARAMS]Entry = undefined,
    len: u8 = 0,

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn get(self: *const Params, key: []const u8) ?[]const u8 {
        for (self.entries[0..self.len]) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }

    fn push(self: *Params, key: []const u8, value: []const u8) void {
        if (self.len < MAX_PARAMS) {
            self.entries[self.len] = .{ .key = key, .value = value };
            self.len += 1;
        }
    }

    fn reset(self: *Params) void {
        self.len = 0;
    }
};

pub const Route = struct {
    method: ?std.http.Method,
    pattern: []const u8,
    handler: Handler,
};

/// Match a request against a list of routes and call the first matching handler.
pub fn serve(request: *Request, env: *Env, ctx: *Context, comptime routes: []const Route) ?Response {
    const url_str = request.url() catch return null;
    const full_path = extractPath(url_str);
    // Strip query string
    const path = if (std.mem.indexOf(u8, full_path, "?")) |qi| full_path[0..qi] else full_path;
    const method = request.method();

    var params: Params = .{};

    inline for (routes) |route| {
        params.reset();
        const method_ok = if (route.method) |rm| rm == method else true;
        if (method_ok and matchPath(route.pattern, path, &params)) {
            const result = route.handler(request, env, ctx, &params);
            if (result) |resp| {
                return resp;
            } else |_| {
                return Response.err(.internal_server_error, "handler error");
            }
        }
    }

    return null;
}

/// Route constructors.
pub fn get(comptime pattern: []const u8, handler: Handler) Route {
    return .{ .method = .GET, .pattern = pattern, .handler = handler };
}

pub fn post(comptime pattern: []const u8, handler: Handler) Route {
    return .{ .method = .POST, .pattern = pattern, .handler = handler };
}

pub fn put(comptime pattern: []const u8, handler: Handler) Route {
    return .{ .method = .PUT, .pattern = pattern, .handler = handler };
}

pub fn delete(comptime pattern: []const u8, handler: Handler) Route {
    return .{ .method = .DELETE, .pattern = pattern, .handler = handler };
}

pub fn patch(comptime pattern: []const u8, handler: Handler) Route {
    return .{ .method = .PATCH, .pattern = pattern, .handler = handler };
}

pub fn head(comptime pattern: []const u8, handler: Handler) Route {
    return .{ .method = .HEAD, .pattern = pattern, .handler = handler };
}

pub fn all(comptime pattern: []const u8, handler: Handler) Route {
    return .{ .method = null, .pattern = pattern, .handler = handler };
}

/// Match a path against a pattern, extracting named parameters.
///
/// Pattern segments starting with `:` are params:
///   "/users/:id"       matches "/users/42"       → id="42"
///   "/posts/:pid/edit" matches "/posts/99/edit"   → pid="99"
///   "/:a/:b/:c"        matches "/x/y/z"           → a="x", b="y", c="z"
///
/// A trailing `*` matches any remaining path:
///   "/files/*"         matches "/files/a/b/c"
///
pub fn matchPath(pattern: []const u8, path: []const u8, params: *Params) bool {
    var pat_iter = splitSegments(pattern);
    var path_iter = splitSegments(path);

    while (true) {
        const pat_seg = pat_iter.next();
        const path_seg = path_iter.next();

        if (pat_seg == null and path_seg == null) return true;

        if (pat_seg) |ps| {
            // Wildcard — matches rest of path
            if (std.mem.eql(u8, ps, "*")) return true;

            if (path_seg == null) return false;

            if (ps.len > 0 and ps[0] == ':') {
                // Named param
                params.push(ps[1..], path_seg.?);
            } else {
                // Literal segment
                if (!std.mem.eql(u8, ps, path_seg.?)) return false;
            }
        } else {
            // Pattern exhausted but path has more segments
            return false;
        }
    }
}

/// Extract the path component from a full URL.
/// "https://example.com/foo/bar?q=1" → "/foo/bar?q=1"
pub fn extractPath(url: []const u8) []const u8 {
    if (std.mem.indexOf(u8, url, "://")) |i| {
        if (std.mem.indexOfPos(u8, url, i + 3, "/")) |j| {
            return url[j..];
        }
    }
    return "/";
}

fn splitSegments(path: []const u8) std.mem.SplitIterator(u8, .scalar) {
    // Skip leading slash
    const trimmed = if (path.len > 0 and path[0] == '/') path[1..] else path;
    return std.mem.splitScalar(u8, trimmed, '/');
}

// ===========================================================================
// Unit tests
// ===========================================================================

test "extractPath" {
    try std.testing.expectEqualStrings("/foo/bar", extractPath("https://example.com/foo/bar"));
    try std.testing.expectEqualStrings("/", extractPath("https://example.com/"));
    try std.testing.expectEqualStrings("/", extractPath("https://example.com"));
    try std.testing.expectEqualStrings("/a?q=1", extractPath("http://localhost:8787/a?q=1"));
}

test "matchPath — exact" {
    var p: Params = .{};
    try std.testing.expect(matchPath("/", "/", &p));
    try std.testing.expect(matchPath("/users", "/users", &p));
    try std.testing.expect(matchPath("/a/b/c", "/a/b/c", &p));
    try std.testing.expect(!matchPath("/a", "/b", &p));
    try std.testing.expect(!matchPath("/a/b", "/a", &p));
    try std.testing.expect(!matchPath("/a", "/a/b", &p));
}

test "matchPath — params" {
    var p: Params = .{};

    try std.testing.expect(matchPath("/users/:id", "/users/42", &p));
    try std.testing.expectEqualStrings("42", p.get("id").?);

    p.reset();
    try std.testing.expect(matchPath("/posts/:pid/comments/:cid", "/posts/10/comments/20", &p));
    try std.testing.expectEqualStrings("10", p.get("pid").?);
    try std.testing.expectEqualStrings("20", p.get("cid").?);

    p.reset();
    try std.testing.expect(!matchPath("/users/:id", "/users", &p));
    try std.testing.expect(!matchPath("/users/:id", "/users/42/extra", &p));
}

test "matchPath — wildcard" {
    var p: Params = .{};
    try std.testing.expect(matchPath("/files/*", "/files/a/b/c", &p));
    try std.testing.expect(matchPath("/files/*", "/files/x", &p));
    try std.testing.expect(matchPath("/*", "/anything/at/all", &p));
    try std.testing.expect(!matchPath("/files/*", "/other/a", &p));
}

test "matchPath — mixed params and literal" {
    var p: Params = .{};
    try std.testing.expect(matchPath("/api/:version/users/:id/profile", "/api/v2/users/abc/profile", &p));
    try std.testing.expectEqualStrings("v2", p.get("version").?);
    try std.testing.expectEqualStrings("abc", p.get("id").?);
}
