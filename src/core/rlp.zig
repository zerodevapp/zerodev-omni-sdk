//! Minimal RLP encoder for EIP-7702 authorization tuples.
//!
//! Only supports what we need: lists of bytes/u64 values. No decoder.

const std = @import("std");

pub const Item = union(enum) {
    bytes: []const u8,
    uint: u64,
};

/// Encode an RLP list of items into a newly allocated buffer.
pub fn encodeList(allocator: std.mem.Allocator, items: []const Item) ![]u8 {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);

    for (items) |item| try encodeItem(allocator, &payload, item);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try writeListPrefix(allocator, &out, payload.items.len);
    try out.appendSlice(allocator, payload.items);
    return try out.toOwnedSlice(allocator);
}

fn encodeItem(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), item: Item) !void {
    switch (item) {
        .bytes => |b| try encodeBytes(allocator, buf, b),
        .uint => |u| {
            var tmp: [8]u8 = undefined;
            const minimal = uintMinimalBigEndian(u, &tmp);
            try encodeBytes(allocator, buf, minimal);
        },
    }
}

fn encodeBytes(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), data: []const u8) !void {
    if (data.len == 1 and data[0] < 0x80) {
        try buf.append(allocator, data[0]);
        return;
    }
    if (data.len <= 55) {
        try buf.append(allocator, 0x80 + @as(u8, @intCast(data.len)));
        try buf.appendSlice(allocator, data);
        return;
    }
    // Long string (unlikely for our usage, but handle it)
    var len_buf: [8]u8 = undefined;
    const len_bytes = uintMinimalBigEndian(@intCast(data.len), &len_buf);
    try buf.append(allocator, 0xb7 + @as(u8, @intCast(len_bytes.len)));
    try buf.appendSlice(allocator, len_bytes);
    try buf.appendSlice(allocator, data);
}

fn writeListPrefix(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), payload_len: usize) !void {
    if (payload_len <= 55) {
        try buf.append(allocator, 0xc0 + @as(u8, @intCast(payload_len)));
        return;
    }
    var len_buf: [8]u8 = undefined;
    const len_bytes = uintMinimalBigEndian(@intCast(payload_len), &len_buf);
    try buf.append(allocator, 0xf7 + @as(u8, @intCast(len_bytes.len)));
    try buf.appendSlice(allocator, len_bytes);
}

fn uintMinimalBigEndian(value: u64, out: *[8]u8) []const u8 {
    if (value == 0) return out[0..0];
    std.mem.writeInt(u64, out, value, .big);
    var i: usize = 0;
    while (i < 8 and out[i] == 0) : (i += 1) {}
    return out[i..];
}

// ---- Tests ----

test "rlp: empty bytes encodes to 0x80" {
    const allocator = std.testing.allocator;
    const items = [_]Item{.{ .bytes = &[_]u8{} }};
    const encoded = try encodeList(allocator, &items);
    defer allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xc1, 0x80 }, encoded);
}

test "rlp: single-byte value < 0x80 encoded as itself" {
    const allocator = std.testing.allocator;
    const items = [_]Item{.{ .uint = 1 }};
    const encoded = try encodeList(allocator, &items);
    defer allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xc1, 0x01 }, encoded);
}

test "rlp: uint zero encodes as 0x80" {
    const allocator = std.testing.allocator;
    const items = [_]Item{.{ .uint = 0 }};
    const encoded = try encodeList(allocator, &items);
    defer allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xc1, 0x80 }, encoded);
}

