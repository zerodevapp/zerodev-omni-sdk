//! EntryPoint v0.7 nonce queries via eth_call.

const std = @import("std");
const zigeth = @import("zigeth");

const Address = zigeth.primitives.Address;
const keccak = zigeth.crypto.keccak;

pub fn parseHex(comptime T: type, hex: []const u8) !T {
    const stripped = if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X'))
        hex[2..]
    else
        hex;
    if (stripped.len == 0) return 0;

    const max_digits = @typeInfo(T).int.bits / 4;
    if (stripped.len > max_digits) return error.Overflow;

    var result: T = 0;
    for (stripped) |c| {
        const digit: T = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.InvalidCharacter,
        };
        result = (result << 4) | digit;
    }
    return result;
}

pub fn getNonce(
    client: anytype,
    allocator: std.mem.Allocator,
    entry_point_hex: []const u8,
    sender: Address,
    key: u192,
) !u256 {
    const calldata = buildGetNonceCalldata(sender, key);
    const calldata_hex = try zigeth.utils.hex.bytesToHex(allocator, &calldata);
    defer allocator.free(calldata_hex);

    var call_obj = std.json.ObjectMap.init(allocator);
    defer call_obj.deinit();
    try call_obj.put("to", .{ .string = entry_point_hex });
    try call_obj.put("data", .{ .string = calldata_hex });

    var params_arr = std.json.Array.init(allocator);
    defer params_arr.deinit();
    try params_arr.append(.{ .object = call_obj });
    try params_arr.append(.{ .string = "latest" });

    const result = try client.call("eth_call", .{ .array = params_arr });
    if (result != .string) return error.UnexpectedResponse;
    defer allocator.free(result.string);
    return parseHex(u256, result.string);
}

pub fn buildGetNonceCalldata(sender: Address, key: u192) [68]u8 {
    var calldata: [68]u8 = [_]u8{0} ** 68;
    const selector = keccak.functionSelector("getNonce(address,uint192)");
    @memcpy(calldata[0..4], &selector);
    @memcpy(calldata[16..36], &sender.bytes);
    const key_u256: u256 = @as(u256, key);
    const key_be: [32]u8 = @bitCast(@byteSwap(key_u256));
    @memcpy(calldata[36..68], &key_be);
    return calldata;
}

test "getNonce selector is 0x35567e1a" {
    const selector = keccak.functionSelector("getNonce(address,uint192)");
    try std.testing.expectEqual(@as(u8, 0x35), selector[0]);
    try std.testing.expectEqual(@as(u8, 0x56), selector[1]);
    try std.testing.expectEqual(@as(u8, 0x7e), selector[2]);
    try std.testing.expectEqual(@as(u8, 0x1a), selector[3]);
}

test "buildGetNonceCalldata length is 68 bytes" {
    const sender = try Address.fromHex("0xCfC4C807Ed404ae1a65fbe0EdaA09EF002E75838");
    const calldata = buildGetNonceCalldata(sender, 0);
    try std.testing.expectEqual(@as(usize, 68), calldata.len);
}

test "buildGetNonceCalldata embeds sender address" {
    const sender = try Address.fromHex("0xCfC4C807Ed404ae1a65fbe0EdaA09EF002E75838");
    const calldata = buildGetNonceCalldata(sender, 0);
    try std.testing.expectEqual(@as(u8, 0x35), calldata[0]);
    try std.testing.expectEqualSlices(u8, &sender.bytes, calldata[16..36]);
    for (calldata[4..16]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    for (calldata[36..68]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "buildGetNonceCalldata with non-zero key" {
    const sender = try Address.fromHex("0xCfC4C807Ed404ae1a65fbe0EdaA09EF002E75838");
    const calldata = buildGetNonceCalldata(sender, 1);
    try std.testing.expectEqual(@as(u8, 1), calldata[67]);
    for (calldata[36..67]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "parseHex u256 basic values" {
    try std.testing.expectEqual(@as(u256, 0), try parseHex(u256, "0x0"));
    try std.testing.expectEqual(@as(u256, 1), try parseHex(u256, "0x1"));
    try std.testing.expectEqual(@as(u256, 255), try parseHex(u256, "0xff"));
    try std.testing.expectEqual(@as(u256, 0xc000), try parseHex(u256, "0xc000"));
}

test "parseHex u256 full 32-byte response" {
    try std.testing.expectEqual(
        @as(u256, 5),
        try parseHex(u256, "0x0000000000000000000000000000000000000000000000000000000000000005"),
    );
}

test "parseHex u128 values" {
    try std.testing.expectEqual(@as(u128, 0x50000), try parseHex(u128, "0x50000"));
    try std.testing.expectEqual(@as(u128, 0x70000), try parseHex(u128, "0x70000"));
}
