const std = @import("std");
const js = @import("js.zig");

// ===========================================================================
// Web Crypto API — hashing, HMAC, sign/verify, encrypt/decrypt.
// ===========================================================================

/// Hash algorithm for digest and HMAC operations.
pub const Algorithm = enum(u32) {
    sha1 = 0,
    sha256 = 1,
    sha384 = 2,
    sha512 = 3,
    md5 = 4,
};

/// Compute a cryptographic hash digest.
/// JSPI-suspending.
///
/// ```zig
/// const hash = try Crypto.digest(allocator, .sha256, "hello world");
/// ```
pub fn digest(allocator: std.mem.Allocator, algorithm: Algorithm, data: []const u8) ![]const u8 {
    const h = js.crypto_digest(@intFromEnum(algorithm), data.ptr, @intCast(data.len));
    return js.readBytes(h, allocator);
}

/// Compute an HMAC signature.
/// JSPI-suspending.
///
/// ```zig
/// const sig = try Crypto.hmac(allocator, .sha256, "secret-key", "message");
/// ```
pub fn hmac(allocator: std.mem.Allocator, algorithm: Algorithm, key: []const u8, data: []const u8) ![]const u8 {
    const h = js.crypto_hmac(
        @intFromEnum(algorithm),
        key.ptr,
        @intCast(key.len),
        data.ptr,
        @intCast(data.len),
    );
    return js.readBytes(h, allocator);
}

/// Verify an HMAC signature. Returns true if the signature matches.
/// JSPI-suspending.
pub fn hmacVerify(algorithm: Algorithm, key: []const u8, signature: []const u8, data: []const u8) bool {
    return js.crypto_hmac_verify(
        @intFromEnum(algorithm),
        key.ptr,
        @intCast(key.len),
        signature.ptr,
        @intCast(signature.len),
        data.ptr,
        @intCast(data.len),
    ) != 0;
}

/// Timing-safe comparison of two byte slices.
/// Non-suspending.
pub fn timingSafeEqual(a: []const u8, b: []const u8) bool {
    return js.crypto_timing_safe_equal(
        a.ptr,
        @intCast(a.len),
        b.ptr,
        @intCast(b.len),
    ) != 0;
}

/// Convert bytes to a hex string.
pub fn toHex(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const hex_chars = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return out;
}

// ---- Unit tests -----------------------------------------------------------

test "toHex — empty" {
    const result = try toHex(std.testing.allocator, "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "toHex — known value" {
    const result = try toHex(std.testing.allocator, &[_]u8{ 0xde, 0xad, 0xbe, 0xef });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("deadbeef", result);
}

test "toHex — all zeros" {
    const result = try toHex(std.testing.allocator, &[_]u8{ 0x00, 0x00, 0x01 });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("000001", result);
}

test "Algorithm enum values" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(Algorithm.sha1));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(Algorithm.sha256));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(Algorithm.sha384));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(Algorithm.sha512));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(Algorithm.md5));
}
