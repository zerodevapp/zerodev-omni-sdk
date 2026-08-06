//! HTTP POST with proper gzip decompression and chunked transfer support.

const std = @import("std");
const http = std.http;
const ca_bundle = @import("ca_bundle.zig");

/// Perform an HTTP POST and return the decompressed response body.
///
/// The trust store is the system's, except where the system store is empty
/// because it can't be scanned (iOS): there the embedded Mozilla roots are used
/// instead, on the first attempt, so no handshake is wasted. If a present but
/// incomplete system store rejects the server certificate, one retry with the
/// embedded roots covers that case too.
pub fn post(allocator: std.mem.Allocator, url: []const u8, payload: []const u8) ![]u8 {
    return postOnce(allocator, url, payload, .system) catch |err| switch (err) {
        error.TlsInitializationFailed,
        error.CertificateBundleLoadFailure,
        => try postOnce(allocator, url, payload, .embedded),
        else => err,
    };
}

const TrustStore = enum {
    /// System roots, falling back to the embedded roots when the system store
    /// is empty.
    system,
    /// The embedded Mozilla roots only.
    embedded,
};

fn postOnce(
    allocator: std.mem.Allocator,
    url: []const u8,
    payload: []const u8,
    trust: TrustStore,
) ![]u8 {
    const uri = try std.Uri.parse(url);

    // Zig 0.16 requires an `Io` instance to be passed to the HTTP client for
    // opening TCP connections. Use the single-threaded global Threaded Io.
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    if (!http.Client.disable_tls) {
        // Build the trust store here rather than letting request() scan the
        // system store lazily, so an empty system store (iOS) can fall back to
        // the embedded roots before the handshake instead of failing it.
        const now = std.Io.Clock.real.now(io);
        const now_sec = now.toSeconds();
        switch (trust) {
            .system => {
                client.ca_bundle.rescan(allocator, io, now) catch {};
                if (client.ca_bundle.map.count() == 0) {
                    try ca_bundle.addEmbedded(&client.ca_bundle, allocator, now_sec);
                }
            },
            .embedded => try ca_bundle.addEmbedded(&client.ca_bundle, allocator, now_sec),
        }
        // A set clock makes request() skip its own system rescan, which would
        // otherwise replace the bundle built above.
        client.now = now;
    }

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
