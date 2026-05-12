//! EIP-7702 Authorization tuple and hash.
//!
//! An authorization delegates an EOA's code to a contract via:
//!   keccak256(0x05 || rlp([chainId, address, nonce]))

const std = @import("std");
const keccak = @import("keccak.zig");

pub const MAGIC: u8 = 0x05;

/// EIP-7702 authorization tuple. Shape mirrors `signers.Authorization`; downstream
/// code that mixes signers + core treats them as structurally identical.
pub const Authorization = struct {
    chain_id: u64,
    address: [20]u8,
    nonce: u64,
    y_parity: u8,
    r: [32]u8,
    s: [32]u8,
};

/// Compute keccak256(0x05 || rlp([chainId, address, nonce])).
pub fn computeAuthHash(chain_id: u64, address: [20]u8, nonce: u64) [32]u8 {
    // Inline RLP encoding — max payload is 40 bytes (list prefix + 9-byte chainId + 21-byte
    // address-with-prefix + 9-byte nonce). Avoids heap allocation entirely.
    var rlp_out: [96]u8 = undefined;
    const rlp_len = encodeAuthRlp(chain_id, address, nonce, &rlp_out);

    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(&[_]u8{MAGIC});
    hasher.update(rlp_out[0..rlp_len]);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    _ = keccak;
    return out;
}

fn uintMinimalBE(value: u64, out: *[8]u8) []const u8 {
    if (value == 0) return out[0..0];
    std.mem.writeInt(u64, out, value, .big);
    var i: usize = 0;
    while (i < 8 and out[i] == 0) : (i += 1) {}
    return out[i..];
}

fn encodeAuthRlp(chain_id: u64, address: [20]u8, nonce: u64, out: *[96]u8) usize {
    var payload: [64]u8 = undefined;
    var p: usize = 0;

    var tmp: [8]u8 = undefined;
    const cid = uintMinimalBE(chain_id, &tmp);
    if (cid.len == 1 and cid[0] < 0x80) {
        payload[p] = cid[0];
        p += 1;
    } else {
        payload[p] = 0x80 + @as(u8, @intCast(cid.len));
        p += 1;
        @memcpy(payload[p .. p + cid.len], cid);
        p += cid.len;
    }

    // address is always 20 bytes, encoded as 0x94 || addr.
    payload[p] = 0x80 + 20;
    p += 1;
    @memcpy(payload[p .. p + 20], &address);
    p += 20;

    var tmp2: [8]u8 = undefined;
    const non = uintMinimalBE(nonce, &tmp2);
    if (non.len == 1 and non[0] < 0x80) {
        payload[p] = non[0];
        p += 1;
    } else {
        payload[p] = 0x80 + @as(u8, @intCast(non.len));
        p += 1;
        @memcpy(payload[p .. p + non.len], non);
        p += non.len;
    }

    // List prefix — payload is always <= 40 bytes.
    out[0] = 0xc0 + @as(u8, @intCast(p));
    @memcpy(out[1 .. 1 + p], payload[0..p]);
    return 1 + p;
}

// ---- Tests ----

fn hexToBytesSlice(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
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

fn hexToBytes20(hex: []const u8) [20]u8 {
    const stripped = if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) hex[2..] else hex;
    var out: [20]u8 = undefined;
    for (0..20) |i| {
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

fn hexToBytes32(hex: []const u8) [32]u8 {
    const stripped = if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) hex[2..] else hex;
    var out: [32]u8 = undefined;
    for (0..32) |i| {
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

test "computeAuthHash: sepolia + kernel v3.3 + nonce=0" {
    const addr = hexToBytes20("d6cedde84be40893d153be9d467cd6ad37875b28");
    const expected = hexToBytes32("43b260a4372240d4b9ceb89608803e35a47e43b8f3f93bc4a2d190a8cff2d9d1");
    const got = computeAuthHash(11155111, addr, 0);
    try std.testing.expectEqualSlices(u8, &expected, &got);
}

test "computeAuthHash: chainId=0" {
    const addr = hexToBytes20("d6cedde84be40893d153be9d467cd6ad37875b28");
    const expected = hexToBytes32("ad1d9e81db1399cc4003dacd2e43654b71007dc275c62d2f8c1912895f0da68d");
    const got = computeAuthHash(0, addr, 0);
    try std.testing.expectEqualSlices(u8, &expected, &got);
}

test "computeAuthHash: zero address" {
    const addr = [_]u8{0} ** 20;
    const expected = hexToBytes32("20aed0d1fcfcae79908c669252609bf10de3cc521c36d631c62eea3e826c79ad");
    const got = computeAuthHash(1, addr, 0);
    try std.testing.expectEqualSlices(u8, &expected, &got);
}

test "computeAuthHash: nonce=256" {
    const addr = hexToBytes20("d6cedde84be40893d153be9d467cd6ad37875b28");
    const expected = hexToBytes32("11bd02146353172effcdad57fa973856b87691ffedfca2ba4a4ba193d7ab129a");
    const got = computeAuthHash(1, addr, 256);
    try std.testing.expectEqualSlices(u8, &expected, &got);
}

test "computeAuthHash: base chain, large nonce" {
    const addr = hexToBytes20("d6cedde84be40893d153be9d467cd6ad37875b28");
    const expected = hexToBytes32("47e6b5a7a8162aa15abd82a04b12c48a2725cbe93a724e6c7b615a9883774311");
    const got = computeAuthHash(8453, addr, 65535);
    try std.testing.expectEqualSlices(u8, &expected, &got);
}

test "computeAuthHash: hash against viem sign vector (pk=0x11*32)" {
    // Signer from viem: pk=0x11*32 signing authorization (chain=sepolia, addr=kernel v3.3, nonce=7)
    // Expected authHash derived via viem `hashAuthorization`
    const addr = hexToBytes20("d6cedde84be40893d153be9d467cd6ad37875b28");
    const expected = hexToBytes32("c1c1b892c3fb784d758bc18a2e8ef8de246aee3c9503b3c7477cf4e3ad21e2d5");
    const got = computeAuthHash(11155111, addr, 7);
    try std.testing.expectEqualSlices(u8, &expected, &got);
}
