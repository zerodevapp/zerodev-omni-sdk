//! Weighted-ECDSA validator for Kernel v3 smart accounts — the basis for social
//! recovery (guardians).
//!
//! This covers the install path: it produces the on-chain validator's identifier
//! and enable-data (the guardian set, their weights, the threshold, and a delay)
//! so the validator can be installed as a secondary validator on an account. The
//! account owner signs that installation with its own sudo validator, so this
//! validator never signs a UserOp itself here.
//!
//! Active signing by the weighted validator — guardians co-signing a recovery —
//! needs per-UserOp context (sender, callData, nonce) beyond the hash this
//! interface carries, and is a separate, multi-party flow. It's intentionally
//! not implemented on the account owner's device. Enable-data is pinned to
//! @zerodev/weighted-ecdsa-validator in the tests.

const std = @import("std");
const abi = @import("abi");
const Validator = @import("Validator.zig").Validator;
const SignError = @import("Validator.zig").SignError;

/// WeightedECDSAValidator contract for Kernel v3 (0.3.0 || 0.3.1).
/// 0xeD89244160CfE273800B58b1B534031699dFeEEE
pub const WEIGHTED_VALIDATOR_ADDR = [20]u8{
    0xeD, 0x89, 0x24, 0x41, 0x60, 0xCf, 0xE2, 0x73, 0x80, 0x0B,
    0x58, 0xb1, 0xB5, 0x34, 0x03, 0x16, 0x99, 0xdF, 0xeE, 0xEE,
};

/// A guardian: an address that can take part in recovery, and its weight.
pub const Guardian = struct {
    address: [20]u8,
    weight: u24,
};

pub const WeightedValidator = struct {
    // enable-data is dynamic (address[] + uint24[]), so it's built once at init
    // into an owned slice and borrowed by getEnableData. Free it with deinit.
    enable_data: []u8,
    addr: [20]u8,

    /// Build the validator from a guardian set, a threshold, and a delay
    /// (seconds). Guardians are sorted by address descending, matching the
    /// reference so the enable-data is byte-identical.
    pub fn init(
        allocator: std.mem.Allocator,
        guardians: []const Guardian,
        threshold: u24,
        delay: u48,
    ) !WeightedValidator {
        const enable_data = try encodeEnableData(allocator, guardians, threshold, delay);
        return .{ .enable_data = enable_data, .addr = WEIGHTED_VALIDATOR_ADDR };
    }

    pub fn deinit(self: *WeightedValidator, allocator: std.mem.Allocator) void {
        allocator.free(self.enable_data);
    }

    /// abi.encode(address[] guardians, uint24[] weights, uint24 threshold,
    /// uint48 delay), with guardians sorted by address descending. Caller owns
    /// the result. Exposed so the host can build enable-data for an install
    /// without holding a validator instance.
    pub fn encodeEnableData(
        allocator: std.mem.Allocator,
        guardians: []const Guardian,
        threshold: u24,
        delay: u48,
    ) ![]u8 {
        const sorted = try allocator.dupe(Guardian, guardians);
        defer allocator.free(sorted);
        std.mem.sort(Guardian, sorted, {}, addressDescending);

        const guardian_words = try allocator.alloc([32]u8, sorted.len);
        defer allocator.free(guardian_words);
        const weight_words = try allocator.alloc([32]u8, sorted.len);
        defer allocator.free(weight_words);
        for (sorted, 0..) |g, i| {
            guardian_words[i] = abi.wordAddress(g.address);
            weight_words[i] = abi.word256(g.weight);
        }

        return abi.encode(allocator, &.{
            .{ .dyn_words = guardian_words },
            .{ .dyn_words = weight_words },
            .{ .word = abi.word256(threshold) },
            .{ .word = abi.word256(delay) },
        });
    }

    pub fn validator(self: *WeightedValidator) Validator {
        return .{
            .ptr = @ptrCast(self),
            .signUserOpFn = signUserOpImpl,
            .getEnableDataFn = getEnableDataImpl,
            .getStubSignatureFn = getStubSignatureImpl,
            .getIdentifierFn = getIdentifierImpl,
            .getNonceKeyFn = getNonceKeyImpl,
        };
    }

    // The account owner's device never signs as the guardian multisig — that's
    // the guardians' recovery flow, which needs per-UserOp context this
    // interface doesn't carry. Installing the validator is signed by the sudo
    // validator instead.
    fn signUserOpImpl(_: *anyopaque, _: std.mem.Allocator, _: [32]u8) SignError![]u8 {
        return SignError.SigningFailed;
    }

    fn getEnableDataImpl(ptr: *anyopaque) []const u8 {
        const self: *WeightedValidator = @ptrCast(@alignCast(ptr));
        return self.enable_data;
    }

    fn getStubSignatureImpl(_: *anyopaque) []const u8 {
        return &[_]u8{};
    }

    fn getIdentifierImpl(ptr: *anyopaque) [20]u8 {
        const self: *WeightedValidator = @ptrCast(@alignCast(ptr));
        return self.addr;
    }

    fn getNonceKeyImpl(_: *anyopaque) u192 {
        return 0;
    }
};

fn addressDescending(_: void, a: Guardian, b: Guardian) bool {
    return std.mem.order(u8, &a.address, &b.address) == .gt;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn hexConst(comptime hex: []const u8) [hex.len / 2]u8 {
    @setEvalBranchQuota(100_000);
    var buf: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&buf, hex) catch unreachable;
    return buf;
}

test "identifier is the weighted validator address" {
    var v = try WeightedValidator.init(testing.allocator, &.{
        .{ .address = [_]u8{0x11} ** 20, .weight = 1 },
    }, 1, 0);
    defer v.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &WEIGHTED_VALIDATOR_ADDR, &v.validator().getIdentifier());
}

test "getEnableData matches the reference (and sorts guardians descending)" {
    // Pass guardians in ascending order to prove init sorts them descending.
    const g_low = [_]u8{0x11} ** 20;
    const g_high = [_]u8{0x22} ** 20;
    var v = try WeightedValidator.init(testing.allocator, &.{
        .{ .address = g_low, .weight = 2 },
        .{ .address = g_high, .weight = 1 },
    }, 2, 0);
    defer v.deinit(testing.allocator);

    const expected = hexConst(
        "0000000000000000000000000000000000000000000000000000000000000080" ++
        "00000000000000000000000000000000000000000000000000000000000000e0" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "0000000000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "0000000000000000000000002222222222222222222222222222222222222222" ++
        "0000000000000000000000001111111111111111111111111111111111111111" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000002");
    try testing.expectEqualSlices(u8, &expected, v.validator().getEnableData());
}

test "nonce key is zero" {
    var v = try WeightedValidator.init(testing.allocator, &.{
        .{ .address = [_]u8{0x11} ** 20, .weight = 1 },
    }, 1, 0);
    defer v.deinit(testing.allocator);
    try testing.expectEqual(@as(u192, 0), v.validator().getNonceKey());
}
