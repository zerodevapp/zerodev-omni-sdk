//! ERC-4337 paymaster sponsorship via pm_getPaymasterStubData / pm_getPaymasterData.

const std = @import("std");
const zigeth = @import("zigeth");
const json_rpc = @import("transport");

const Address = zigeth.primitives.Address;

pub const StubData = struct {
    paymaster: Address,
    paymaster_data: []u8,
    paymaster_post_op_gas_limit: u128,

    pub fn deinit(self: StubData, allocator: std.mem.Allocator) void {
        allocator.free(self.paymaster_data);
    }
};

pub const PaymasterData = struct {
    paymaster: Address,
    paymaster_data: []u8,

    pub fn deinit(self: PaymasterData, allocator: std.mem.Allocator) void {
        allocator.free(self.paymaster_data);
    }
};

pub fn getPaymasterStubData(
    client: anytype,
    allocator: std.mem.Allocator,
    userop_value: std.json.Value,
    entry_point_hex: []const u8,
    chain_id: u64,
) !StubData {
    var params_arr = std.json.Array.init(allocator);
    defer params_arr.deinit();
    try params_arr.append(userop_value);
    try params_arr.append(.{ .string = entry_point_hex });

    const chain_hex = try std.fmt.allocPrint(allocator, "0x{x}", .{chain_id});
    defer allocator.free(chain_hex);
    try params_arr.append(.{ .string = chain_hex });

    const result = try client.call("pm_getPaymasterStubData", .{ .array = params_arr });
    defer json_rpc.freeValue(allocator, result);
    if (result != .object) return error.UnexpectedResponse;
    const obj = result.object;

    const pm_val = obj.get("paymaster") orelse return error.MissingField;
    if (pm_val != .string) return error.UnexpectedResponse;
    const paymaster = try Address.fromHex(pm_val.string);

    const pm_data_val = obj.get("paymasterData") orelse return error.MissingField;
    if (pm_data_val != .string) return error.UnexpectedResponse;
    const paymaster_data = try zigeth.utils.hex.hexToBytes(allocator, pm_data_val.string);

    var post_op_gas: u128 = 0;
    if (obj.get("paymasterPostOpGasLimit")) |v| {
        if (v == .string) post_op_gas = json_rpc.parseHex(u128, v.string) catch 0;
    }

    return .{
        .paymaster = paymaster,
        .paymaster_data = paymaster_data,
        .paymaster_post_op_gas_limit = post_op_gas,
    };
}

pub fn getPaymasterData(
    client: anytype,
    allocator: std.mem.Allocator,
    userop_value: std.json.Value,
    entry_point_hex: []const u8,
    chain_id: u64,
) !PaymasterData {
    var params_arr = std.json.Array.init(allocator);
    defer params_arr.deinit();
    try params_arr.append(userop_value);
    try params_arr.append(.{ .string = entry_point_hex });

    const chain_hex = try std.fmt.allocPrint(allocator, "0x{x}", .{chain_id});
    defer allocator.free(chain_hex);
    try params_arr.append(.{ .string = chain_hex });

    const result = try client.call("pm_getPaymasterData", .{ .array = params_arr });
    defer json_rpc.freeValue(allocator, result);
    if (result != .object) return error.UnexpectedResponse;
    const obj = result.object;

    const pm_val = obj.get("paymaster") orelse return error.MissingField;
    if (pm_val != .string) return error.UnexpectedResponse;
    const paymaster = try Address.fromHex(pm_val.string);

    const pm_data_val = obj.get("paymasterData") orelse return error.MissingField;
    if (pm_data_val != .string) return error.UnexpectedResponse;
    const paymaster_data = try zigeth.utils.hex.hexToBytes(allocator, pm_data_val.string);

    return .{
        .paymaster = paymaster,
        .paymaster_data = paymaster_data,
    };
}

pub fn packPaymasterAndData(
    allocator: std.mem.Allocator,
    paymaster: Address,
    verification_gas_limit: u128,
    post_op_gas_limit: u128,
    paymaster_data: []const u8,
) ![]u8 {
    const len = 20 + 16 + 16 + paymaster_data.len;
    const buf = try allocator.alloc(u8, len);
    @memcpy(buf[0..20], &paymaster.bytes);
    const verif_be: [16]u8 = @bitCast(@byteSwap(verification_gas_limit));
    @memcpy(buf[20..36], &verif_be);
    const postop_be: [16]u8 = @bitCast(@byteSwap(post_op_gas_limit));
    @memcpy(buf[36..52], &postop_be);
    if (paymaster_data.len > 0) {
        @memcpy(buf[52..], paymaster_data);
    }
    return buf;
}
