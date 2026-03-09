//! ZeroDev Omni SDK — Account Abstraction library with C API.
//!
//! Provides Kernel v3.3 smart account operations, ECDSA validator,
//! and a C-compatible API for cross-language bindings.

const std = @import("std");

pub const core = @import("core/root.zig");
pub const transport = struct {
    pub const http = @import("transport/http.zig");
    pub const json_rpc = @import("transport/json_rpc.zig");
};
pub const validators = struct {
    pub const Validator = @import("validators/Validator.zig").Validator;
    pub const EcdsaValidator = @import("validators/ecdsa.zig").EcdsaValidator;
};

// Re-export commonly used types
pub const KernelVersion = core.KernelVersion;
pub const getKernelAddress = core.getKernelAddress;
pub const UserOp = core.userop.UserOp;

test {
    std.testing.refAllDecls(@This());
}
