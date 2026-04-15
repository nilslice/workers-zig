const std = @import("std");
const http = std.http;
const js = @import("js.zig");

pub const Method = http.Method;

handle: js.Handle,
allocator: std.mem.Allocator,

const Request = @This();

pub fn init(handle: js.Handle, allocator: std.mem.Allocator) Request {
    return .{ .handle = handle, .allocator = allocator };
}

/// HTTP method of the incoming request.
pub fn method(self: *const Request) Method {
    return @enumFromInt(js.request_method(self.handle));
}

/// Full URL of the incoming request (allocated from the arena).
pub fn url(self: *const Request) ![]const u8 {
    const str_handle = js.request_url(self.handle);
    return js.readString(str_handle, self.allocator);
}

/// Get a request header by name. Returns null if the header is absent.
pub fn header(self: *const Request, name: []const u8) !?[]const u8 {
    const str_handle = js.request_header(self.handle, name.ptr, @intCast(name.len));
    if (str_handle == js.null_handle) return null;
    return js.readString(str_handle, self.allocator);
}

/// Read the full request body. Returns null for bodyless requests.
pub fn body(self: *const Request) !?[]const u8 {
    const len = js.request_body_len(self.handle);
    if (len == 0) return null;
    const buf = try self.allocator.alloc(u8, len);
    js.request_body_read(self.handle, buf.ptr);
    return buf;
}

/// Cloudflare-specific request properties (geolocation, network, TLS, etc.).
/// Available on all plans. Returns null if not present (e.g. in local dev).
///
/// ```zig
/// if (try request.cf()) |cf| {
///     workers.log("colo={s} country={s} asn={?d}", .{
///         cf.colo orelse "?", cf.country orelse "?", cf.asn,
///     });
/// }
/// ```
pub fn cf(self: *const Request) !?CfProperties {
    const h = js.request_cf(self.handle);
    if (h == js.null_handle) return null;
    const json = try js.readString(h, self.allocator);
    const parsed = std.json.parseFromSlice(CfProperties, self.allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;
    return parsed.value;
}

/// The raw JSON string of the `cf` object, for fields not covered by
/// `CfProperties` or for pass-through serialization.
pub fn cfJson(self: *const Request) !?[]const u8 {
    const h = js.request_cf(self.handle);
    if (h == js.null_handle) return null;
    const s = try js.readString(h, self.allocator);
    return s;
}

/// Cloudflare request properties. All fields are optional because
/// availability depends on the request context and Cloudflare plan.
pub const CfProperties = struct {
    // -- Network -------------------------------------------------------
    /// ASN of the incoming request (e.g. 395747).
    asn: ?u32 = null,
    /// Organization that owns the ASN (e.g. "Google Cloud").
    asOrganization: ?[]const u8 = null,

    // -- Geolocation ---------------------------------------------------
    /// Three-letter IATA airport code of the data center (e.g. "DFW").
    colo: ?[]const u8 = null,
    /// Two-letter country code (e.g. "US"). Same as CF-IPCountry header.
    country: ?[]const u8 = null,
    /// City name (e.g. "Austin").
    city: ?[]const u8 = null,
    /// Continent code (e.g. "NA").
    continent: ?[]const u8 = null,
    /// Latitude as a string (e.g. "30.27130").
    latitude: ?[]const u8 = null,
    /// Longitude as a string (e.g. "-97.74260").
    longitude: ?[]const u8 = null,
    /// Postal code (e.g. "78701").
    postalCode: ?[]const u8 = null,
    /// Metro code / DMA (e.g. "635").
    metroCode: ?[]const u8 = null,
    /// ISO 3166-2 region name (e.g. "Texas").
    region: ?[]const u8 = null,
    /// ISO 3166-2 region code (e.g. "TX").
    regionCode: ?[]const u8 = null,
    /// IANA timezone (e.g. "America/Chicago").
    timezone: ?[]const u8 = null,
    /// "1" if the country is in the EU.
    isEUCountry: ?[]const u8 = null,

    // -- Protocol / TLS ------------------------------------------------
    /// HTTP protocol version (e.g. "HTTP/2").
    httpProtocol: ?[]const u8 = null,
    /// TLS version (e.g. "TLSv1.3").
    tlsVersion: ?[]const u8 = null,
    /// TLS cipher suite (e.g. "AEAD-AES128-GCM-SHA256").
    tlsCipher: ?[]const u8 = null,

    // -- Client info ---------------------------------------------------
    /// Original Accept-Encoding before Cloudflare replacement.
    clientAcceptEncoding: ?[]const u8 = null,
    /// Smoothed RTT for QUIC (HTTP/3) connections, in ms.
    clientQuicRtt: ?f64 = null,
    /// Smoothed RTT for TCP (HTTP/1, HTTP/2) connections, in ms.
    clientTcpRtt: ?f64 = null,
    /// Browser-requested priority info string.
    requestPriority: ?[]const u8 = null,

    // -- TLS client details --------------------------------------------
    /// SHA-1 hash of the cipher suite sent by the client.
    tlsClientCiphersSha1: ?[]const u8 = null,
    /// SHA-1 hash of TLS client extensions (big-endian).
    tlsClientExtensionsSha1: ?[]const u8 = null,
    /// SHA-1 hash of TLS client extensions (little-endian).
    tlsClientExtensionsSha1Le: ?[]const u8 = null,
    /// Length of the client hello message.
    tlsClientHelloLength: ?[]const u8 = null,
    /// 32-byte random value from the TLS handshake.
    tlsClientRandom: ?[]const u8 = null,
};

/// A name-value pair from the headers iterator.
pub const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
};

