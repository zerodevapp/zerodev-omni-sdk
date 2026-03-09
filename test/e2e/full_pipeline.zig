//! E2E tests against local Anvil + Alto bundler.
//!
//! Requires environment variables:
//!   E2E_RPC_URL      — Anvil JSON-RPC endpoint (e.g. http://127.0.0.1:8545/1)
//!   E2E_BUNDLER_URL  — Alto bundler endpoint (e.g. http://127.0.0.1:4337/1)
//!   E2E_CHAIN_ID     — Chain ID (e.g. 8453 for Base fork)
//!   E2E_PRIVATE_KEY  — 32-byte hex private key (no 0x prefix)
//!
//! Run via: zig build test-e2e
//! Or via harness: cd test/infra && node harness.mjs test

const std = @import("std");
const zigeth = @import("zigeth");

const Address = zigeth.primitives.Address;
const PrivateKey = zigeth.crypto.secp256k1.PrivateKey;
const Wallet = zigeth.signer.Wallet;

const core = @import("core");
const KernelVersion = core.KernelVersion;
const create2 = core.create2;
const kernel_mod = core.kernel;
const userop_mod = core.userop;
const entrypoint_mod = core.entrypoint;
const bundler_mod = core.bundler;
const json_rpc = @import("transport");
const Client = json_rpc.Client;

const EcdsaValidator = @import("validators").ecdsa.EcdsaValidator;

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
    const rpc_url = getEnvOr("E2E_RPC_URL", "");
    if (rpc_url.len == 0) {
        std.log.warn("E2E_RPC_URL not set, skipping e2e tests", .{});
        return true;
    }
    return false;
}

/// Fund a smart account on Anvil using anvil_setBalance.
fn fundAccount(rpc: *Client, allocator: std.mem.Allocator, account: Address) !void {
    const addr_hex = try account.toHex(allocator);
    defer allocator.free(addr_hex);
    // Set balance to 10 ETH (in wei hex)
    const balance_hex = "0x8AC7230489E80000"; // 10 ETH
    var params = [_]std.json.Value{ .{ .string = addr_hex }, .{ .string = balance_hex } };
    const result = rpc.callWithParams("anvil_setBalance", &params) catch |err| {
        std.log.warn("anvil_setBalance failed: {}", .{err});
        return;
    };
    json_rpc.freeValue(allocator, result);
}

// ---- Tests ----

test "e2e: verify EntryPoint v0.7 is deployed" {
    if (skipIfNoEnv()) return;
    const allocator = std.testing.allocator;
    const rpc_url = getEnvOr("E2E_RPC_URL", "");

    var client = try Client.init(allocator, rpc_url);
    defer client.deinit();

    const ep_addr = try Address.fromHex(core.ENTRY_POINT_V07);
    const code = try client.getCode(ep_addr);
    defer allocator.free(code);

    try std.testing.expect(code.len > 0);
    std.log.info("EntryPoint v0.7 deployed: {d} bytes of code", .{code.len});
}

test "e2e: verify MetaFactory is deployed" {
    if (skipIfNoEnv()) return;
    const allocator = std.testing.allocator;
    const rpc_url = getEnvOr("E2E_RPC_URL", "");

    var client = try Client.init(allocator, rpc_url);
    defer client.deinit();

    const mf_addr = try Address.fromHex(core.META_FACTORY);
    const code = try client.getCode(mf_addr);
    defer allocator.free(code);

    try std.testing.expect(code.len > 0);
    std.log.info("MetaFactory deployed: {d} bytes of code", .{code.len});
}

test "e2e: get chain ID from RPC" {
    if (skipIfNoEnv()) return;
    const allocator = std.testing.allocator;
    const rpc_url = getEnvOr("E2E_RPC_URL", "");

    var client = try Client.init(allocator, rpc_url);
    defer client.deinit();

    const chain_id = try client.getChainId();
    const expected_str = getEnvOr("E2E_CHAIN_ID", "8453");
    const expected = try std.fmt.parseInt(u64, expected_str, 10);

    try std.testing.expectEqual(expected, chain_id);
    std.log.info("Chain ID: {d}", .{chain_id});
}

