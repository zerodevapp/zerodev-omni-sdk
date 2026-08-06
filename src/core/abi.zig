//! Minimal Solidity ABI encoder for the parameter shapes the validators need.
//!
//! Supports static 32-byte words (uint256 / bool / bytes32 / left-padded
//! address), dynamic `bytes` / `string`, and arrays of static words
//! (`address[]` / `uintN[]`). It follows `abi.encode`: every parameter
//! contributes one 32-byte head — the value itself when static, or an offset
//! when dynamic — and dynamic parameters append their data as tails after all
//! heads, with offsets measured from the start of the encoded block.
//!
//! It is deliberately small: enough to encode validator enable-data and
//! signatures exactly as viem's `encodeAbiParameters` does (the encodings are
//! pinned to viem output in the tests), without a general type system.

const std = @import("std");

/// One top-level ABI parameter.
pub const Value = union(enum) {
    /// A static 32-byte word: uint256, bool, bytes32, or a left-padded address.
    word: [32]u8,
    /// Dynamic `bytes` or `string`: a length word then the right-padded data.
    dyn_bytes: []const u8,
    /// A dynamic array of static words (`address[]`, `uintN[]`): a length word
    /// then each element as its own 32-byte word.
    dyn_words: []const [32]u8,
};

/// uint256 (and any uintN, right-aligned) as a big-endian 32-byte word.
pub fn word256(v: u256) [32]u8 {
    return @bitCast(@byteSwap(v));
}

/// bool as a 32-byte word (0 or 1 in the last byte).
pub fn wordBool(b: bool) [32]u8 {
    var w = [_]u8{0} ** 32;
    w[31] = @intFromBool(b);
    return w;
}

/// A 20-byte address left-padded into a 32-byte word.
pub fn wordAddress(addr: [20]u8) [32]u8 {
    var w = [_]u8{0} ** 32;
    @memcpy(w[12..32], &addr);
    return w;
}

/// Round a byte length up to the next 32-byte boundary.
fn paddedLen(len: usize) usize {
    return (len + 31) / 32 * 32;
}

/// ABI-encode a sequence of top-level parameters. The caller owns the result.
pub fn encode(allocator: std.mem.Allocator, params: []const Value) ![]u8 {
    const head_len = params.len * 32;
    var tail_len: usize = 0;
    for (params) |p| switch (p) {
        .word => {},
        .dyn_bytes => |b| tail_len += 32 + paddedLen(b.len),
        .dyn_words => |ws| tail_len += 32 + ws.len * 32,
    };

    const buf = try allocator.alloc(u8, head_len + tail_len);
    @memset(buf, 0);

    var head: usize = 0;
    var tail: usize = head_len;
    for (params) |p| switch (p) {
        .word => |w| {
            @memcpy(buf[head..][0..32], &w);
            head += 32;
        },
        // The head is the offset of this parameter's tail, measured from the
        // start of the block; the tail is a length word then the data.
        .dyn_bytes => |b| {
            const off = word256(tail);
            @memcpy(buf[head..][0..32], &off);
            head += 32;
            const len = word256(b.len);
            @memcpy(buf[tail..][0..32], &len);
            tail += 32;
            @memcpy(buf[tail..][0..b.len], b);
            tail += paddedLen(b.len);
        },
        .dyn_words => |ws| {
            const off = word256(tail);
            @memcpy(buf[head..][0..32], &off);
            head += 32;
            const len = word256(ws.len);
            @memcpy(buf[tail..][0..32], &len);
            tail += 32;
            for (ws) |w| {
                @memcpy(buf[tail..][0..32], &w);
                tail += 32;
            }
        },
    };
    return buf;
}

// ── Tests ────────────────────────────────────────────────────────────────
// Each expected encoding is the exact output of viem's encodeAbiParameters for
// the same parameters, so these pin the encoder to the reference the on-chain
// validators were built against.

const testing = std.testing;

fn expectHex(expected_hex: []const u8, actual: []const u8) !void {
    var buf: [2048]u8 = undefined;
    const expected = try std.fmt.hexToBytes(&buf, expected_hex);
    try testing.expectEqualSlices(u8, expected, actual);
}

