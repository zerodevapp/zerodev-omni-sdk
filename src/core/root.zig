//! ZeroDev-specific constants, Kernel v3.x addresses, and URL builder.

const std = @import("std");

pub const create2 = @import("create2.zig");
pub const kernel = @import("kernel.zig");
pub const userop = @import("userop.zig");
pub const entrypoint = @import("entrypoint.zig");
pub const bundler = @import("bundler.zig");
pub const paymaster = @import("paymaster.zig");
pub const getKernelAddress = create2.getKernelAddress;

/// Kernel smart account versions
pub const KernelVersion = enum {
    v3_1,
    v3_2,
    v3_3,

    pub fn factoryAddress(self: KernelVersion) []const u8 {
        return switch (self) {
            .v3_1 => "0xaac5D4240AF87249B3f71BC8E4A2cae074A3E419",
            .v3_2 => "0x7a1dBAB750f12a90EB1B60D2Ae3aD17D4D81EfFe",
            .v3_3 => "0x2577507b78c2008Ff367261CB6285d44ba5eF2E9",
        };
    }

    pub fn implementationAddress(self: KernelVersion) []const u8 {
        return switch (self) {
            .v3_1 => "0xBAC849bB641841b44E965fB01A4Bf5F074f84b4D",
            .v3_2 => "0xD830D15D3dc0C269F3dBAa0F3e8626d33CFdaBe1",
            .v3_3 => "0xd6CEDDe84be40893d153Be9d467CD6aD37875b28",
        };
    }

    pub fn fromString(str: []const u8) ?KernelVersion {
        if (std.mem.eql(u8, str, "v3.1") or std.mem.eql(u8, str, "3.1")) return .v3_1;
        if (std.mem.eql(u8, str, "v3.2") or std.mem.eql(u8, str, "3.2")) return .v3_2;
        if (std.mem.eql(u8, str, "v3.3") or std.mem.eql(u8, str, "3.3")) return .v3_3;
        return null;
    }

    pub fn toString(self: KernelVersion) []const u8 {
        return switch (self) {
            .v3_1 => "v3.1",
            .v3_2 => "v3.2",
            .v3_3 => "v3.3",
        };
    }

    pub fn toInt(self: KernelVersion) u8 {
        return switch (self) {
            .v3_1 => 0,
            .v3_2 => 1,
            .v3_3 => 2,
        };
    }

    pub fn fromInt(val: u8) ?KernelVersion {
        return switch (val) {
            0 => .v3_1,
            1 => .v3_2,
            2 => .v3_3,
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

test "buildRpcUrl" {
    const allocator = std.testing.allocator;
    const url = try buildRpcUrl(allocator, "abc123", 11155111);
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://rpc.zerodev.app/api/v3/abc123/chain/11155111", url);
}

test "KernelVersion fromString" {
    try std.testing.expectEqual(KernelVersion.v3_3, KernelVersion.fromString("v3.3").?);
    try std.testing.expectEqual(KernelVersion.v3_1, KernelVersion.fromString("3.1").?);
    try std.testing.expect(KernelVersion.fromString("v4.0") == null);
}
