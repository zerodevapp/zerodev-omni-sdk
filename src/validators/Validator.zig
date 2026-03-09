//! Validator plugin interface for account abstraction.
//!
//! New validators implement this vtable. Host languages pick from
//! compiled-in validators via the C API — no FFI callbacks needed.

const std = @import("std");
const zigeth = @import("zigeth");

const Address = zigeth.primitives.Address;

pub const SignError = error{
    SigningFailed,
    InvalidKey,
    OutOfMemory,
};

pub const Validator = struct {
    ptr: *anyopaque,
    signUserOpFn: *const fn (*anyopaque, user_op_hash: [32]u8) SignError![65]u8,
    getEnableDataFn: *const fn (*anyopaque) []const u8,
    getStubSignatureFn: *const fn (*anyopaque) [65]u8,
    getIdentifierFn: *const fn (*anyopaque) [20]u8,
    getNonceKeyFn: *const fn (*anyopaque) u192,

    pub fn signUserOp(self: Validator, hash: [32]u8) SignError![65]u8 {
        return self.signUserOpFn(self.ptr, hash);
    }

    pub fn getEnableData(self: Validator) []const u8 {
        return self.getEnableDataFn(self.ptr);
    }

    pub fn getStubSignature(self: Validator) [65]u8 {
        return self.getStubSignatureFn(self.ptr);
    }

    pub fn getIdentifier(self: Validator) [20]u8 {
        return self.getIdentifierFn(self.ptr);
    }

    pub fn getNonceKey(self: Validator) u192 {
        return self.getNonceKeyFn(self.ptr);
    }
};
