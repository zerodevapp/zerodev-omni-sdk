//! ECDSA validator plugin for Kernel v3 smart accounts.
//!
//! Wraps any Signer implementation with the on-chain ECDSA validator
//! contract metadata (address, nonce key, enable data, stub signature).

const std = @import("std");
const zigeth = @import("zigeth");
const Validator = @import("Validator.zig").Validator;
const SignError = @import("Validator.zig").SignError;
const signers = @import("signers");
const Signer = signers.Signer;

const Address = zigeth.primitives.Address;

/// ECDSA Validator address (shared across all Kernel versions)
pub const ECDSA_VALIDATOR_ADDR = [20]u8{
    0x84, 0x5A, 0xDb, 0x2C, 0x71, 0x11, 0x29, 0xd4, 0xf3, 0x96,
    0x67, 0x35, 0xeD, 0x98, 0xa9, 0xF0, 0x9f, 0xC4, 0xcE, 0x57,
};

pub const EcdsaValidator = struct {
    signer: Signer,
    owner_address: Address,

    /// The Signer's ptr must point to stable memory (heap or struct field).
    /// The caller keeps the backing signer alive.
    pub fn init(s: Signer) EcdsaValidator {
        return .{
            .signer = s,
            .owner_address = Address.fromBytes(s.getAddress()),
        };
    }

    pub fn validator(self: *EcdsaValidator) Validator {
        return .{
            .ptr = @ptrCast(self),
            .signUserOpFn = signUserOpImpl,
            .getEnableDataFn = getEnableDataImpl,
            .getStubSignatureFn = getStubSignatureImpl,
            .getIdentifierFn = getIdentifierImpl,
            .getNonceKeyFn = getNonceKeyImpl,
        };
    }

    fn signUserOpImpl(ptr: *anyopaque, user_op_hash: [32]u8) SignError![65]u8 {
        const self: *EcdsaValidator = @ptrCast(@alignCast(ptr));
        const sig = self.signer.signMessage(&user_op_hash) catch return SignError.SigningFailed;
        return sig.toBytes();
    }

    fn getEnableDataImpl(ptr: *anyopaque) []const u8 {
        const self: *EcdsaValidator = @ptrCast(@alignCast(ptr));
        return &self.owner_address.bytes;
    }

    fn getStubSignatureImpl(_: *anyopaque) [65]u8 {
        return [_]u8{0} ** 65;
    }

    fn getIdentifierImpl(_: *anyopaque) [20]u8 {
        return ECDSA_VALIDATOR_ADDR;
    }

    fn getNonceKeyImpl(_: *anyopaque) u192 {
        return 0;
    }
};
