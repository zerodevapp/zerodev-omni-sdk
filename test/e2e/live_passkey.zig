//! Live E2E test: a passkey-owned Kernel account sends a sponsored UserOp on
//! Sepolia through the C API, using a software P-256 authenticator in place of
//! Face ID / Touch ID.
//!
//! This is the end-to-end proof for the passkey path that no unit test can give:
//!   - the low-level/high-level initCode for a WebAuthn root validator deploys
//!     the address the account claims (a fresh random key every run, so every
//!     run takes the deploy path);
//!   - the ceremony runs exactly once per UserOp and signs the FINAL op — the
//!     challenge it receives equals the userOpHash the bundler accepts, i.e. the
//!     hash over the op with paymaster data installed;
//!   - the paymaster accepts the structured WebAuthn stub in both phases;
//!   - the on-chain validator accepts a real assertion that went through the
//!     strict DER parser and low-S normalisation;
//!   - the assertion buffers are freed exactly once under the ownership contract.
//!
//! Requires: ZERODEV_PROJECT_ID. Run via: zig build test-live-passkey

const std = @import("std");
const c_api = @import("c_api");

const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

fn getEnvOr(key: []const u8, default: []const u8) []const u8 {
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

/// A software WebAuthn authenticator: holds a P-256 key and produces standard
/// assertions. Counts ceremonies and frees so the test can assert the "once"
/// and "exactly-once" contracts.
const SoftPasskey = struct {
    kp: Ecdsa.KeyPair,
    calls: usize = 0,
    frees: usize = 0,
    last_challenge: [32]u8 = [_]u8{0} ** 32,

    fn allocCopy(bytes: []const u8) ?[*]const u8 {
        const p: [*]u8 = @ptrCast(c_api.aa_alloc(bytes.len) orelse return null);
        @memcpy(p[0..bytes.len], bytes);
        return p;
    }

    fn sign(user_ctx: ?*anyopaque, challenge: *const [32]u8, out: *c_api.CWebAuthnAssertion) callconv(.c) c_int {
        const self: *SoftPasskey = @ptrCast(@alignCast(user_ctx.?));
        self.calls += 1;
        self.last_challenge = challenge.*;

        // authenticatorData = rpIdHash(32) || flags(1) || signCount(4, BE).
        // UP | UV set, as a platform authenticator with biometrics would.
        var auth_data: [37]u8 = undefined;
        Sha256.hash("zerodev.app", auth_data[0..32], .{});
        auth_data[32] = 0x05;
        std.mem.writeInt(u32, auth_data[33..37], @intCast(self.calls), .big);

        // clientDataJSON with challenge = base64url(userOpHash), unpadded — the
        // on-chain validator searches for exactly this "challenge":"…" pair.
        var b64: [43]u8 = undefined;
        const enc = std.base64.url_safe_no_pad.Encoder.encode(&b64, challenge);
        var cdj_buf: [256]u8 = undefined;
        const cdj = std.fmt.bufPrint(
            &cdj_buf,
            "{{\"type\":\"webauthn.get\",\"challenge\":\"{s}\",\"origin\":\"https://zerodev.app\",\"crossOrigin\":false}}",
            .{enc},
        ) catch return 1;

        // WebAuthn signs authenticatorData || SHA-256(clientDataJSON) with ES256.
        var cdj_hash: [32]u8 = undefined;
        Sha256.hash(cdj, &cdj_hash, .{});
        var msg: [69]u8 = undefined;
        @memcpy(msg[0..37], &auth_data);
        @memcpy(msg[37..69], &cdj_hash);
        const sig = self.kp.sign(&msg, null) catch return 1;
        var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
        const der = sig.toDer(&der_buf);

        // Hand over aa_alloc-owned copies; the SDK frees them.
        out.authenticator_data = allocCopy(&auth_data) orelse return 1;
        out.authenticator_data_len = auth_data.len;
        out.client_data_json = allocCopy(cdj) orelse return 1;
        out.client_data_json_len = cdj.len;
        out.der_signature = allocCopy(der) orelse return 1;
        out.der_signature_len = der.len;
        return 0;
    }

    fn free(user_ctx: ?*anyopaque, buf: [*]u8, _: usize) callconv(.c) void {
        const self: *SoftPasskey = @ptrCast(@alignCast(user_ctx.?));
        self.frees += 1;
        std.c.free(buf);
    }
};

test "passkey account: one ceremony, sponsored UserOp lands on Sepolia" {
    const project_id = getEnvOr("ZERODEV_PROJECT_ID", "");
    if (project_id.len == 0) {
        std.log.warn("ZERODEV_PROJECT_ID not set, skipping passkey live test", .{});
        return;
    }
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const chain_id: u64 = 11155111;

    const pid_z = try allocator.allocSentinel(u8, project_id.len, 0);
    defer allocator.free(pid_z);
    @memcpy(pid_z, project_id);

    var ctx: ?*c_api.ContextImpl = null;
    try std.testing.expectEqual(c_api.Status.ok, c_api.aa_context_create(pid_z.ptr, "", "", chain_id, &ctx));
    defer _ = c_api.aa_context_destroy(ctx);
    try std.testing.expectEqual(c_api.Status.ok, c_api.aa_context_set_gas_middleware(ctx, &c_api.aa_gas_zerodev));
    try std.testing.expectEqual(c_api.Status.ok, c_api.aa_context_set_paymaster_middleware(ctx, &c_api.aa_paymaster_zerodev));

    // Fresh credential every run → fresh counterfactual account → deploy path.
    var pk = SoftPasskey{ .kp = Ecdsa.KeyPair.generate(io) };
    try std.testing.expectEqual(c_api.Status.ok, c_api.aa_context_set_webauthn_free_fn(ctx, SoftPasskey.free));

    const sec1 = pk.kp.public_key.toUncompressedSec1(); // 0x04 || x || y
    var id_hash: [32]u8 = undefined;
    Sha256.hash("omni-sdk live passkey credential", &id_hash, .{});

    var account: ?*c_api.AccountImpl = null;
    const acc_status = c_api.aa_account_create_passkey(
        ctx,
        SoftPasskey.sign,
        &pk,
        sec1[1..33],
        sec1[33..65],
        &id_hash,
        2, // WebAuthn validator v0.0.3 (v0.0.1/v0.0.2 are on the paymaster vulnerable-contract blocklist)
        chain_id,
        c_api.AA_KERNEL_V3_3,
        0,
        &account,
    );
    try std.testing.expectEqual(c_api.Status.ok, acc_status);
    defer _ = c_api.aa_account_destroy(account);

    var addr: [20]u8 = undefined;
    try std.testing.expectEqual(c_api.Status.ok, c_api.aa_account_get_address(account, &addr));
    var addr_hex_buf: [40]u8 = undefined;
    std.debug.print("\n========================================\n", .{});
    std.debug.print("PASSKEY TEST: account 0x{s} (fresh)\n", .{fmtBytes(&addr, &addr_hex_buf)});

    // Send 0 ETH to self, sponsored.
    var calls_arr = [_]c_api.CCall{.{ .target = addr, .value_be = [_]u8{0} ** 32, .calldata = null, .calldata_len = 0 }};
    var hash_out: [32]u8 = undefined;
    const send_status = c_api.aa_send_userop(account, @as([*]const c_api.CCall, &calls_arr), 1, &hash_out);
    if (send_status != .ok) {
        std.debug.print("aa_send_userop FAILED: {s} (code {d})\nrpc: {s}\n", .{
            c_api.aa_get_last_error(), @intFromEnum(send_status), c_api.aa_get_last_rpc_error(),
        });
        return error.TestUnexpectedResult;
    }
    var hash_hex_buf: [64]u8 = undefined;
    std.debug.print("PASSKEY TEST: userOpHash 0x{s}\n", .{fmtBytes(&hash_out, &hash_hex_buf)});

    // Exactly one ceremony — the stub carried every earlier step — and it
    // signed the final op: its challenge is the hash the bundler accepted.
    try std.testing.expectEqual(@as(usize, 1), pk.calls);
    try std.testing.expectEqualSlices(u8, &hash_out, &pk.last_challenge);
    // Ownership: three buffers handed over, three freed.
    try std.testing.expectEqual(@as(usize, 3), pk.frees);

    var json_ptr: [*]u8 = undefined;
    var json_len: usize = undefined;
    const receipt_status = c_api.aa_wait_for_user_operation_receipt(account, &hash_out, 0, 0, &json_ptr, &json_len);
    if (receipt_status != .ok) {
        std.debug.print("receipt FAILED: {s} (code {d})\n", .{ c_api.aa_get_last_error(), @intFromEnum(receipt_status) });
        return error.TestUnexpectedResult;
    }
    defer c_api.aa_free(json_ptr);
    const json_str = json_ptr[0..json_len];
    std.debug.print("PASSKEY TEST: receipt ({d} bytes): {s}\n", .{ json_len, json_str[0..@min(json_len, 200)] });

    // Inclusion is not enough: the on-chain WebAuthn validator must have
    // accepted the assertion, i.e. the op executed successfully.
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"success\":true") != null);
    std.debug.print("PASSKEY TEST: SUCCESS — one ceremony, sponsored, executed on-chain\n", .{});
    std.debug.print("========================================\n", .{});
}
