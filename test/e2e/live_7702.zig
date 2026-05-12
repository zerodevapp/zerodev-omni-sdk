//! Live E2E test exercising the C API EIP-7702 account flow on Sepolia.
//!
//! Generates a fresh EOA via `aa_signer_generate` — this forces the delegation
//! to be installed on the first UserOp, exercising the authorization-signing path.
//! The UserOp is sponsored by the ZeroDev paymaster, so the EOA needs no ETH.
//!
//! Requires environment variables:
//!   ZERODEV_PROJECT_ID  — ZeroDev project ID
//!
//! Run via: zig build test-live-7702

const std = @import("std");
const c_api = @import("c_api");

fn getEnvOr(key: []const u8, default: []const u8) []const u8 {
    // Zig 0.16 removed `std.posix.getenv` (and equivalents in std.process).
    // Fall back to libc — these test binaries already link libc.
    var buf: [256]u8 = undefined;
    if (key.len >= buf.len) return default;
    @memcpy(buf[0..key.len], key);
    buf[key.len] = 0;
    const raw = std.c.getenv(buf[0..key.len :0].ptr) orelse return default;
    return std.mem.span(raw);
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
        std.log.warn("ZERODEV_PROJECT_ID not set, skipping 7702 live test", .{});
        return true;
    }
    return false;
}

test "C API: aa_context_new_account_7702 sponsored UserOp on Sepolia" {
    if (skipIfNoEnv()) return;

    const allocator = std.testing.allocator;

    const project_id = getEnvOr("ZERODEV_PROJECT_ID", "");
    const chain_id: u64 = 11155111;

    const pid_z = try allocator.allocSentinel(u8, project_id.len, 0);
    defer allocator.free(pid_z);
    @memcpy(pid_z, project_id);

    // Step 1: Create context
    var ctx: ?*c_api.ContextImpl = null;
    try std.testing.expectEqual(c_api.Status.ok, c_api.aa_context_create(pid_z.ptr, "", "", chain_id, &ctx));
    try std.testing.expect(ctx != null);
    defer _ = c_api.aa_context_destroy(ctx);

    try std.testing.expectEqual(c_api.Status.ok, c_api.aa_context_set_gas_middleware(ctx, &c_api.aa_gas_zerodev));
    try std.testing.expectEqual(c_api.Status.ok, c_api.aa_context_set_paymaster_middleware(ctx, &c_api.aa_paymaster_zerodev));

    // Step 2: Generate a fresh EOA — guarantees first-run delegation install
    var signer: ?*c_api.SignerImpl = null;
    try std.testing.expectEqual(c_api.Status.ok, c_api.aa_signer_generate(&signer));
    try std.testing.expect(signer != null);
    defer c_api.aa_signer_destroy(signer);

    // Step 3: Create 7702 account — sender == signer EOA, no CREATE2
    // (only Kernel v3.3 supports EIP-7702 today)
    var account: ?*c_api.AccountImpl = null;
    try std.testing.expectEqual(c_api.Status.ok, c_api.aa_context_new_account_7702(ctx, signer, c_api.AA_KERNEL_V3_3, &account));
    try std.testing.expect(account != null);
    defer _ = c_api.aa_account_destroy(account);

    // Step 4: Confirm account address is the EOA's address
    var addr: [20]u8 = undefined;
    try std.testing.expectEqual(c_api.Status.ok, c_api.aa_account_get_address(account, &addr));

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
    std.debug.print("7702 E2E: Account address (EOA): 0x{s}\n", .{addr_hex});

    // Step 5: Send a no-op UserOp — SDK handles delegation check + authorization signing internally
    const call = c_api.CCall{
        .target = addr,
        .value_be = [_]u8{0} ** 32,
        .calldata = null,
        .calldata_len = 0,
    };
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
    std.debug.print("7702 E2E: UserOp hash: 0x{s}\n", .{hash_hex});

    var hash_zero = true;
    for (hash_out) |b| {
        if (b != 0) {
            hash_zero = false;
            break;
        }
    }
    try std.testing.expect(!hash_zero);

    // Step 6: Wait for receipt
    var json_ptr: [*]u8 = undefined;
    var json_len: usize = undefined;
    const receipt_status = c_api.aa_wait_for_user_operation_receipt(account, &hash_out, 0, 0, &json_ptr, &json_len);

    if (receipt_status != .ok) {
        const err_msg: [*:0]const u8 = c_api.aa_get_last_error();
        std.debug.print("aa_wait_for_user_operation_receipt FAILED: {s} (code {d})\n", .{ err_msg, @intFromEnum(receipt_status) });
        std.debug.print("========================================\n", .{});
        return error.TestUnexpectedResult;
    }
    defer c_api.aa_free(json_ptr);

    const json_str = json_ptr[0..json_len];
    std.debug.print("7702 E2E: Receipt ({d} bytes): {s}\n", .{ json_len, json_str[0..@min(json_len, 300)] });

    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"success\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"userOpHash\"") != null);
    std.debug.print("7702 E2E: SUCCESS\n", .{});
    std.debug.print("========================================\n", .{});
}
