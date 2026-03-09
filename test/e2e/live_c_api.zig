//! Live E2E test exercising the C API orchestrator (aa_send_userop).
//!
//! This test calls the same exported C functions that Go/Rust/Swift would use,
//! proving the full pipeline works through the FFI boundary.
//!
//! Requires environment variables:
//!   ZERODEV_PROJECT_ID  — ZeroDev project ID
//!   E2E_PRIVATE_KEY     — 32-byte hex private key (no 0x prefix)
//!
//! Run via: zig build test-live-capi

const std = @import("std");
const c_api = @import("c_api");

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

fn fmtBytes(bytes: []const u8, buf: []u8) []const u8 {
    const hex_chars = "0123456789abcdef";
    const len = @min(bytes.len * 2, buf.len);
    for (bytes[0 .. len / 2], 0..) |b, i| {
        buf[i * 2] = hex_chars[b >> 4];
        buf[i * 2 + 1] = hex_chars[b & 0xf];
    }
    return buf[0..len];
}

fn skipIfNoEnv() bool {
    const project_id = getEnvOr("ZERODEV_PROJECT_ID", "");
    if (project_id.len == 0) {
        std.log.warn("ZERODEV_PROJECT_ID not set, skipping C API live tests", .{});
        return true;
    }
    return false;
}

test "C API: aa_send_userop full pipeline on Sepolia" {
    if (skipIfNoEnv()) return;

    const allocator = std.testing.allocator;

    const project_id = getEnvOr("ZERODEV_PROJECT_ID", "");
    const pk_hex = getEnvOr("E2E_PRIVATE_KEY", "");
    if (pk_hex.len == 0) return;

    const pk_bytes = try hexToBytes32(pk_hex);
    const chain_id: u64 = 11155111;

    // Null-terminate the project_id for C API
    const pid_z = try allocator.allocSentinel(u8, project_id.len, 0);
    defer allocator.free(pid_z);
    @memcpy(pid_z, project_id);

    // Step 1: Create context (empty rpc_url and bundler_url — derive from project_id)
    var ctx: ?*c_api.ContextImpl = null;
    const ctx_status = c_api.aa_context_create(pid_z.ptr, "", "", chain_id, &ctx);
    try std.testing.expectEqual(c_api.Status.ok, ctx_status);
    try std.testing.expect(ctx != null);
    defer _ = c_api.aa_context_destroy(ctx);

    // Plug in ZeroDev middleware (gas + paymaster)
    const gas_status = c_api.aa_context_set_gas_middleware(ctx, &c_api.aa_gas_zerodev);
    try std.testing.expectEqual(c_api.Status.ok, gas_status);
    const pm_status2 = c_api.aa_context_set_paymaster_middleware(ctx, &c_api.aa_paymaster_zerodev);
    try std.testing.expectEqual(c_api.Status.ok, pm_status2);

    // Step 2: Create account (Kernel v3.3 = version 2, index 0)
    var account: ?*c_api.AccountImpl = null;
    const acc_status = c_api.aa_account_create(ctx, &pk_bytes, 2, 0, &account);
    try std.testing.expectEqual(c_api.Status.ok, acc_status);
    try std.testing.expect(account != null);
    defer _ = c_api.aa_account_destroy(account);

    // Step 3: Get address
    var addr: [20]u8 = undefined;
    const addr_status = c_api.aa_account_get_address(account, &addr);
    try std.testing.expectEqual(c_api.Status.ok, addr_status);

    // Verify address is non-zero
    var all_zero = true;
    for (addr) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try std.testing.expect(!all_zero);

    var addr_hex_buf: [40]u8 = undefined;
    const addr_hex = fmtBytes(&addr, &addr_hex_buf);
    std.debug.print("\n========================================\n", .{});
    std.debug.print("C API TEST: Account address: 0x{s}\n", .{addr_hex});

    // Step 4: Build a call (send 0 ETH to self — noop)
    const call = c_api.CCall{
        .target = addr,
        .value_be = [_]u8{0} ** 32,
        .calldata = null,
        .calldata_len = 0,
    };

    // Step 5: Send UserOp via the high-level orchestrator — THIS IS THE KEY TEST
    var calls_arr = [_]c_api.CCall{call};
    var hash_out: [32]u8 = undefined;
    const send_status = c_api.aa_send_userop(account, @as([*]const c_api.CCall, &calls_arr), 1, &hash_out);

    if (send_status != .ok) {
        const err_msg: [*:0]const u8 = c_api.aa_get_last_error();
        std.debug.print("aa_send_userop FAILED: {s} (code {d})\n", .{ err_msg, @intFromEnum(send_status) });
        std.debug.print("========================================\n", .{});
        return error.TestUnexpectedResult;
    }

    var hash_hex_buf: [64]u8 = undefined;
    const hash_hex = fmtBytes(&hash_out, &hash_hex_buf);
    std.debug.print("C API TEST: UserOp hash: 0x{s}\n", .{hash_hex});
    std.debug.print("C API TEST: aa_send_userop SUCCESS!\n", .{});
    std.debug.print("========================================\n", .{});

    // Verify hash is non-zero
    var hash_zero = true;
    for (hash_out) |b| {
        if (b != 0) {
            hash_zero = false;
            break;
        }
    }
    try std.testing.expect(!hash_zero);
}