// Vectors derived from viem toRlp([chainId, address, nonce]).
fn parseHexBytes(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    const stripped = if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) hex[2..] else hex;
    const out = try allocator.alloc(u8, stripped.len / 2);
    for (0..out.len) |i| {
        const hi: u8 = switch (stripped[i * 2]) {
            '0'...'9' => stripped[i * 2] - '0',
            'a'...'f' => stripped[i * 2] - 'a' + 10,
            'A'...'F' => stripped[i * 2] - 'A' + 10,
            else => unreachable,
        };
        const lo: u8 = switch (stripped[i * 2 + 1]) {
            '0'...'9' => stripped[i * 2 + 1] - '0',
            'a'...'f' => stripped[i * 2 + 1] - 'a' + 10,
            'A'...'F' => stripped[i * 2 + 1] - 'A' + 10,
            else => unreachable,
        };
        out[i] = (hi << 4) | lo;
    }
    return out;
}

test "rlp: viem vector (sepolia, kernel v3.3, nonce=0)" {
    const allocator = std.testing.allocator;
    const addr_hex: []const u8 = "d6cedde84be40893d153be9d467cd6ad37875b28";
    const addr = try parseHexBytes(allocator, addr_hex);
    defer allocator.free(addr);
    const items = [_]Item{
        .{ .uint = 11155111 },
        .{ .bytes = addr },
        .{ .uint = 0 },
    };
    const encoded = try encodeList(allocator, &items);
    defer allocator.free(encoded);
    const expected = try parseHexBytes(allocator, "da83aa36a794d6cedde84be40893d153be9d467cd6ad37875b2880");
    defer allocator.free(expected);
    try std.testing.expectEqualSlices(u8, expected, encoded);
}

test "rlp: viem vector (chainId=1, zero address, nonce=0)" {
    const allocator = std.testing.allocator;
    var addr = [_]u8{0} ** 20;
    const items = [_]Item{
        .{ .uint = 1 },
        .{ .bytes = &addr },
        .{ .uint = 0 },
    };
    const encoded = try encodeList(allocator, &items);
    defer allocator.free(encoded);
    const expected = try parseHexBytes(allocator, "d70194000000000000000000000000000000000000000080");
    defer allocator.free(expected);
    try std.testing.expectEqualSlices(u8, expected, encoded);
}

test "rlp: viem vector (chainId=0)" {
    const allocator = std.testing.allocator;
    const addr = try parseHexBytes(allocator, "d6cedde84be40893d153be9d467cd6ad37875b28");
    defer allocator.free(addr);
    const items = [_]Item{
        .{ .uint = 0 },
        .{ .bytes = addr },
        .{ .uint = 0 },
    };
    const encoded = try encodeList(allocator, &items);
    defer allocator.free(encoded);
    const expected = try parseHexBytes(allocator, "d78094d6cedde84be40893d153be9d467cd6ad37875b2880");
    defer allocator.free(expected);
    try std.testing.expectEqualSlices(u8, expected, encoded);
}

test "rlp: viem vector (nonce=256, two-byte encoding)" {
    const allocator = std.testing.allocator;
    const addr = try parseHexBytes(allocator, "d6cedde84be40893d153be9d467cd6ad37875b28");
    defer allocator.free(addr);
    const items = [_]Item{
        .{ .uint = 1 },
        .{ .bytes = addr },
        .{ .uint = 256 },
    };
    const encoded = try encodeList(allocator, &items);
    defer allocator.free(encoded);
    const expected = try parseHexBytes(allocator, "d90194d6cedde84be40893d153be9d467cd6ad37875b28820100");
    defer allocator.free(expected);
    try std.testing.expectEqualSlices(u8, expected, encoded);
}

test "rlp: viem vector (base, nonce=65535)" {
    const allocator = std.testing.allocator;
    const addr = try parseHexBytes(allocator, "d6cedde84be40893d153be9d467cd6ad37875b28");
    defer allocator.free(addr);
    const items = [_]Item{
        .{ .uint = 8453 },
        .{ .bytes = addr },
        .{ .uint = 65535 },
    };
    const encoded = try encodeList(allocator, &items);
    defer allocator.free(encoded);
    const expected = try parseHexBytes(allocator, "db82210594d6cedde84be40893d153be9d467cd6ad37875b2882ffff");
    defer allocator.free(expected);
    try std.testing.expectEqualSlices(u8, expected, encoded);
}
