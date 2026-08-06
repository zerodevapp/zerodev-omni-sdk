//! Validator plugin interface for account abstraction.
//!
//! New validators implement this vtable. Host languages pick from
//! compiled-in validators via the C API — no FFI callbacks needed.

const std = @import("std");
const primitives = @import("primitives");

const Address = primitives.Address;

pub const SignError = error{
    SigningFailed,
    InvalidKey,
    OutOfMemory,
};

pub const Validator = struct {
    ptr: *anyopaque,
    // The real signature is variable-length: an ECDSA validator returns 65
    // bytes, a WebAuthn validator an ABI-encoded assertion, a weighted validator
    // a concatenation of member signatures. Its size depends on runtime data
    // (e.g. the clientDataJSON in a WebAuthn assertion), so it's built into a
    // caller-provided allocator; in practice that's an arena dropped after the
    // UserOp is built. The stub, by contrast, is a fixed dummy of the same shape
    // and so is a borrowed constant, mirroring getEnableData — no allocation.
    signUserOpFn: *const fn (*anyopaque, allocator: std.mem.Allocator, user_op_hash: [32]u8) SignError![]u8,
    getEnableDataFn: *const fn (*anyopaque) []const u8,
    getStubSignatureFn: *const fn (*anyopaque) []const u8,
    getIdentifierFn: *const fn (*anyopaque) [20]u8,
    getNonceKeyFn: *const fn (*anyopaque) u192,

    pub fn signUserOp(self: Validator, allocator: std.mem.Allocator, hash: [32]u8) SignError![]u8 {
        return self.signUserOpFn(self.ptr, allocator, hash);
    }

    pub fn getEnableData(self: Validator) []const u8 {
        return self.getEnableDataFn(self.ptr);
    }

    // A dummy signature of the same shape as a real one, for gas estimation
    // before the real signature exists. For validators whose real signing needs
    // a user gesture (WebAuthn / Face ID), estimating against this stub avoids
    // prompting the user more than once per UserOp.
    pub fn getStubSignature(self: Validator) []const u8 {
        return self.getStubSignatureFn(self.ptr);
    }

    pub fn getIdentifier(self: Validator) [20]u8 {
        return self.getIdentifierFn(self.ptr);
    }

    pub fn getNonceKey(self: Validator) u192 {
        return self.getNonceKeyFn(self.ptr);
    }
};