test "e2e: derive Kernel v3.3 address is deterministic" {
    if (skipIfNoEnv()) return;
    const allocator = std.testing.allocator;

    const pk_hex = getEnvOr("E2E_PRIVATE_KEY", "");
    if (pk_hex.len == 0) return;

    const pk_bytes = try hexToBytes32(pk_hex);
    const pk = try PrivateKey.fromBytes(pk_bytes);
    const wallet = try Wallet.init(allocator, pk);

    const addr1 = try create2.getKernelAddress(wallet.address, 0, .v3_3);
    const addr2 = try create2.getKernelAddress(wallet.address, 0, .v3_3);
    try std.testing.expectEqualSlices(u8, &addr1.bytes, &addr2.bytes);

    // Different index should give different address
    const addr_idx1 = try create2.getKernelAddress(wallet.address, 1, .v3_3);
    try std.testing.expect(!std.mem.eql(u8, &addr1.bytes, &addr_idx1.bytes));

    std.log.info("Kernel v3.3 addr[0] first4: {x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ addr1.bytes[0], addr1.bytes[1], addr1.bytes[2], addr1.bytes[3] });
    std.log.info("Kernel v3.3 addr[1] first4: {x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ addr_idx1.bytes[0], addr_idx1.bytes[1], addr_idx1.bytes[2], addr_idx1.bytes[3] });
}

test "e2e: get nonce for undeployed account" {
    if (skipIfNoEnv()) return;
    const allocator = std.testing.allocator;
    const rpc_url = getEnvOr("E2E_RPC_URL", "");

    const pk_hex = getEnvOr("E2E_PRIVATE_KEY", "");
    if (pk_hex.len == 0) return;

    var rpc = try Client.init(allocator, rpc_url);
    defer rpc.deinit();

    const pk_bytes = try hexToBytes32(pk_hex);
    const pk = try PrivateKey.fromBytes(pk_bytes);
    const wallet = try Wallet.init(allocator, pk);

    const sender = try create2.getKernelAddress(wallet.address, 0, .v3_3);
    const nonce = try entrypoint_mod.getNonce(&rpc, allocator, core.ENTRY_POINT_V07, sender, 0);

    try std.testing.expectEqual(@as(u256, 0), nonce);
    std.log.info("Nonce for undeployed account: {d}", .{nonce});
}

test "e2e: build, hash, and sign UserOp" {
    if (skipIfNoEnv()) return;
    const allocator = std.testing.allocator;

    const pk_hex = getEnvOr("E2E_PRIVATE_KEY", "");
    if (pk_hex.len == 0) return;

    const chain_id_str = getEnvOr("E2E_CHAIN_ID", "8453");
    const chain_id = try std.fmt.parseInt(u64, chain_id_str, 10);

    const pk_bytes = try hexToBytes32(pk_hex);
    var ecdsa = try EcdsaValidator.init(allocator, pk_bytes);

    const sender = try create2.getKernelAddress(ecdsa.owner_address, 0, .v3_3);

    // Build calldata: send 0 ETH to self
    const exec = kernel_mod.Execution{
        .to = sender,
        .value = 0,
        .data = &[_]u8{},
    };
    const call_data = try kernel_mod.encodeExecute(allocator, exec);
    defer allocator.free(call_data);

    // Build factory calldata for init code
    const factory_data = try create2.buildFactoryCalldata(allocator, ecdsa.owner_address, 0, .v3_3);
    defer allocator.free(factory_data);

    const meta_factory = try Address.fromHex(core.META_FACTORY);
    const init_code = try allocator.alloc(u8, 20 + factory_data.len);
    defer allocator.free(init_code);
    @memcpy(init_code[0..20], &meta_factory.bytes);
    @memcpy(init_code[20..], factory_data);

    // Build UserOp with stub gas values
    const user_op = userop_mod.UserOp{
        .sender = sender,
        .nonce = 0,
        .init_code = init_code,
        .call_data = call_data,
        .call_gas_limit = 200_000,
        .verification_gas_limit = 500_000,
        .pre_verification_gas = 100_000,
        .max_fee_per_gas = 1_000_000_000,
        .max_priority_fee_per_gas = 1_000_000_000,
        .paymaster_and_data = &[_]u8{},
    };

    // Hash
    const entry_point = try Address.fromHex(core.ENTRY_POINT_V07);
    const hash = user_op.computeHash(entry_point, @as(u256, chain_id));

    var hash_nonzero = false;
    for (hash.bytes) |b| {
        if (b != 0) {
            hash_nonzero = true;
            break;
        }
    }
    try std.testing.expect(hash_nonzero);

    // Sign with ECDSA validator
    var val = ecdsa.validator();
    const sig = try val.signUserOp(hash.bytes);

    try std.testing.expectEqual(@as(usize, 65), sig.len);
    var sig_nonzero = false;
    for (sig) |b| {
        if (b != 0) {
            sig_nonzero = true;
            break;
        }
    }
    try std.testing.expect(sig_nonzero);

    std.log.info("UserOp hash first4: {x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ hash.bytes[0], hash.bytes[1], hash.bytes[2], hash.bytes[3] });
    std.log.info("Signature v={d}, r[0..4]={x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ sig[64], sig[0], sig[1], sig[2], sig[3] });
}

test "e2e: bundler responds to eth_supportedEntryPoints" {
    if (skipIfNoEnv()) return;
    const allocator = std.testing.allocator;
    const bundler_url = getEnvOr("E2E_BUNDLER_URL", "");
    if (bundler_url.len == 0) return;

    var bundler = try Client.init(allocator, bundler_url);
    defer bundler.deinit();

    const result = try bundler.callWithParams("eth_supportedEntryPoints", &[_]std.json.Value{});
    defer json_rpc.freeValue(allocator, result);

    // Should return an array of entrypoint addresses
    try std.testing.expect(result == .array);
    try std.testing.expect(result.array.items.len > 0);

    std.log.info("Bundler supports {d} entrypoint(s)", .{result.array.items.len});
    for (result.array.items) |item| {
        if (item == .string) {
            std.log.info("  - {s}", .{item.string});
        }
    }
}

test "e2e: estimate gas for UserOp via bundler" {
    if (skipIfNoEnv()) return;
    const allocator = std.testing.allocator;
    const rpc_url = getEnvOr("E2E_RPC_URL", "");
    const bundler_url = getEnvOr("E2E_BUNDLER_URL", "");
    if (bundler_url.len == 0) return;

    const pk_hex = getEnvOr("E2E_PRIVATE_KEY", "");
    if (pk_hex.len == 0) return;

    const pk_bytes = try hexToBytes32(pk_hex);
    var ecdsa = try EcdsaValidator.init(allocator, pk_bytes);
    const sender = try create2.getKernelAddress(ecdsa.owner_address, 0, .v3_3);

    // Fund the smart account via anvil_setBalance
    var rpc = try Client.init(allocator, rpc_url);
    defer rpc.deinit();
    try fundAccount(&rpc, allocator, sender);

    // Build calldata: send 0 ETH to self
    const exec = kernel_mod.Execution{
        .to = sender,
        .value = 0,
        .data = &[_]u8{},
    };
    const call_data = try kernel_mod.encodeExecute(allocator, exec);
    defer allocator.free(call_data);

    // Build init_code (factory + factoryData)
    const factory_data = try create2.buildFactoryCalldata(allocator, ecdsa.owner_address, 0, .v3_3);
    defer allocator.free(factory_data);
    const meta_factory = try Address.fromHex(core.META_FACTORY);
    const init_code = try allocator.alloc(u8, 20 + factory_data.len);
    defer allocator.free(init_code);
    @memcpy(init_code[0..20], &meta_factory.bytes);
    @memcpy(init_code[20..], factory_data);

    // Build UserOp with stub gas
    const user_op = userop_mod.UserOp{
        .sender = sender,
        .nonce = 0,
        .init_code = init_code,
        .call_data = call_data,
        .call_gas_limit = 200_000,
        .verification_gas_limit = 500_000,
        .pre_verification_gas = 100_000,
        .max_fee_per_gas = 1_000_000_000,
        .max_priority_fee_per_gas = 1_000_000_000,
        .paymaster_and_data = &[_]u8{},
    };

    // Sign with stub signature for estimation
    var val = ecdsa.validator();
    const entry_point = try Address.fromHex(core.ENTRY_POINT_V07);
    const chain_id_str = getEnvOr("E2E_CHAIN_ID", "8453");
    const chain_id = try std.fmt.parseInt(u64, chain_id_str, 10);
    const hash = user_op.computeHash(entry_point, @as(u256, chain_id));
    const sig = try val.signUserOp(hash.bytes);

    // Serialize to JSON
    const userop_json = try user_op.toJsonValue(allocator, &sig);
    defer json_rpc.freeValue(allocator, userop_json);

    // Estimate gas
    var bundler = try Client.init(allocator, bundler_url);
    defer bundler.deinit();
    const gas = try bundler_mod.estimateUserOperationGas(&bundler, allocator, userop_json, core.ENTRY_POINT_V07);

    try std.testing.expect(gas.call_gas_limit > 0);
    try std.testing.expect(gas.verification_gas_limit > 0);
    try std.testing.expect(gas.pre_verification_gas > 0);

    std.log.info("Gas estimate — callGas: {d}, verifGas: {d}, preVerifGas: {d}", .{
        gas.call_gas_limit, gas.verification_gas_limit, gas.pre_verification_gas,
    });
}

test "e2e: full pipeline — build, estimate, sign, send UserOp" {
    if (skipIfNoEnv()) return;
    const allocator = std.testing.allocator;
    const rpc_url = getEnvOr("E2E_RPC_URL", "");
    const bundler_url = getEnvOr("E2E_BUNDLER_URL", "");
    if (bundler_url.len == 0) return;

    const pk_hex = getEnvOr("E2E_PRIVATE_KEY", "");
    if (pk_hex.len == 0) return;

    const chain_id_str = getEnvOr("E2E_CHAIN_ID", "8453");
    const chain_id = try std.fmt.parseInt(u64, chain_id_str, 10);

    const pk_bytes = try hexToBytes32(pk_hex);
    var ecdsa = try EcdsaValidator.init(allocator, pk_bytes);
    const sender = try create2.getKernelAddress(ecdsa.owner_address, 0, .v3_3);

    var rpc = try Client.init(allocator, rpc_url);
    defer rpc.deinit();
    var bundler = try Client.init(allocator, bundler_url);
    defer bundler.deinit();

    // Step 1: Fund the smart account
    try fundAccount(&rpc, allocator, sender);
    std.log.info("Step 1: Funded smart account", .{});

    // Step 2: Build calldata (send 0 ETH to self — noop execution)
    const exec = kernel_mod.Execution{
        .to = sender,
        .value = 0,
        .data = &[_]u8{},
    };
    const call_data = try kernel_mod.encodeExecute(allocator, exec);
    defer allocator.free(call_data);

    // Build init_code (factory + factoryData)
    const factory_data = try create2.buildFactoryCalldata(allocator, ecdsa.owner_address, 0, .v3_3);
    defer allocator.free(factory_data);
    const meta_factory = try Address.fromHex(core.META_FACTORY);
    const init_code = try allocator.alloc(u8, 20 + factory_data.len);
    defer allocator.free(init_code);
    @memcpy(init_code[0..20], &meta_factory.bytes);
    @memcpy(init_code[20..], factory_data);

    // Get nonce
    const nonce = try entrypoint_mod.getNonce(&rpc, allocator, core.ENTRY_POINT_V07, sender, 0);
    std.log.info("Step 2: Built UserOp, nonce={d}", .{nonce});

    // Step 3: Build UserOp with stub gas for estimation
    var user_op = userop_mod.UserOp{
        .sender = sender,
        .nonce = nonce,
        .init_code = init_code,
        .call_data = call_data,
        .call_gas_limit = 200_000,
        .verification_gas_limit = 1_000_000,
        .pre_verification_gas = 100_000,
        .max_fee_per_gas = 10_000_000_000,
        .max_priority_fee_per_gas = 2_000_000_000,
        .paymaster_and_data = &[_]u8{},
    };

    // Sign with real key for estimation (bundler validates signature during simulation)
    const entry_point = try Address.fromHex(core.ENTRY_POINT_V07);
    var val = ecdsa.validator();
    const est_hash = user_op.computeHash(entry_point, @as(u256, chain_id));
    const est_sig = try val.signUserOp(est_hash.bytes);

    // Serialize and estimate gas
    const est_json = try user_op.toJsonValue(allocator, &est_sig);
    defer json_rpc.freeValue(allocator, est_json);

    const gas = try bundler_mod.estimateUserOperationGas(&bundler, allocator, est_json, core.ENTRY_POINT_V07);
    std.log.info("Step 3: Gas estimate — call={d}, verif={d}, preVerif={d}", .{
        gas.call_gas_limit, gas.verification_gas_limit, gas.pre_verification_gas,
    });

    // Step 4: Apply gas estimates (with 20% buffer)
    user_op.call_gas_limit = gas.call_gas_limit + gas.call_gas_limit / 5;
    user_op.verification_gas_limit = gas.verification_gas_limit + gas.verification_gas_limit / 5;
    const pvg_u128: u128 = @truncate(gas.pre_verification_gas);
    user_op.pre_verification_gas = gas.pre_verification_gas + pvg_u128 / 5;

    // Step 5: Hash and sign with updated gas values
    const op_hash = user_op.computeHash(entry_point, @as(u256, chain_id));
    const real_sig = try val.signUserOp(op_hash.bytes);
    std.log.info("Step 5: Signed UserOp, hash first4: {x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        op_hash.bytes[0], op_hash.bytes[1], op_hash.bytes[2], op_hash.bytes[3],
    });

    // Step 6: Serialize final UserOp and send
    const send_json = try user_op.toJsonValue(allocator, &real_sig);
    defer json_rpc.freeValue(allocator, send_json);

    const op_hash_hex = try bundler_mod.sendUserOperation(&bundler, allocator, send_json, core.ENTRY_POINT_V07);
    defer allocator.free(op_hash_hex);
    std.log.info("Step 6: Sent UserOp, hash: {s}", .{op_hash_hex});
    try std.testing.expect(op_hash_hex.len > 0);

    // Step 7: Poll for receipt
    var receipt_opt: ?bundler_mod.UserOpReceipt = null;
    var attempts: u32 = 0;
    while (attempts < 30) : (attempts += 1) {
        receipt_opt = try bundler_mod.getUserOperationReceipt(&bundler, allocator, op_hash_hex);
        if (receipt_opt != null) break;
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }

    if (receipt_opt) |receipt| {
        defer receipt.deinit(allocator);
        std.log.info("Step 7: Receipt — success={}, gasUsed={d}, tx={s}", .{
            receipt.success, receipt.actual_gas_used, receipt.tx_hash,
        });
        try std.testing.expect(receipt.success);
        try std.testing.expect(receipt.actual_gas_used > 0);
    } else {
        std.log.err("Step 7: No receipt after 15 seconds!", .{});
        return error.TestUnexpectedResult;
    }

    // Step 8: Verify account is now deployed
    const code = try rpc.getCode(sender);
    defer allocator.free(code);
    try std.testing.expect(code.len > 0);
    std.log.info("Step 8: Account deployed, code size={d} bytes", .{code.len});
}

test "e2e: second UserOp (no init_code) on deployed account" {
    if (skipIfNoEnv()) return;
    const allocator = std.testing.allocator;
    const rpc_url = getEnvOr("E2E_RPC_URL", "");
    const bundler_url = getEnvOr("E2E_BUNDLER_URL", "");
    if (bundler_url.len == 0) return;

    const pk_hex = getEnvOr("E2E_PRIVATE_KEY", "");
    if (pk_hex.len == 0) return;

    const chain_id_str = getEnvOr("E2E_CHAIN_ID", "8453");
    const chain_id = try std.fmt.parseInt(u64, chain_id_str, 10);

    const pk_bytes = try hexToBytes32(pk_hex);
    var ecdsa = try EcdsaValidator.init(allocator, pk_bytes);
    const sender = try create2.getKernelAddress(ecdsa.owner_address, 0, .v3_3);

    var rpc = try Client.init(allocator, rpc_url);
    defer rpc.deinit();
    var bundler = try Client.init(allocator, bundler_url);
    defer bundler.deinit();

    // Ensure account is deployed + funded (from previous test or do it here)
    try fundAccount(&rpc, allocator, sender);

    // Check if account is already deployed
    const code = try rpc.getCode(sender);
    defer allocator.free(code);
    if (code.len == 0) {
        std.log.warn("Account not deployed yet, skipping second UserOp test", .{});
        return;
    }

    // Get current nonce
    const nonce = try entrypoint_mod.getNonce(&rpc, allocator, core.ENTRY_POINT_V07, sender, 0);
    std.log.info("Second UserOp: nonce={d}", .{nonce});

    // Build calldata: send 0 ETH to self
    const exec = kernel_mod.Execution{
        .to = sender,
        .value = 0,
        .data = &[_]u8{},
    };
    const call_data = try kernel_mod.encodeExecute(allocator, exec);
    defer allocator.free(call_data);

    // No init_code for already-deployed account
    var user_op = userop_mod.UserOp{
        .sender = sender,
        .nonce = nonce,
        .init_code = &[_]u8{},
        .call_data = call_data,
        .call_gas_limit = 200_000,
        .verification_gas_limit = 500_000,
        .pre_verification_gas = 100_000,
        .max_fee_per_gas = 10_000_000_000,
        .max_priority_fee_per_gas = 2_000_000_000,
        .paymaster_and_data = &[_]u8{},
    };

    // Sign with real key for estimation
    const entry_point = try Address.fromHex(core.ENTRY_POINT_V07);
    var val = ecdsa.validator();
    const est_hash = user_op.computeHash(entry_point, @as(u256, chain_id));
    const est_sig = try val.signUserOp(est_hash.bytes);

    const est_json = try user_op.toJsonValue(allocator, &est_sig);
    defer json_rpc.freeValue(allocator, est_json);

    const gas = try bundler_mod.estimateUserOperationGas(&bundler, allocator, est_json, core.ENTRY_POINT_V07);

    // Apply gas with buffer
    user_op.call_gas_limit = gas.call_gas_limit + gas.call_gas_limit / 5;
    user_op.verification_gas_limit = gas.verification_gas_limit + gas.verification_gas_limit / 5;
    const pvg_u128: u128 = @truncate(gas.pre_verification_gas);
    user_op.pre_verification_gas = gas.pre_verification_gas + pvg_u128 / 5;

    // Sign with updated gas values
    const op_hash = user_op.computeHash(entry_point, @as(u256, chain_id));
    const sig = try val.signUserOp(op_hash.bytes);

    // Send
    const send_json = try user_op.toJsonValue(allocator, &sig);
    defer json_rpc.freeValue(allocator, send_json);

    const op_hash_hex = try bundler_mod.sendUserOperation(&bundler, allocator, send_json, core.ENTRY_POINT_V07);
    defer allocator.free(op_hash_hex);
    std.log.info("Second UserOp sent, hash: {s}", .{op_hash_hex});

    // Poll for receipt
    var receipt_opt: ?bundler_mod.UserOpReceipt = null;
    var attempts: u32 = 0;
    while (attempts < 30) : (attempts += 1) {
        receipt_opt = try bundler_mod.getUserOperationReceipt(&bundler, allocator, op_hash_hex);
        if (receipt_opt != null) break;
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }

    if (receipt_opt) |receipt| {
        defer receipt.deinit(allocator);
        std.log.info("Second UserOp receipt — success={}, gasUsed={d}", .{
            receipt.success, receipt.actual_gas_used,
        });
        try std.testing.expect(receipt.success);
    } else {
        std.log.err("No receipt for second UserOp!", .{});
        return error.TestUnexpectedResult;
    }

    // Verify nonce incremented
    const new_nonce = try entrypoint_mod.getNonce(&rpc, allocator, core.ENTRY_POINT_V07, sender, 0);
    try std.testing.expect(new_nonce > nonce);
    std.log.info("Nonce incremented: {d} -> {d}", .{ nonce, new_nonce });
}
