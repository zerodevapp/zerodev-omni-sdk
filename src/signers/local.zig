//! Local Signer — signs using a private key via zigeth's Wallet.
//!
//! Wraps zigeth's secp256k1 Wallet behind the Signer interface.
//! Handles EIP-191 personal_sign wrapping in signMessage.

const std = @import("std");
const zigeth = @import("zigeth");
const signer_mod = @import("signer.zig");
const Signer = signer_mod.Signer;
const Signature = signer_mod.Signature;
const SignerError = signer_mod.SignerError;

const Wallet = zigeth.signer.Wallet;
const PrivateKey = zigeth.crypto.secp256k1.PrivateKey;
const keccak = zigeth.crypto.keccak;

pub const LocalSigner = struct {
    wallet: Wallet,
    address_bytes: [20]u8,

    pub fn init(allocator: std.mem.Allocator, private_key: [32]u8) !LocalSigner {
        const pk = try PrivateKey.fromBytes(private_key);
        const wallet = try Wallet.init(allocator, pk);
        return .{
            .wallet = wallet,
            .address_bytes = wallet.address.bytes,
        };
    }

    pub fn signer(self: *LocalSigner) Signer {
        return .{
            .ptr = @ptrCast(self),
            .getAddressFn = getAddressImpl,
            .signHashFn = signHashImpl,
            .signMessageFn = signMessageImpl,
            .signTypedDataHashFn = signHashImpl, // EIP-712 hash is already prefixed
        };
    }

    fn getAddressImpl(ptr: *anyopaque) [20]u8 {
        const self: *LocalSigner = @ptrCast(@alignCast(ptr));
        return self.address_bytes;
    }

    fn signHashImpl(ptr: *anyopaque, hash: [32]u8) SignerError!Signature {
        const self: *LocalSigner = @ptrCast(@alignCast(ptr));
        const h = zigeth.primitives.Hash{ .bytes = hash };
        const sig = self.wallet.signer.signHash(h) catch return SignerError.SigningFailed;
        return .{
            .r = sig.r,
            .s = sig.s,
            .v = sig.v,
        };
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
