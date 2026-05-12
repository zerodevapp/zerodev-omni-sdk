//! Ethereum primitive types — thin wrappers over raw byte arrays that match
//! the surface area zigeth used to expose (struct with `.bytes`, `.fromHex`,
//! `.toHex`, `.isZero`, `.eql`, `.fromBytes`). Internally, the `.bytes` field
//! is interchangeable with zabi's `[20]u8` / `[32]u8` raw types.
//!
//! Keeping a wrapper here means the rest of the SDK doesn't need to change
//! when zabi alters its raw representation.

const std = @import("std");

/// Ethereum address (20 bytes).
pub const Address = struct {
    bytes: [20]u8,

    pub fn fromBytes(bytes: [20]u8) Address {
        return .{ .bytes = bytes };
    }

    pub fn fromHex(hex_str: []const u8) !Address {
        const stripped = if (hex_str.len >= 2 and hex_str[0] == '0' and (hex_str[1] == 'x' or hex_str[1] == 'X'))
            hex_str[2..]
        else
            hex_str;
        if (stripped.len != 40) return error.InvalidAddressLength;

        var out: Address = undefined;
        for (0..20) |i| {
            const hi = try hexNibble(stripped[i * 2]);
            const lo = try hexNibble(stripped[i * 2 + 1]);
            out.bytes[i] = (hi << 4) | lo;
        }
        return out;
    }

    /// Convert to 0x-prefixed lower-case hex. Caller frees.
    pub fn toHex(self: Address, allocator: std.mem.Allocator) ![]u8 {
        return bytesToHex(allocator, &self.bytes);
    }

    pub fn isZero(self: Address) bool {
        return std.mem.eql(u8, &self.bytes, &[_]u8{0} ** 20);
    }

    pub fn eql(self: Address, other: Address) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

/// Ethereum hash (32 bytes — typically Keccak-256).
pub const Hash = struct {
    bytes: [32]u8,

    pub fn fromBytes(bytes: [32]u8) Hash {
        return .{ .bytes = bytes };
    }

    pub fn fromSlice(slice: []const u8) !Hash {
        if (slice.len != 32) return error.InvalidHashLength;
        var out: Hash = undefined;
        @memcpy(&out.bytes, slice);
        return out;
    }

    pub fn fromHex(hex_str: []const u8) !Hash {
        const stripped = if (hex_str.len >= 2 and hex_str[0] == '0' and (hex_str[1] == 'x' or hex_str[1] == 'X'))
            hex_str[2..]
        else
            hex_str;
        if (stripped.len != 64) return error.InvalidHashLength;

        var out: Hash = undefined;
        for (0..32) |i| {
            const hi = try hexNibble(stripped[i * 2]);
            const lo = try hexNibble(stripped[i * 2 + 1]);
            out.bytes[i] = (hi << 4) | lo;
        }
        return out;
    }

    /// Convert to 0x-prefixed lower-case hex. Caller frees.
    pub fn toHex(self: Hash, allocator: std.mem.Allocator) ![]u8 {
        return bytesToHex(allocator, &self.bytes);
    }

    pub fn isZero(self: Hash) bool {
        return std.mem.eql(u8, &self.bytes, &[_]u8{0} ** 32);
    }

    pub fn eql(self: Hash, other: Hash) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    pub fn zero() Hash {
        return .{ .bytes = [_]u8{0} ** 32 };
    }
};

/// secp256k1 signature in (r, s, v) form — v is the Ethereum-style recovery byte
/// (typically 27 or 28, or 0/1 in some contexts).
pub const Signature = struct {
    r: [32]u8,
    s: [32]u8,
    v: u8,
};

// ---- Hex utilities (allocator-owning, 0x-prefixed) ----

/// Convert bytes to 0x-prefixed lower-case hex. Caller frees.
pub fn bytesToHex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const hex_chars = "0123456789abcdef";
    const out = try allocator.alloc(u8, 2 + bytes.len * 2);
    out[0] = '0';
    out[1] = 'x';
    for (bytes, 0..) |b, i| {
        out[2 + i * 2] = hex_chars[b >> 4];
        out[2 + i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return out;
}

/// Convert (optionally 0x-prefixed) hex string to bytes. Caller frees.
pub fn hexToBytes(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    const stripped = if (hex_str.len >= 2 and hex_str[0] == '0' and (hex_str[1] == 'x' or hex_str[1] == 'X'))
        hex_str[2..]
    else
        hex_str;
    if (stripped.len % 2 != 0) return error.InvalidHexLength;

    const out = try allocator.alloc(u8, stripped.len / 2);
    errdefer allocator.free(out);
    for (0..out.len) |i| {
        const hi = try hexNibble(stripped[i * 2]);
        const lo = try hexNibble(stripped[i * 2 + 1]);
        out[i] = (hi << 4) | lo;
    }
    return out;
}

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHexCharacter,
    };
}

// ---- Tests ----

test "Address round-trip via fromHex/toHex" {
    const allocator = std.testing.allocator;
    const a = try Address.fromHex("0xd6CEDDe84be40893d153Be9d467CD6aD37875b28");
    const h = try a.toHex(allocator);
    defer allocator.free(h);
    try std.testing.expectEqualStrings("0xd6cedde84be40893d153be9d467cd6ad37875b28", h);
}

test "Address.isZero" {
    const zero = Address.fromBytes([_]u8{0} ** 20);
    try std.testing.expect(zero.isZero());
    var ones: [20]u8 = undefined;
    @memset(&ones, 1);
    try std.testing.expect(!Address.fromBytes(ones).isZero());
}

test "Hash round-trip" {
    const allocator = std.testing.allocator;
    const hex_in = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";
    const h = try Hash.fromHex(hex_in);
    const hex_out = try h.toHex(allocator);
    defer allocator.free(hex_out);
    try std.testing.expectEqualStrings(hex_in, hex_out);
}

test "Hash.eql" {
    const a = Hash.fromBytes([_]u8{1} ** 32);
    const b = Hash.fromBytes([_]u8{1} ** 32);
    const c = Hash.fromBytes([_]u8{2} ** 32);
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "bytesToHex / hexToBytes round-trip" {
    const allocator = std.testing.allocator;
    const bytes = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    const hex = try bytesToHex(allocator, &bytes);
    defer allocator.free(hex);
    try std.testing.expectEqualStrings("0xdeadbeef", hex);

    const back = try hexToBytes(allocator, hex);
    defer allocator.free(back);
    try std.testing.expectEqualSlices(u8, &bytes, back);
}

test "hexToBytes without 0x prefix" {
    const allocator = std.testing.allocator;
    const back = try hexToBytes(allocator, "deadbeef");
    defer allocator.free(back);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xde, 0xad, 0xbe, 0xef }, back);
}