test "word256 is big-endian" {
    const w = word256(0x1234);
    try testing.expectEqual(@as(u8, 0x12), w[30]);
    try testing.expectEqual(@as(u8, 0x34), w[31]);
    for (w[0..30]) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "wordAddress left-pads to 20 low bytes" {
    var addr: [20]u8 = undefined;
    @memset(&addr, 0xab);
    const w = wordAddress(addr);
    for (w[0..12]) |b| try testing.expectEqual(@as(u8, 0), b);
    for (w[12..32]) |b| try testing.expectEqual(@as(u8, 0xab), b);
}

test "encode: static words only (webauthn enableData shape)" {
    const a = testing.allocator;
    var h: [32]u8 = undefined;
    @memset(&h, 0xcc);
    const out = try encode(a, &.{
        .{ .word = word256(0xaaaa) },
        .{ .word = word256(0xbbbb) },
        .{ .word = h },
    });
    defer a.free(out);
    try expectHex(
        "000000000000000000000000000000000000000000000000000000000000aaaa" ++
            "000000000000000000000000000000000000000000000000000000000000bbbb" ++
            "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        out,
    );
}

test "encode: address[] + uint24[] + uint24 + uint48 (weighted enableData)" {
    const a = testing.allocator;
    var g0: [20]u8 = undefined;
    @memset(&g0, 0x22);
    var g1: [20]u8 = undefined;
    @memset(&g1, 0x11);
    const guardians = [_][32]u8{ wordAddress(g0), wordAddress(g1) };
    const weights = [_][32]u8{ word256(1), word256(2) };
    const out = try encode(a, &.{
        .{ .dyn_words = &guardians },
        .{ .dyn_words = &weights },
        .{ .word = word256(2) },
        .{ .word = word256(0) },
    });
    defer a.free(out);
    try expectHex(
        "0000000000000000000000000000000000000000000000000000000000000080" ++
            "00000000000000000000000000000000000000000000000000000000000000e0" ++
            "0000000000000000000000000000000000000000000000000000000000000002" ++
            "0000000000000000000000000000000000000000000000000000000000000000" ++
            "0000000000000000000000000000000000000000000000000000000000000002" ++
            "0000000000000000000000002222222222222222222222222222222222222222" ++
            "0000000000000000000000001111111111111111111111111111111111111111" ++
            "0000000000000000000000000000000000000000000000000000000000000002" ++
            "0000000000000000000000000000000000000000000000000000000000000001" ++
            "0000000000000000000000000000000000000000000000000000000000000002",
        out,
    );
}

test "encode: bytes + string + uint256 x3 + bool (webauthn signature)" {
    const a = testing.allocator;
    var auth_data: [37]u8 = undefined;
    @memset(&auth_data, 0x49);
    const client_data_json = "{\"type\":\"webauthn.get\",\"challenge\":\"abc\"}";
    const out = try encode(a, &.{
        .{ .dyn_bytes = &auth_data },
        .{ .dyn_bytes = client_data_json },
        .{ .word = word256(1) },
        .{ .word = word256(0x1234) },
        .{ .word = word256(0x5678) },
        .{ .word = wordBool(false) },
    });
    defer a.free(out);
    try expectHex(
        "00000000000000000000000000000000000000000000000000000000000000c0" ++
            "0000000000000000000000000000000000000000000000000000000000000120" ++
            "0000000000000000000000000000000000000000000000000000000000000001" ++
            "0000000000000000000000000000000000000000000000000000000000001234" ++
            "0000000000000000000000000000000000000000000000000000000000005678" ++
            "0000000000000000000000000000000000000000000000000000000000000000" ++
            "0000000000000000000000000000000000000000000000000000000000000025" ++
            "4949494949494949494949494949494949494949494949494949494949494949" ++
            "4949494949000000000000000000000000000000000000000000000000000000" ++
            "0000000000000000000000000000000000000000000000000000000000000029" ++
            "7b2274797065223a22776562617574686e2e676574222c226368616c6c656e67" ++
            "65223a22616263227d0000000000000000000000000000000000000000000000",
        out,
    );
}
