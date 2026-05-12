//! Keccak-256 (the pre-NIST Keccak that Ethereum uses, NOT SHA-3).
//!
//! Thin wrapper around `std.crypto.hash.sha3.Keccak256` that produces our
//! `Hash` struct (matching the zigeth surface the rest of the SDK relies on).

const std = @import("std");
const primitives = @import("primitives");
const Hash = primitives.Hash;

pub const Keccak256 = std.crypto.hash.sha3.Keccak256;

/// Hash a byte slice with Keccak-256 and return our Hash wrapper.
pub fn hash(data: []const u8) Hash {
    var out: [32]u8 = undefined;
    Keccak256.hash(data, &out, .{});
    return Hash.fromBytes(out);
}

/// Hash a byte slice and return raw 32 bytes (skip the wrapper).
pub fn hashBytes(data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    Keccak256.hash(data, &out, .{});
    return out;
}

/// Compute an Ethereum function selector: first 4 bytes of keccak256(signature).
pub fn functionSelector(signature: []const u8) [4]u8 {
    const h = hashBytes(signature);
    return h[0..4].*;
}

test "keccak256 of empty string" {
    const allocator = std.testing.allocator;
    const h = hash("");
    const expected = try Hash.fromHex("0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470");
    try std.testing.expect(h.eql(expected));
    _ = allocator;
}

test "functionSelector matches transfer(address,uint256) = 0xa9059cbb" {
    const sel = functionSelector("transfer(address,uint256)");
    try std.testing.expectEqual(@as(u8, 0xa9), sel[0]);
    try std.testing.expectEqual(@as(u8, 0x05), sel[1]);
    try std.testing.expectEqual(@as(u8, 0x9c), sel[2]);
    try std.testing.expectEqual(@as(u8, 0xbb), sel[3]);
}
