//! ERC-4337 v0.7 UserOperation hashing.
//!
//! Computes the UserOperation hash as defined by the EntryPoint v0.7 contract:
//!   userOpHash = keccak256(abi.encode(keccak256(packedUserOp), entryPoint, chainId))

const std = @import("std");
const zigeth = @import("zigeth");

const Address = zigeth.primitives.Address;
const Hash = zigeth.primitives.Hash;
const keccak = zigeth.crypto.keccak;

pub const UserOp = struct {
    sender: Address,
    nonce: u256,
    init_code: []const u8,
    call_data: []const u8,
    call_gas_limit: u128,
    verification_gas_limit: u128,
    pre_verification_gas: u256,
    max_fee_per_gas: u128,
    max_priority_fee_per_gas: u128,
    paymaster_and_data: []const u8,

    /// Serialize this UserOp to a JSON object in the ERC-4337 v0.7 RPC format.
    /// The caller must free the returned value via json_rpc.freeValue().
    pub fn toJsonValue(self: UserOp, allocator: std.mem.Allocator, signature: []const u8) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        errdefer {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                // values are string literals or allocated strings
                if (entry.value_ptr.* == .string) allocator.free(entry.value_ptr.string);
            }
            obj.deinit();
        }

        // sender
        const sender_hex = try self.sender.toHex(allocator);
        try obj.put(try allocator.dupe(u8, "sender"), .{ .string = sender_hex });

        // nonce
        const nonce_hex = try std.fmt.allocPrint(allocator, "0x{x}", .{self.nonce});
        try obj.put(try allocator.dupe(u8, "nonce"), .{ .string = nonce_hex });

        // factory + factoryData (v0.7 splits initCode)
        if (self.init_code.len >= 20) {
            const factory_addr = Address.fromBytes(self.init_code[0..20].*);
            const factory_hex = try factory_addr.toHex(allocator);
            try obj.put(try allocator.dupe(u8, "factory"), .{ .string = factory_hex });
            const factory_data_hex = try zigeth.utils.hex.bytesToHex(allocator, self.init_code[20..]);
            try obj.put(try allocator.dupe(u8, "factoryData"), .{ .string = factory_data_hex });
        }

        // callData
        const call_data_hex = try zigeth.utils.hex.bytesToHex(allocator, self.call_data);
        try obj.put(try allocator.dupe(u8, "callData"), .{ .string = call_data_hex });

        // gas limits
        const cgl_hex = try std.fmt.allocPrint(allocator, "0x{x}", .{self.call_gas_limit});
        try obj.put(try allocator.dupe(u8, "callGasLimit"), .{ .string = cgl_hex });

        const vgl_hex = try std.fmt.allocPrint(allocator, "0x{x}", .{self.verification_gas_limit});
        try obj.put(try allocator.dupe(u8, "verificationGasLimit"), .{ .string = vgl_hex });

        const pvg_hex = try std.fmt.allocPrint(allocator, "0x{x}", .{self.pre_verification_gas});
        try obj.put(try allocator.dupe(u8, "preVerificationGas"), .{ .string = pvg_hex });

        const mfpg_hex = try std.fmt.allocPrint(allocator, "0x{x}", .{self.max_fee_per_gas});
        try obj.put(try allocator.dupe(u8, "maxFeePerGas"), .{ .string = mfpg_hex });

        const mppfg_hex = try std.fmt.allocPrint(allocator, "0x{x}", .{self.max_priority_fee_per_gas});
        try obj.put(try allocator.dupe(u8, "maxPriorityFeePerGas"), .{ .string = mppfg_hex });

        // paymaster fields (v0.7 splits paymasterAndData)
        if (self.paymaster_and_data.len >= 52) {
            const pm_addr = Address.fromBytes(self.paymaster_and_data[0..20].*);
            const pm_hex = try pm_addr.toHex(allocator);
            try obj.put(try allocator.dupe(u8, "paymaster"), .{ .string = pm_hex });
            // Parse 16-byte big-endian gas limits back to integers for compact hex encoding
            const pm_vgl: u128 = @byteSwap(@as(u128, @bitCast(self.paymaster_and_data[20..36].*)));
            const pm_vgl_hex = try std.fmt.allocPrint(allocator, "0x{x}", .{pm_vgl});
            try obj.put(try allocator.dupe(u8, "paymasterVerificationGasLimit"), .{ .string = pm_vgl_hex });
            const pm_pogl: u128 = @byteSwap(@as(u128, @bitCast(self.paymaster_and_data[36..52].*)));
            const pm_pogl_hex = try std.fmt.allocPrint(allocator, "0x{x}", .{pm_pogl});
            try obj.put(try allocator.dupe(u8, "paymasterPostOpGasLimit"), .{ .string = pm_pogl_hex });
            const pm_data_hex = try zigeth.utils.hex.bytesToHex(allocator, self.paymaster_and_data[52..]);
            try obj.put(try allocator.dupe(u8, "paymasterData"), .{ .string = pm_data_hex });
        }

        // signature
        const sig_hex = try zigeth.utils.hex.bytesToHex(allocator, signature);
        try obj.put(try allocator.dupe(u8, "signature"), .{ .string = sig_hex });

        return .{ .object = obj };
    }

    pub fn computeHash(self: UserOp, entry_point: Address, chain_id: u256) Hash {
        var account_gas_limits: [32]u8 = [_]u8{0} ** 32;
        account_gas_limits[0..16].* = @bitCast(@byteSwap(self.verification_gas_limit));
        account_gas_limits[16..32].* = @bitCast(@byteSwap(self.call_gas_limit));

        var gas_fees: [32]u8 = [_]u8{0} ** 32;
        gas_fees[0..16].* = @bitCast(@byteSwap(self.max_priority_fee_per_gas));
        gas_fees[16..32].* = @bitCast(@byteSwap(self.max_fee_per_gas));

        const init_code_hash = keccak.hash(self.init_code);
        const call_data_hash = keccak.hash(self.call_data);
        const paymaster_hash = keccak.hash(self.paymaster_and_data);

        var encoded: [256]u8 = [_]u8{0} ** 256;
        @memcpy(encoded[12..32], &self.sender.bytes);
        encoded[32..64].* = @bitCast(@byteSwap(self.nonce));
        @memcpy(encoded[64..96], &init_code_hash.bytes);
        @memcpy(encoded[96..128], &call_data_hash.bytes);
        @memcpy(encoded[128..160], &account_gas_limits);
        encoded[160..192].* = @bitCast(@byteSwap(self.pre_verification_gas));
        @memcpy(encoded[192..224], &gas_fees);
        @memcpy(encoded[224..256], &paymaster_hash.bytes);

        const encoded_hash = keccak.hash(&encoded);

        var final_input: [96]u8 = [_]u8{0} ** 96;
        @memcpy(final_input[0..32], &encoded_hash.bytes);
        @memcpy(final_input[44..64], &entry_point.bytes);
        final_input[64..96].* = @bitCast(@byteSwap(chain_id));

        return keccak.hash(&final_input);
    }
};

