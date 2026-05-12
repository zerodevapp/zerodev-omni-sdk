//! HTTP POST with proper gzip decompression and chunked transfer support.

const std = @import("std");
const http = std.http;

/// Perform an HTTP POST and return the decompressed response body.
pub fn post(allocator: std.mem.Allocator, url: []const u8, payload: []const u8) ![]u8 {
    const uri = try std.Uri.parse(url);

    // Zig 0.16 requires an `Io` instance to be passed to the HTTP client for
    // opening TCP connections. Use the single-threaded global Threaded Io.
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

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
