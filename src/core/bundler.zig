//! Bundler gas estimation via eth_estimateUserOperationGas.

const std = @import("std");
const zigeth = @import("zigeth");
const json_rpc = @import("transport");

pub const GasEstimate = struct {
    call_gas_limit: u128,
    verification_gas_limit: u128,
    pre_verification_gas: u256,
    paymaster_verification_gas_limit: u128 = 0,
    paymaster_post_op_gas_limit: u128 = 0,
};

fn parseHex(comptime T: type, hex: []const u8) !T {
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

pub fn estimateUserOperationGas(
    client: anytype,
    allocator: std.mem.Allocator,
    userop_value: std.json.Value,
    entry_point_hex: []const u8,
) !GasEstimate {
    var params_arr = std.json.Array.init(allocator);
    defer params_arr.deinit();
    try params_arr.append(userop_value);
    try params_arr.append(.{ .string = entry_point_hex });

    const result = try client.call("eth_estimateUserOperationGas", .{ .array = params_arr });
    if (result != .object) return error.UnexpectedResponse;
    const obj = result.object;
    defer json_rpc.freeValue(allocator, result);

    const call_gas_val = obj.get("callGasLimit") orelse return error.MissingField;
    const verif_gas_val = obj.get("verificationGasLimit") orelse return error.MissingField;
    const pre_verif_val = obj.get("preVerificationGas") orelse return error.MissingField;
    if (call_gas_val != .string or verif_gas_val != .string or pre_verif_val != .string)
        return error.UnexpectedResponse;

    var pm_verif_gas: u128 = 0;
    if (obj.get("paymasterVerificationGasLimit")) |v| {
        if (v == .string) pm_verif_gas = parseHex(u128, v.string) catch 0;
    }
    var pm_postop_gas: u128 = 0;
    if (obj.get("paymasterPostOpGasLimit")) |v| {
        if (v == .string) pm_postop_gas = parseHex(u128, v.string) catch 0;
    }

    return .{
        .call_gas_limit = try parseHex(u128, call_gas_val.string),
        .verification_gas_limit = try parseHex(u128, verif_gas_val.string),
        .pre_verification_gas = try parseHex(u256, pre_verif_val.string),
        .paymaster_verification_gas_limit = pm_verif_gas,
        .paymaster_post_op_gas_limit = pm_postop_gas,
    };
}

pub fn sendUserOperation(
    client: anytype,
    allocator: std.mem.Allocator,
    userop_value: std.json.Value,
    entry_point_hex: []const u8,
) ![]u8 {
    var params_arr = std.json.Array.init(allocator);
    defer params_arr.deinit();
    try params_arr.append(userop_value);
    try params_arr.append(.{ .string = entry_point_hex });

    const result = try client.call("eth_sendUserOperation", .{ .array = params_arr });
    defer json_rpc.freeValue(allocator, result);
    if (result != .string) return error.UnexpectedResponse;
    return try allocator.dupe(u8, result.string);
}

pub const UserOpReceipt = struct {
    success: bool,
    actual_gas_used: u256,
    /// The UserOp hash
    user_op_hash: []u8,
    /// The transaction hash where the UserOp was included
    tx_hash: []u8,

    pub fn deinit(self: UserOpReceipt, allocator: std.mem.Allocator) void {
        allocator.free(self.user_op_hash);
        allocator.free(self.tx_hash);
    }
};

pub fn getUserOperationReceipt(
    client: anytype,
    allocator: std.mem.Allocator,
    userop_hash: []const u8,
) !?UserOpReceipt {
    var params_arr = std.json.Array.init(allocator);
    defer params_arr.deinit();
    try params_arr.append(.{ .string = userop_hash });

    const result = client.call("eth_getUserOperationReceipt", .{ .array = params_arr }) catch |err| {
        if (err == error.JsonRpcError) return null;
        return err;
    };
    if (result == .null) return null;
    if (result != .object) {
        json_rpc.freeValue(allocator, result);
        return error.UnexpectedResponse;
    }
    defer json_rpc.freeValue(allocator, result);
    const obj = result.object;

    var success = true;
    if (obj.get("success")) |v| {
        if (v == .bool) success = v.bool;
    }

    var actual_gas: u256 = 0;
    if (obj.get("actualGasUsed")) |v| {
        if (v == .string) actual_gas = parseHex(u256, v.string) catch 0;
    }

    const uoh = if (obj.get("userOpHash")) |v|
        (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, ""))
    else
        try allocator.dupe(u8, "");

    const txh = if (obj.get("receipt")) |receipt_val| blk: {
        if (receipt_val == .object) {
            if (receipt_val.object.get("transactionHash")) |v| {
                if (v == .string) break :blk try allocator.dupe(u8, v.string);
            }
        }
        break :blk try allocator.dupe(u8, "");
    } else try allocator.dupe(u8, "");

    return .{
        .success = success,
        .actual_gas_used = actual_gas,
        .user_op_hash = uoh,
        .tx_hash = txh,
    };
}

test "parseHex u128 with 0x prefix" {
    const result = try parseHex(u128, "0x50000");
    try std.testing.expectEqual(@as(u128, 0x50000), result);
}

test "parseHex u128 without prefix" {
    const result = try parseHex(u128, "70000");
    try std.testing.expectEqual(@as(u128, 0x70000), result);
}

test "parseHex u256 with 0x prefix" {
    const result = try parseHex(u256, "0xc000");
    try std.testing.expectEqual(@as(u256, 0xc000), result);
}

test "parseHex u128 zero" {
    try std.testing.expectEqual(@as(u128, 0), try parseHex(u128, "0x0"));
    try std.testing.expectEqual(@as(u128, 0), try parseHex(u128, "0x"));
}

test "parseHex u128 uppercase hex" {
    const result = try parseHex(u128, "0xABCDEF");
    try std.testing.expectEqual(@as(u128, 0xABCDEF), result);
}

test "parseHex u128 overflow returns error" {
    const result = parseHex(u128, "0x" ++ "1" ** 33);
    try std.testing.expectError(error.Overflow, result);
}