fn testUserOp() UserOp {
    const sender = Address.fromHex("0xCfC4C807Ed404ae1a65fbe0EdaA09EF002E75838") catch unreachable;
    return .{
        .sender = sender,
        .nonce = 0,
        .init_code = &[_]u8{},
        .call_data = &[_]u8{},
        .call_gas_limit = 0x50000,
        .verification_gas_limit = 0x70000,
        .pre_verification_gas = 0xc000,
        .max_fee_per_gas = 0x3b9aca00,
        .max_priority_fee_per_gas = 0x3b9aca00,
        .paymaster_and_data = &[_]u8{},
    };
}

fn testEntryPoint() Address {
    return Address.fromHex("0x0000000071727De22E5E9d8BAf0edAc6f37da032") catch unreachable;
}

test "computeHash produces non-zero hash" {
    const op = testUserOp();
    const h = op.computeHash(testEntryPoint(), 11155111);
    try std.testing.expect(!h.isZero());
}

test "computeHash is deterministic" {
    const op = testUserOp();
    const h1 = op.computeHash(testEntryPoint(), 11155111);
    const h2 = op.computeHash(testEntryPoint(), 11155111);
    try std.testing.expect(h1.eql(h2));
}

test "computeHash changes with different sender" {
    const ep = testEntryPoint();
    const op1 = testUserOp();
    var op2 = testUserOp();
    op2.sender = Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266") catch unreachable;
    const h1 = op1.computeHash(ep, 11155111);
    const h2 = op2.computeHash(ep, 11155111);
    try std.testing.expect(!h1.eql(h2));
}

test "computeHash changes with different chainId" {
    const op = testUserOp();
    const ep = testEntryPoint();
    const h1 = op.computeHash(ep, 1);
    const h2 = op.computeHash(ep, 11155111);
    try std.testing.expect(!h1.eql(h2));
}

test "computeHash changes with different nonce" {
    const ep = testEntryPoint();
    const op1 = testUserOp();
    var op2 = testUserOp();
    op2.nonce = 1;
    const h1 = op1.computeHash(ep, 11155111);
    const h2 = op2.computeHash(ep, 11155111);
    try std.testing.expect(!h1.eql(h2));
}

test "computeHash changes with different callData" {
    const ep = testEntryPoint();
    const op1 = testUserOp();
    var op2 = testUserOp();
    op2.call_data = &[_]u8{ 0xde, 0xad };
    const h1 = op1.computeHash(ep, 11155111);
    const h2 = op2.computeHash(ep, 11155111);
    try std.testing.expect(!h1.eql(h2));
}

test "computeHash changes with different gas params" {
    const ep = testEntryPoint();
    const op1 = testUserOp();
    var op2 = testUserOp();
    op2.max_fee_per_gas = 0x77359400;
    const h1 = op1.computeHash(ep, 11155111);
    const h2 = op2.computeHash(ep, 11155111);
    try std.testing.expect(!h1.eql(h2));
}
