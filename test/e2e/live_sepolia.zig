//! Live E2E tests against ZeroDev infrastructure on Sepolia.
//!
//! Uses paymaster sponsorship — no ETH needed in the smart account.
//!
//! Requires environment variables:
//!   ZERODEV_PROJECT_ID  — ZeroDev project ID
//!   E2E_PRIVATE_KEY     — 32-byte hex private key (no 0x prefix)
//!
//! Run via: zig build test-live
//! Or:      make test-live

const std = @import("std");
const zigeth = @import("zigeth");

const Address = zigeth.primitives.Address;
const PrivateKey = zigeth.crypto.secp256k1.PrivateKey;
const Wallet = zigeth.signer.Wallet;

const core = @import("core");
const create2 = core.create2;
const kernel_mod = core.kernel;
const userop_mod = core.userop;
const entrypoint_mod = core.entrypoint;
const bundler_mod = core.bundler;
const paymaster_mod = core.paymaster;
const json_rpc = @import("transport");
const Client = json_rpc.Client;

const EcdsaValidator = @import("validators").ecdsa.EcdsaValidator;
const LocalSigner = @import("signers").local.LocalSigner;

fn fmtAddr(bytes: []const u8) [40]u8 {
    const hex_chars = "0123456789abcdef";
    var out: [40]u8 = undefined;
    for (bytes[0..20], 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0xf];
    }
    return out;
}

fn fmtHash(bytes: []const u8) [64]u8 {
    const hex_chars = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (bytes[0..32], 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0xf];
    }
    return out;
}

// ---- Helpers ----

fn getEnvOr(key: []const u8, default: []const u8) []const u8 {
    return std.posix.getenv(key) orelse default;
}

fn hexToBytes32(hex: []const u8) ![32]u8 {
    const stripped = if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X'))
        hex[2..]
    else
        hex;
    if (stripped.len != 64) return error.InvalidLength;

    var result: [32]u8 = undefined;
    for (0..32) |i| {
        const hi = try hexDigit(stripped[i * 2]);
        const lo = try hexDigit(stripped[i * 2 + 1]);
        result[i] = (hi << 4) | lo;
    }
    return result;
}

fn hexDigit(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => return error.InvalidCharacter,
    };
}

fn skipIfNoEnv() bool {
    const project_id = getEnvOr("ZERODEV_PROJECT_ID", "");
    if (project_id.len == 0) {
        std.log.warn("ZERODEV_PROJECT_ID not set, skipping live tests", .{});
        return true;
    }
    return false;
}

// ---- Tests ----

test "live: verify Sepolia chain ID" {
    if (skipIfNoEnv()) return;
    const allocator = std.testing.allocator;
    const project_id = getEnvOr("ZERODEV_PROJECT_ID", "");

    const rpc_url = try core.buildRpcUrl(allocator, project_id, 11155111);
    defer allocator.free(rpc_url);

    var client = try Client.init(allocator, rpc_url);
    defer client.deinit();

    const chain_id = try client.getChainId();
    try std.testing.expectEqual(@as(u64, 11155111), chain_id);
    std.log.info("Sepolia chain ID: {d}", .{chain_id});
}

test "live: derive Kernel address on Sepolia" {
    if (skipIfNoEnv()) return;
    const allocator = std.testing.allocator;

    const pk_hex = getEnvOr("E2E_PRIVATE_KEY", "");
    if (pk_hex.len == 0) return;

    const pk_bytes = try hexToBytes32(pk_hex);
    const local = try allocator.create(LocalSigner);
    defer allocator.destroy(local);
    local.* = try LocalSigner.init(allocator, pk_bytes);
    const ecdsa = EcdsaValidator.init(local.signer());

    const addr = try create2.getKernelAddress(ecdsa.owner_address, 0, .v3_3);
    const addr_hex = fmtAddr(&addr.bytes);
    std.log.info("Kernel v3.3 address on Sepolia: 0x{s}", .{&addr_hex});

    // Address should be non-zero and deterministic
    try std.testing.expect(!addr.isZero());
    const addr2 = try create2.getKernelAddress(ecdsa.owner_address, 0, .v3_3);
    try std.testing.expectEqualSlices(u8, &addr.bytes, &addr2.bytes);
}

