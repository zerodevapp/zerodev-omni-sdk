//! HTTP POST with proper gzip decompression and chunked transfer support.

const std = @import("std");
const builtin = @import("builtin");
const http = std.http;
const ca_bundle = @import("ca_bundle.zig");

/// Targets where a sandboxed app has no dependable system trust store: Apple
/// mobile (std's Bundle.rescan is a no-op there) and Android (the store exists
/// but may be relocated or unreadable from an app, e.g. Android 14+ moved it
/// into the Conscrypt APEX). Everywhere else the system store is authoritative
/// and the embedded bundle is never consulted.
const mobile_trust_store = switch (builtin.os.tag) {
    .ios, .tvos, .watchos, .visionos => true,
    else => builtin.abi.isAndroid(),
};

/// HTTP POST returning the decompressed body.
pub fn post(allocator: std.mem.Allocator, url: []const u8, payload: []const u8) ![]u8 {
    const uri = try std.Uri.parse(url);

    // Zig 0.16 requires an `Io` instance to be passed to the HTTP client for
    // opening TCP connections. Use the single-threaded global Threaded Io.
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    try prepareTrustStore(&client, allocator, io, mobile_trust_store);

    var req = try client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
        },
    });
    defer req.deinit();

    try req.sendBodyComplete(@constCast(payload));

    var redirect_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    var transfer_buf: [8192]u8 = undefined;
    var decompress: http.Decompress = undefined;
    const decompress_buf = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(decompress_buf);

    var reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);
    return try reader.allocRemaining(allocator, std.Io.Limit.limited(10 * 1024 * 1024));
}

/// Decide the trust store BEFORE connecting - never in response to a
/// handshake failure. Zig reports a rejected certificate chain with the same
/// TlsInitializationFailed as "no roots found", so a retry-on-failure would
/// re-trust, via the embedded Mozilla set, a root the system store had
/// deliberately excluded.
///
/// Desktop/server (`mobile` false): leave the client alone. request() scans
/// the system store exactly as it did before the embedded bundle existed.
///
/// Mobile: scan the system store first and keep it if it yields any roots.
/// Install the embedded roots only if the scan finds nothing (store absent,
/// or the no-op scan on Apple mobile) or cannot read the store at all - on
/// these targets the only alternative is no TLS.
fn prepareTrustStore(client: *http.Client, allocator: std.mem.Allocator, io: std.Io, mobile: bool) !void {
    if (!mobile) return;
    const now = std.Io.Clock.real.now(io);
    const have_system_roots = blk: {
        client.ca_bundle.rescan(allocator, io, now) catch |err| switch (err) {
            // Resource failures are not "no store": surface them.
            error.OutOfMemory, error.Canceled => return err,
            else => break :blk false,
        };
        break :blk client.ca_bundle.map.count() > 0;
    };
    try chooseTrustStore(client, allocator, io, now, have_system_roots);
}

/// Keep the system roots the scan found, or replace whatever it left behind
/// with the embedded bundle. Split from the scan so the fallback branch is
/// testable on a desktop host, where the scan never comes up empty.
fn chooseTrustStore(client: *http.Client, allocator: std.mem.Allocator, io: std.Io, now: std.Io.Timestamp, have_system_roots: bool) !void {
    if (have_system_roots) {
        // A set clock makes request() skip its own rescan.
        client.now = now;
        return;
    }
    // Drop anything a failed partial scan may have left so we do not union an
    // unknown subset of the system store with the Mozilla roots.
    client.ca_bundle.bytes.clearRetainingCapacity();
    client.ca_bundle.map.clearRetainingCapacity();
    try ca_bundle.install(client, allocator, io);
}

// -- Tests -------------------------------------------------------------------
// The mobile branch cannot be exercised end-to-end on a desktop host (the
// system scan here always finds roots), so these pin the three observable
// behaviours: non-mobile is untouched, mobile keeps a non-empty system store
// without adding embedded roots, and the embedded install itself works.

const testing = std.testing;

test "prepareTrustStore: non-mobile leaves the client to request()'s system scan" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var client = http.Client{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    try prepareTrustStore(&client, testing.allocator, io, false);
    try testing.expect(client.now == null);
    try testing.expectEqual(@as(usize, 0), client.ca_bundle.map.count());
}

test "prepareTrustStore: mobile keeps a system store that yields roots, adds nothing" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var client = http.Client{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    try prepareTrustStore(&client, testing.allocator, io, true);
    try testing.expect(client.now != null);
    try testing.expect(client.ca_bundle.map.count() > 0);

    // Must equal a plain system scan - i.e. the embedded roots were NOT added.
    var reference = http.Client{ .allocator = testing.allocator, .io = io };
    defer reference.deinit();
    try reference.ca_bundle.rescan(testing.allocator, io, std.Io.Clock.real.now(io));
    try testing.expectEqual(reference.ca_bundle.map.count(), client.ca_bundle.map.count());
}

test "embedded bundle installs the Mozilla roots into an empty client" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var client = http.Client{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    try ca_bundle.install(&client, testing.allocator, io);
    // 119 certificates in the 2026-07-16 bundle; allow for subject dedup.
    try testing.expect(client.ca_bundle.map.count() > 100);
    try testing.expect(client.now != null);
}

test "chooseTrustStore: an empty system scan installs the embedded roots" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var client = http.Client{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    try chooseTrustStore(&client, testing.allocator, io, std.Io.Clock.real.now(io), false);
    try testing.expect(client.ca_bundle.map.count() > 100);
    try testing.expect(client.now != null);
}

test "chooseTrustStore: the fallback replaces a partial scan rather than adding to it" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const now = std.Io.Clock.real.now(io);
    var embedded_only = http.Client{ .allocator = testing.allocator, .io = io };
    defer embedded_only.deinit();
    try ca_bundle.install(&embedded_only, testing.allocator, io);

    // A client whose store already holds the system roots stands in for a
    // partial scan; the fallback must end with exactly the embedded set.
    var client = http.Client{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    try client.ca_bundle.rescan(testing.allocator, io, now);
    try testing.expect(client.ca_bundle.map.count() > 0);
    try chooseTrustStore(&client, testing.allocator, io, now, false);
    try testing.expectEqual(embedded_only.ca_bundle.map.count(), client.ca_bundle.map.count());
}