/// Return all request headers as a slice of name-value pairs.
///
/// ```zig
/// const headers = try request.headers();
/// for (headers) |h| {
///     workers.log("{s}: {s}", .{ h.name, h.value });
/// }
/// ```
pub fn headers(self: *const Request) ![]const HeaderEntry {
    const h = js.request_headers_entries(self.handle);
    if (h == js.null_handle) return &.{};
    const raw = try js.readString(h, self.allocator);

    // Format: "name\0value\nname\0value\n..."
    // Count entries first.
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < raw.len) {
        if (raw[pos] == '\n') count += 1;
        pos += 1;
    }
    if (raw.len > 0 and raw[raw.len - 1] != '\n') count += 1;

    const entries = try self.allocator.alloc(HeaderEntry, count);
    var idx: usize = 0;
    var start: usize = 0;
    for (raw, 0..) |c, i| {
        if (c == '\n') {
            if (idx < count) {
                entries[idx] = parseHeaderEntry(raw[start..i]);
                idx += 1;
            }
            start = i + 1;
        }
    }
    if (start < raw.len and idx < count) {
        entries[idx] = parseHeaderEntry(raw[start..]);
        idx += 1;
    }
    return entries[0..idx];
}

fn parseHeaderEntry(entry: []const u8) HeaderEntry {
    // "name\0value"
    for (entry, 0..) |c, i| {
        if (c == 0) {
            return .{
                .name = entry[0..i],
                .value = entry[i + 1 ..],
            };
        }
    }
    return .{ .name = entry, .value = "" };
}

// ===========================================================================
// Unit tests
// ===========================================================================

test "parseHeaderEntry — name and value" {
    const e = parseHeaderEntry("content-type\x00application/json");
    try std.testing.expectEqualStrings("content-type", e.name);
    try std.testing.expectEqualStrings("application/json", e.value);
}

test "parseHeaderEntry — no separator returns name only" {
    const e = parseHeaderEntry("x-solo-header");
    try std.testing.expectEqualStrings("x-solo-header", e.name);
    try std.testing.expectEqualStrings("", e.value);
}

test "parseHeaderEntry — empty value" {
    const e = parseHeaderEntry("x-empty\x00");
    try std.testing.expectEqualStrings("x-empty", e.name);
    try std.testing.expectEqualStrings("", e.value);
}

test "parseHeaderEntry — value with null bytes" {
    // Only the first \0 is the separator
    const e = parseHeaderEntry("key\x00val\x00ue");
    try std.testing.expectEqualStrings("key", e.name);
    try std.testing.expectEqualStrings("val\x00ue", e.value);
}

