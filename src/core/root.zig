//! ZeroDev-specific constants, Kernel v3.x addresses, and URL builder.

const std = @import("std");

pub const create2 = @import("create2.zig");
pub const kernel = @import("kernel.zig");
pub const userop = @import("userop.zig");
pub const entrypoint = @import("entrypoint.zig");
pub const bundler = @import("bundler.zig");
pub const paymaster = @import("paymaster.zig");
pub const rlp = @import("rlp.zig");
pub const authorization = @import("authorization.zig");
pub const erc1271 = @import("erc1271.zig");
pub const Authorization = authorization.Authorization;
pub const getKernelAddress = create2.getKernelAddress;

/// EIP-7702 delegation target — Kernel v3.3 implementation address (as bytes).
pub const KERNEL_V3_3_DELEGATION_TARGET: [20]u8 = [_]u8{
    0xd6, 0xce, 0xdd, 0xe8, 0x4b, 0xe4, 0x08, 0x93, 0xd1, 0x53,
    0xbe, 0x9d, 0x46, 0x7c, 0xd6, 0xad, 0x37, 0x87, 0x5b, 0x28,
};

/// Kernel smart account versions. Only v3.3 is supported today — earlier
/// versions were never wired into examples, e2e tests, or language bindings.
pub const KernelVersion = enum(u8) {
    v3_3 = 0,

    pub fn factoryAddress(self: KernelVersion) []const u8 {
        return switch (self) {
            .v3_3 => "0x2577507b78c2008Ff367261CB6285d44ba5eF2E9",
        };
    }

    /// The version string the deployed Kernel reports from eip712Domain(), which an
    /// ERC-1271 wrap must reproduce exactly for the digest to match on chain.
    pub fn eip712Version(self: KernelVersion) []const u8 {
        return switch (self) {
            .v3_3 => "0.3.3",
        };
    }

    pub fn implementationAddress(self: KernelVersion) []const u8 {
        return switch (self) {
            .v3_3 => "0xd6CEDDe84be40893d153Be9d467CD6aD37875b28",
        };
    }

    /// EIP-7702 delegation target for this Kernel version. Returns null for
    /// versions that don't support 7702. When a future Kernel version adds
    /// support, extend this switch to return its implementation address bytes.
    pub fn delegationTarget(self: KernelVersion) ?[20]u8 {
        return switch (self) {
            .v3_3 => KERNEL_V3_3_DELEGATION_TARGET,
        };
    }

    pub fn fromString(str: []const u8) ?KernelVersion {
        if (std.mem.eql(u8, str, "v3.3") or std.mem.eql(u8, str, "3.3")) return .v3_3;
        return null;
    }

    pub fn toString(self: KernelVersion) []const u8 {
        return switch (self) {
            .v3_3 => "v3.3",
        };
    }

    pub fn toInt(self: KernelVersion) u8 {
        return @intFromEnum(self);
    }

    pub fn fromInt(val: u8) ?KernelVersion {
        return switch (val) {
            0 => .v3_3,
            else => null,
        };
    }
};

/// Meta factory address (shared across all Kernel v3.x versions)
pub const META_FACTORY = "0xd703aaE79538628d27099B8c4f621bE4CCd142d5";

/// ECDSA Validator address (shared across all Kernel versions)
pub const ECDSA_VALIDATOR = "0x845ADb2C711129d4f3966735eD98a9F09fC4cE57";

/// EntryPoint v0.7 address
pub const ENTRY_POINT_V07 = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";

/// Build ZeroDev v3 RPC URL from project ID and chain ID.
pub fn buildRpcUrl(allocator: std.mem.Allocator, project_id: []const u8, chain_id: u64) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "https://rpc.zerodev.app/api/v3/{s}/chain/{d}",
        .{ project_id, chain_id },
    );
}

/// Build ZeroDev paymaster URL.
pub fn buildPaymasterUrl(allocator: std.mem.Allocator, project_id: []const u8, chain_id: u64) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "https://rpc.zerodev.app/api/v3/{s}/chain/{d}",
        .{ project_id, chain_id },
    );
}

test {
    const std_ = @import("std");
    std_.testing.refAllDecls(@This());
}

test "buildRpcUrl" {
    const allocator = std.testing.allocator;
    const url = try buildRpcUrl(allocator, "abc123", 11155111);
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://rpc.zerodev.app/api/v3/abc123/chain/11155111", url);
}

test "KernelVersion fromString" {
    try std.testing.expectEqual(KernelVersion.v3_3, KernelVersion.fromString("v3.3").?);
    try std.testing.expectEqual(KernelVersion.v3_3, KernelVersion.fromString("3.3").?);
    try std.testing.expect(KernelVersion.fromString("v4.0") == null);
    try std.testing.expect(KernelVersion.fromString("v3.1") == null);
}