test "live: sponsored UserOp via ZeroDev paymaster" {
    if (skipIfNoEnv()) return;
    const allocator = std.testing.allocator;
    const project_id = getEnvOr("ZERODEV_PROJECT_ID", "");

    const pk_hex = getEnvOr("E2E_PRIVATE_KEY", "");
    if (pk_hex.len == 0) return;

    const chain_id: u64 = 11155111;

    // Build ZeroDev RPC URL (bundler + paymaster use same endpoint)
    const rpc_url = try core.buildRpcUrl(allocator, project_id, chain_id);
    defer allocator.free(rpc_url);

    var rpc = try Client.init(allocator, rpc_url);
    defer rpc.deinit();

    const pk_bytes = try hexToBytes32(pk_hex);
    const local = try allocator.create(LocalSigner);
    defer allocator.destroy(local);
    local.* = try LocalSigner.init(allocator, pk_bytes);
    var ecdsa = EcdsaValidator.init(local.signer());
    const sender = try create2.getKernelAddress(ecdsa.owner_address, 0, .v3_3);
    const sender_hex = fmtAddr(&sender.bytes);
    std.log.info("Step 1: Sender address: 0x{s}", .{&sender_hex});

    // Step 2: Get nonce
    const nonce = try entrypoint_mod.getNonce(&rpc, allocator, core.ENTRY_POINT_V07, sender, 0);
    std.log.info("Step 2: Nonce: {d}", .{nonce});

    // Step 3: Build calldata (send 0 ETH to self — noop)
    const exec = kernel_mod.Execution{
        .to = sender,
        .value = 0,
        .data = &[_]u8{},
    };
    const call_data = try kernel_mod.encodeExecute(allocator, exec);
    defer allocator.free(call_data);

    // Build init_code if nonce is 0 (first UserOp deploys the account)
    var init_code: []u8 = &[_]u8{};
    var init_code_allocated = false;
    if (nonce == 0) {
        const factory_data = try create2.buildFactoryCalldata(allocator, ecdsa.owner_address, 0, .v3_3);
        defer allocator.free(factory_data);
        const meta_factory = try Address.fromHex(core.META_FACTORY);
        init_code = try allocator.alloc(u8, 20 + factory_data.len);
        init_code_allocated = true;
        @memcpy(init_code[0..20], &meta_factory.bytes);
        @memcpy(init_code[20..], factory_data);
    }
    defer if (init_code_allocated) allocator.free(init_code);

    // Step 4: Build UserOp with stub gas values
    var user_op = userop_mod.UserOp{
        .sender = sender,
        .nonce = nonce,
        .init_code = init_code,
        .call_data = call_data,
        .call_gas_limit = 100_000,
        .verification_gas_limit = 500_000,
        .pre_verification_gas = 100_000,
        .max_fee_per_gas = 10_000_000_000,
        .max_priority_fee_per_gas = 2_000_000_000,
        .paymaster_and_data = &[_]u8{},
    };

    // Step 5: Get paymaster stub data
    // Serialize UserOp without paymaster for the stub request
    var val = ecdsa.validator();
    const entry_point = try Address.fromHex(core.ENTRY_POINT_V07);

    // Sign with current gas values for estimation
    const stub_hash = user_op.computeHash(entry_point, @as(u256, chain_id));
    const stub_sig = try val.signUserOp(stub_hash.bytes);
    const stub_json = try user_op.toJsonValue(allocator, &stub_sig);
    defer json_rpc.freeValue(allocator, stub_json);

    const pm_stub = try paymaster_mod.getPaymasterStubData(&rpc, allocator, stub_json, core.ENTRY_POINT_V07, chain_id);
    defer pm_stub.deinit(allocator);
    const pm_hex = fmtAddr(&pm_stub.paymaster.bytes);
    std.log.info("Step 5: Paymaster: 0x{s}", .{&pm_hex});

    // Pack paymaster data into paymaster_and_data
    // Use stub verification gas limit (will be updated after estimation)
    const pm_packed_stub = try paymaster_mod.packPaymasterAndData(
        allocator,
        pm_stub.paymaster,
        500_000, // stub verification gas
        pm_stub.paymaster_post_op_gas_limit,
        pm_stub.paymaster_data,
    );
    defer allocator.free(pm_packed_stub);

    user_op.paymaster_and_data = pm_packed_stub;

    // Step 6: Estimate gas with paymaster stub
    const est_hash = user_op.computeHash(entry_point, @as(u256, chain_id));
    const est_sig = try val.signUserOp(est_hash.bytes);
    const est_json = try user_op.toJsonValue(allocator, &est_sig);
    defer json_rpc.freeValue(allocator, est_json);

    const gas = try bundler_mod.estimateUserOperationGas(&rpc, allocator, est_json, core.ENTRY_POINT_V07);
    std.log.info("Step 6: Gas — call={d}, verif={d}, preVerif={d}, pmVerif={d}, pmPostOp={d}", .{
        gas.call_gas_limit,
        gas.verification_gas_limit,
        gas.pre_verification_gas,
        gas.paymaster_verification_gas_limit,
        gas.paymaster_post_op_gas_limit,
    });

    // Step 7: Apply gas estimates (including paymaster gas limits)
    user_op.call_gas_limit = gas.call_gas_limit + gas.call_gas_limit / 5;
    user_op.verification_gas_limit = gas.verification_gas_limit + gas.verification_gas_limit / 5;
    const pvg_u128: u128 = @truncate(gas.pre_verification_gas);
    user_op.pre_verification_gas = gas.pre_verification_gas + pvg_u128 / 5;

    // Repack paymaster_and_data with estimated gas limits (so pm_getPaymasterData sees correct values)
    const pm_packed_est = try paymaster_mod.packPaymasterAndData(
        allocator,
        pm_stub.paymaster,
        gas.paymaster_verification_gas_limit,
        gas.paymaster_post_op_gas_limit,
        pm_stub.paymaster_data,
    );
    defer allocator.free(pm_packed_est);
    user_op.paymaster_and_data = pm_packed_est;

    // Step 8: Get final paymaster data (paymaster signs over the final gas values)
    const final_pm_hash = user_op.computeHash(entry_point, @as(u256, chain_id));
    const final_pm_sig = try val.signUserOp(final_pm_hash.bytes);
    const final_pm_json = try user_op.toJsonValue(allocator, &final_pm_sig);
    defer json_rpc.freeValue(allocator, final_pm_json);

    const pm_final = try paymaster_mod.getPaymasterData(&rpc, allocator, final_pm_json, core.ENTRY_POINT_V07, chain_id);
    defer pm_final.deinit(allocator);

    // Repack with FINAL paymaster data (keeping estimated gas limits)
    const pm_packed_final = try paymaster_mod.packPaymasterAndData(
        allocator,
        pm_final.paymaster,
        gas.paymaster_verification_gas_limit,
        gas.paymaster_post_op_gas_limit,
        pm_final.paymaster_data,
    );
    defer allocator.free(pm_packed_final);

    user_op.paymaster_and_data = pm_packed_final;

    // Step 9: Final hash and sign
    const op_hash = user_op.computeHash(entry_point, @as(u256, chain_id));
    const real_sig = try val.signUserOp(op_hash.bytes);
    const hash_hex = fmtHash(&op_hash.bytes);
    std.log.info("Step 9: Signed, hash: 0x{s}", .{&hash_hex});

    // Step 10: Send
    const send_json = try user_op.toJsonValue(allocator, &real_sig);
    defer json_rpc.freeValue(allocator, send_json);

    const op_hash_hex = try bundler_mod.sendUserOperation(&rpc, allocator, send_json, core.ENTRY_POINT_V07);
    defer allocator.free(op_hash_hex);
    std.debug.print("\n========================================\n", .{});
    std.debug.print("USEROP HASH: {s}\n", .{op_hash_hex});
    std.debug.print("========================================\n", .{});
    try std.testing.expect(op_hash_hex.len > 0);

    // Step 11: Poll for receipt
    var receipt_opt: ?bundler_mod.UserOpReceipt = null;
    var attempts: u32 = 0;
    while (attempts < 60) : (attempts += 1) {
        receipt_opt = try bundler_mod.getUserOperationReceipt(&rpc, allocator, op_hash_hex);
        if (receipt_opt != null) break;
        std.Thread.sleep(2 * std.time.ns_per_s);
    }

    if (receipt_opt) |receipt| {
        defer receipt.deinit(allocator);
        std.log.info("Step 11: Receipt — success={}, gasUsed={d}, tx={s}", .{
            receipt.success, receipt.actual_gas_used, receipt.tx_hash,
        });
        try std.testing.expect(receipt.success);
        try std.testing.expect(receipt.actual_gas_used > 0);

        // Step 12: Raw RPC call to log the full getUserOperationReceipt JSON
        {
            var raw_params = std.json.Array.init(allocator);
            defer raw_params.deinit();
            try raw_params.append(.{ .string = op_hash_hex });

            const raw_result = try rpc.call("eth_getUserOperationReceipt", .{ .array = raw_params });
            defer json_rpc.freeValue(allocator, raw_result);

            const raw_json_str = try std.json.Stringify.valueAlloc(allocator, raw_result, .{});
            defer allocator.free(raw_json_str);

            std.debug.print("\n========================================\n", .{});
            std.debug.print("FULL getUserOperationReceipt JSON:\n", .{});
            std.debug.print("{s}\n", .{raw_json_str});
            std.debug.print("========================================\n", .{});
        }
    } else {
        std.log.err("Step 11: No receipt after 2 minutes!", .{});
        return error.TestUnexpectedResult;
    }
}