test "parseHeaderEntry — empty input" {
    const e = parseHeaderEntry("");
    try std.testing.expectEqualStrings("", e.name);
    try std.testing.expectEqualStrings("", e.value);
}

test "CfProperties — parse full JSON" {
    const json =
        \\{"asn":395747,"asOrganization":"Google Cloud","colo":"DFW","country":"US","city":"Austin","continent":"NA","latitude":"30.27130","longitude":"-97.74260","postalCode":"78701","metroCode":"635","region":"Texas","regionCode":"TX","timezone":"America/Chicago","isEUCountry":"1","httpProtocol":"HTTP/2","tlsVersion":"TLSv1.3","tlsCipher":"AEAD-AES128-GCM-SHA256","clientAcceptEncoding":"gzip, deflate, br","clientQuicRtt":42.0,"clientTcpRtt":22.0,"requestPriority":"weight=192","tlsClientCiphersSha1":"abc","tlsClientExtensionsSha1":"def","tlsClientExtensionsSha1Le":"ghi","tlsClientHelloLength":"508","tlsClientRandom":"rand123"}
    ;
    const parsed = try std.json.parseFromSlice(CfProperties, std.testing.allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const props = parsed.value;

    try std.testing.expectEqual(@as(u32, 395747), props.asn.?);
    try std.testing.expectEqualStrings("Google Cloud", props.asOrganization.?);
    try std.testing.expectEqualStrings("DFW", props.colo.?);
    try std.testing.expectEqualStrings("US", props.country.?);
    try std.testing.expectEqualStrings("Austin", props.city.?);
    try std.testing.expectEqualStrings("NA", props.continent.?);
    try std.testing.expectEqualStrings("30.27130", props.latitude.?);
    try std.testing.expectEqualStrings("-97.74260", props.longitude.?);
    try std.testing.expectEqualStrings("78701", props.postalCode.?);
    try std.testing.expectEqualStrings("635", props.metroCode.?);
    try std.testing.expectEqualStrings("Texas", props.region.?);
    try std.testing.expectEqualStrings("TX", props.regionCode.?);
    try std.testing.expectEqualStrings("America/Chicago", props.timezone.?);
    try std.testing.expectEqualStrings("1", props.isEUCountry.?);
    try std.testing.expectEqualStrings("HTTP/2", props.httpProtocol.?);
    try std.testing.expectEqualStrings("TLSv1.3", props.tlsVersion.?);
    try std.testing.expectEqualStrings("AEAD-AES128-GCM-SHA256", props.tlsCipher.?);
    try std.testing.expectEqualStrings("gzip, deflate, br", props.clientAcceptEncoding.?);
    try std.testing.expectEqual(@as(f64, 42.0), props.clientQuicRtt.?);
    try std.testing.expectEqual(@as(f64, 22.0), props.clientTcpRtt.?);
    try std.testing.expectEqualStrings("weight=192", props.requestPriority.?);
    try std.testing.expectEqualStrings("abc", props.tlsClientCiphersSha1.?);
    try std.testing.expectEqualStrings("def", props.tlsClientExtensionsSha1.?);
    try std.testing.expectEqualStrings("ghi", props.tlsClientExtensionsSha1Le.?);
    try std.testing.expectEqualStrings("508", props.tlsClientHelloLength.?);
    try std.testing.expectEqualStrings("rand123", props.tlsClientRandom.?);
}

test "CfProperties — parse minimal JSON with unknown fields" {
    const json =
        \\{"colo":"LAX","unknownField":true,"anotherOne":[1,2,3]}
    ;
    const parsed = try std.json.parseFromSlice(CfProperties, std.testing.allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const props = parsed.value;

    try std.testing.expectEqualStrings("LAX", props.colo.?);
    try std.testing.expect(props.asn == null);
    try std.testing.expect(props.country == null);
    try std.testing.expect(props.city == null);
    try std.testing.expect(props.clientTcpRtt == null);
}

test "CfProperties — empty JSON object" {
    const json = "{}";
    const parsed = try std.json.parseFromSlice(CfProperties, std.testing.allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const props = parsed.value;

    try std.testing.expect(props.asn == null);
    try std.testing.expect(props.colo == null);
    try std.testing.expect(props.country == null);
}
