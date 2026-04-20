//! Custom Signer — delegates signing to host-provided C vtable function pointers.
//!
//! Enables host languages to implement arbitrary signing logic (Privy, HSM,
//! MPC, etc.) while conforming to the Signer interface.

const std = @import("std");
const signer_mod = @import("signer.zig");
const Signer = signer_mod.Signer;
const Signature = signer_mod.Signature;
const SignerError = signer_mod.SignerError;
const Authorization = signer_mod.Authorization;

/// Layout of the authorization-out struct exposed to C. Must match the
/// `aa_authorization_t` defined in include/aa.h.
pub const CAuthorization = extern struct {
    chain_id: u64,
    address: [20]u8,
    nonce: u64,
    y_parity: u8,
    r: [32]u8,
    s: [32]u8,
};

/// C-compatible signer vtable. Each function returns 0 on success, non-zero on error.
/// Fields are appended at the END — existing consumers who pass a struct without
/// sign_authorization must still work. `sign_authorization` is treated as optional:
/// NULL means "fall back to sign_hash over the EIP-7702 auth hash".
pub const CVTable = extern struct {
    sign_hash: *const fn (?*anyopaque, *const [32]u8, *[65]u8) callconv(.c) c_int,
    sign_message: *const fn (?*anyopaque, ?[*]const u8, usize, *[65]u8) callconv(.c) c_int,
    sign_typed_data_hash: *const fn (?*anyopaque, *const [32]u8, *[65]u8) callconv(.c) c_int,
    get_address: *const fn (?*anyopaque, *[20]u8) callconv(.c) c_int,
    sign_authorization: ?*const fn (?*anyopaque, u64, *const [20]u8, u64, *CAuthorization) callconv(.c) c_int = null,
};

pub const CustomSigner = struct {
    vtable: *const CVTable,
    user_ctx: ?*anyopaque,

    pub fn signer(self: *CustomSigner) Signer {
        return .{
            .ptr = @ptrCast(self),
            .getAddressFn = getAddressImpl,
            .signHashFn = signHashImpl,
            .signMessageFn = signMessageImpl,
            .signTypedDataHashFn = signTypedDataHashImpl,
            .signAuthorizationFn = signAuthorizationImpl,
        };
    }

    fn signAuthorizationImpl(
        ptr: *anyopaque,
        chain_id: u64,
        address: [20]u8,
        nonce: u64,
    ) SignerError!Authorization {
        const self: *CustomSigner = @ptrCast(@alignCast(ptr));
        if (self.vtable.sign_authorization) |f| {
            var out: CAuthorization = undefined;
            const result = f(self.user_ctx, chain_id, &address, nonce, &out);
            if (result != 0) return SignerError.SigningFailed;
            return .{
                .chain_id = out.chain_id,
                .address = out.address,
                .nonce = out.nonce,
                .y_parity = out.y_parity,
                .r = out.r,
                .s = out.s,
            };
        }
        // Fall back to default: hash and signHash.
        const s = self.signer();
        return signer_mod.defaultSignAuthorization(s, chain_id, address, nonce);
    }

    fn getAddressImpl(ptr: *anyopaque) [20]u8 {
        const self: *CustomSigner = @ptrCast(@alignCast(ptr));
        var addr: [20]u8 = undefined;
        _ = self.vtable.get_address(self.user_ctx, &addr);
        return addr;
    }

    fn signHashImpl(ptr: *anyopaque, hash: [32]u8) SignerError!Signature {
        const self: *CustomSigner = @ptrCast(@alignCast(ptr));
        var sig_bytes: [65]u8 = undefined;
        const result = self.vtable.sign_hash(self.user_ctx, &hash, &sig_bytes);
        if (result != 0) return SignerError.SigningFailed;
        return Signature.fromBytes(sig_bytes);
    }

    fn signMessageImpl(ptr: *anyopaque, message: []const u8) SignerError!Signature {
        const self: *CustomSigner = @ptrCast(@alignCast(ptr));
        var sig_bytes: [65]u8 = undefined;
        const result = self.vtable.sign_message(
            self.user_ctx,
            if (message.len > 0) message.ptr else null,
            message.len,
            &sig_bytes,
        );
        if (result != 0) return SignerError.SigningFailed;
        return Signature.fromBytes(sig_bytes);
    }

    fn signTypedDataHashImpl(ptr: *anyopaque, hash: [32]u8) SignerError!Signature {
        const self: *CustomSigner = @ptrCast(@alignCast(ptr));
        var sig_bytes: [65]u8 = undefined;
        const result = self.vtable.sign_typed_data_hash(self.user_ctx, &hash, &sig_bytes);
        if (result != 0) return SignerError.SigningFailed;
        return Signature.fromBytes(sig_bytes);
    }
};
