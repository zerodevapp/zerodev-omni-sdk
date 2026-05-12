//! Local Signer — signs using a private key via zabi's ECDSA Signer.
//!
//! Wraps zabi's `Signer` (low-S, RFC 6979 deterministic) behind our Signer
//! interface. Handles EIP-191 personal_sign wrapping in signMessage.

const std = @import("std");
const zabi = @import("zabi");
const signer_mod = @import("signer.zig");
const Signer = signer_mod.Signer;
const Signature = signer_mod.Signature;
const SignerError = signer_mod.SignerError;

const ZabiSigner = zabi.crypto.Signer;
const ZabiSignature = zabi.crypto.signature.Signature;

pub const LocalSigner = struct {
    inner: ZabiSigner,
    address_bytes: [20]u8,

    pub fn init(allocator: std.mem.Allocator, private_key: [32]u8) !LocalSigner {
        _ = allocator; // zabi's Signer is stack-only — no allocator needed.
        const inner = try ZabiSigner.init(private_key);
        return .{
            .inner = inner,
            .address_bytes = inner.address_bytes,
        };
    }

    pub fn signer(self: *LocalSigner) Signer {
        return .{
            .ptr = @ptrCast(self),
            .getAddressFn = getAddressImpl,
            .signHashFn = signHashImpl,
            .signMessageFn = signMessageImpl,
            .signTypedDataHashFn = signHashImpl, // EIP-712 hash is already prefixed
            // signAuthorizationFn left null — default path computes the auth hash
            // and calls signHash, which is exactly what we want here.
        };
    }

    fn getAddressImpl(ptr: *anyopaque) [20]u8 {
        const self: *LocalSigner = @ptrCast(@alignCast(ptr));
        return self.address_bytes;
    }

    fn signHashImpl(ptr: *anyopaque, hash: [32]u8) SignerError!Signature {
        const self: *LocalSigner = @ptrCast(@alignCast(ptr));
        const z_sig = self.inner.sign(hash) catch return SignerError.SigningFailed;
        return zabiToLocal(z_sig);
    }

    fn signMessageImpl(ptr: *anyopaque, message: []const u8) SignerError!Signature {
        // EIP-191: keccak256("\x19Ethereum Signed Message:\n" + len(message) + message)
        const prefix = "\x19Ethereum Signed Message:\n";
        var len_buf: [20]u8 = undefined;
        const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{message.len}) catch
            return SignerError.OutOfMemory;

        var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
        hasher.update(prefix);
        hasher.update(len_str);
        hasher.update(message);
        var msg_hash: [32]u8 = undefined;
        hasher.final(&msg_hash);

        return signHashImpl(ptr, msg_hash);
    }
};

/// Convert zabi's `Signature{r:u256, s:u256, v:u2}` into our wire format
/// (`r:[32]u8, s:[32]u8, v:u8`). Apply Ethereum's +27 convention to v.
fn zabiToLocal(z_sig: ZabiSignature) Signature {
    var r_bytes: [32]u8 = undefined;
    var s_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &r_bytes, z_sig.r, .big);
    std.mem.writeInt(u256, &s_bytes, z_sig.s, .big);
    return .{
        .r = r_bytes,
        .s = s_bytes,
        // zabi returns 0 or 1 (raw y-parity); Ethereum personal_sign / userOp signatures
        // historically use 27 or 28. Match the previous zigeth-based behaviour.
        .v = @as(u8, z_sig.v) + 27,
    };
}

test "signAuthorization round-trip: recovered address matches signer" {
    const allocator = std.testing.allocator;

    var pk: [32]u8 = undefined;
    @memset(&pk, 0x11);

    var local = try LocalSigner.init(allocator, pk);
    const s = local.signer();
    const owner_addr = s.getAddress();

    const chain_id: u64 = 11155111;
    const target = [_]u8{
        0xd6, 0xce, 0xdd, 0xe8, 0x4b, 0xe4, 0x08, 0x93, 0xd1, 0x53,
        0xbe, 0x9d, 0x46, 0x7c, 0xd6, 0xad, 0x37, 0x87, 0x5b, 0x28,
    };
    const nonce: u64 = 7;

    const auth = try s.signAuthorization(chain_id, target, nonce);
    try std.testing.expectEqual(chain_id, auth.chain_id);
    try std.testing.expectEqualSlices(u8, &target, &auth.address);
    try std.testing.expectEqual(nonce, auth.nonce);

    // Re-derive the hash locally and recover the signer.
    var rlp_buf: [64]u8 = undefined;
    var payload: [40]u8 = undefined;
    var p: usize = 0;
    // chainId (11155111 = 0xaa36a7)
    payload[p] = 0x83;
    p += 1;
    payload[p] = 0xaa;
    payload[p + 1] = 0x36;
    payload[p + 2] = 0xa7;
    p += 3;
    payload[p] = 0x94;
    p += 1;
    @memcpy(payload[p .. p + 20], &target);
    p += 20;
    // nonce=7 (<0x80 → as itself)
    payload[p] = 0x07;
    p += 1;
    rlp_buf[0] = 0xc0 + @as(u8, @intCast(p));
    @memcpy(rlp_buf[1 .. 1 + p], payload[0..p]);

    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(&[_]u8{0x05});
    hasher.update(rlp_buf[0 .. 1 + p]);
    var hash_bytes: [32]u8 = undefined;
    hasher.final(&hash_bytes);

    // Recover via zabi's static recovery helper. y_parity is stored as raw
    // 0/1, so the recovered signature passes v=y_parity directly.
    var r_u: u256 = 0;
    var s_u: u256 = 0;
    r_u = std.mem.readInt(u256, &auth.r, .big);
    s_u = std.mem.readInt(u256, &auth.s, .big);
    const recovered_addr = try ZabiSigner.recoverAddress(.{
        .r = r_u,
        .s = s_u,
        .v = @intCast(auth.y_parity),
    }, hash_bytes);
    try std.testing.expectEqualSlices(u8, &owner_addr, &recovered_addr);
}
