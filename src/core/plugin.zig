//! Kernel v3 plugin lifecycle calldata: installing a validator as a secondary
//! validator, and changing the account's root (sudo) validator.
//!
//! Both produce the inner self-call calldata; the caller sends it as a UserOp
//! targeting the account itself (the account's execute wraps it). The encodings
//! are pinned to @zerodev/sdk in the tests.

const std = @import("std");
const abi = @import("abi");

fn keccak256(data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(data, &out, .{});
    return out;
}

/// installModule(uint256,address,bytes)
const INSTALL_MODULE_SELECTOR = [4]u8{ 0x95, 0x17, 0xe2, 0x9f };
/// changeRootValidator(bytes21,address,bytes,bytes)
const CHANGE_ROOT_VALIDATOR_SELECTOR = [4]u8{ 0x52, 0x14, 0x1c, 0xd9 };
/// execute(bytes32,bytes) — the default action selector for EntryPoint 0.7.
const EXECUTE_ACTION_SELECTOR = [4]u8{ 0xe9, 0xae, 0x5c, 0x53 };

/// ERC-7579 module type id for a validator.
const MODULE_TYPE_VALIDATOR: u256 = 1;
/// Kernel validation type byte for a plain validator (vs 0x02 permission).
const VALIDATION_TYPE_VALIDATOR: u8 = 0x01;

const ZERO_ADDRESS = [_]u8{0} ** 20;

/// Calldata to install `module` as a secondary validator with `validator_data`
/// (its enable-data). No hook. Send it to the account itself.
pub fn installValidatorCallData(
    allocator: std.mem.Allocator,
    module: [20]u8,
    validator_data: []const u8,
) ![]u8 {
    // initData = hookAddress(20, zero) ++ abi.encode(bytes validatorData, bytes hookData, bytes selectorData)
    const encoded = try abi.encode(allocator, &.{
        .{ .dyn_bytes = validator_data },
        .{ .dyn_bytes = &[_]u8{} },
        .{ .dyn_bytes = &EXECUTE_ACTION_SELECTOR },
    });
    defer allocator.free(encoded);

    const init_data = try allocator.alloc(u8, ZERO_ADDRESS.len + encoded.len);
    defer allocator.free(init_data);
    @memcpy(init_data[0..ZERO_ADDRESS.len], &ZERO_ADDRESS);
    @memcpy(init_data[ZERO_ADDRESS.len..], encoded);

    const args = try abi.encode(allocator, &.{
        .{ .word = abi.word256(MODULE_TYPE_VALIDATOR) },
        .{ .word = abi.wordAddress(module) },
        .{ .dyn_bytes = init_data },
    });
    defer allocator.free(args);

    return prefixSelector(allocator, INSTALL_MODULE_SELECTOR, args);
}

/// Calldata to make `module` the account's root (sudo) validator, with
/// `validator_data` as its enable-data. No hook. Send it to the account itself.
pub fn changeRootValidatorCallData(
    allocator: std.mem.Allocator,
    module: [20]u8,
    validator_data: []const u8,
) ![]u8 {
    // rootValidatorId is a bytes21: validationType(0x01) ++ validator address,
    // encoded as one left-aligned word.
    var root_id = [_]u8{0} ** 32;
    root_id[0] = VALIDATION_TYPE_VALIDATOR;
    @memcpy(root_id[1..21], &module);

    const args = try abi.encode(allocator, &.{
        .{ .word = root_id },
        .{ .word = abi.wordAddress(ZERO_ADDRESS) },
        .{ .dyn_bytes = validator_data },
        .{ .dyn_bytes = &[_]u8{} },
    });
    defer allocator.free(args);

    return prefixSelector(allocator, CHANGE_ROOT_VALIDATOR_SELECTOR, args);
}

fn prefixSelector(allocator: std.mem.Allocator, selector: [4]u8, args: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, 4 + args.len);
    @memcpy(out[0..4], &selector);
    @memcpy(out[4..], args);
    return out;
}

// ── Weighted validator social recovery ──────────────────────────────────────

/// approve(bytes32,address)
const APPROVE_SELECTOR = [4]u8{ 0xb2, 0xe2, 0xc9, 0x9b };

/// The value every guardian approves for one recovery:
/// keccak256(abi.encode(address sender, bytes callData, uint256 nonce)). Pinning
/// the sender, the rotation calldata, and the nonce ties an approval to exactly
/// one operation, so a collected approval can never be replayed on another.
pub fn callDataAndNonceHash(
    allocator: std.mem.Allocator,
    sender: [20]u8,
    call_data: []const u8,
    nonce: u256,
) ![32]u8 {
    const encoded = try abi.encode(allocator, &.{
        .{ .word = abi.wordAddress(sender) },
        .{ .dyn_bytes = call_data },
        .{ .word = abi.word256(nonce) },
    });
    defer allocator.free(encoded);
    return keccak256(encoded);
}

/// Calldata for approve(callDataAndNonceHash, kernel) on the weighted validator.
/// A smart-account guardian sends this to the validator to record its approval
/// on chain; the recovery then counts it toward the threshold.
pub fn approveCallData(
    allocator: std.mem.Allocator,
    call_data_and_nonce_hash: [32]u8,
    kernel: [20]u8,
) ![]u8 {
    const args = try abi.encode(allocator, &.{
        .{ .word = call_data_and_nonce_hash },
        .{ .word = abi.wordAddress(kernel) },
    });
    defer allocator.free(args);
    return prefixSelector(allocator, APPROVE_SELECTOR, args);
}

// ── Tests ────────────────────────────────────────────────────────────────
// Calldata is pinned to @zerodev/sdk's encodeFunctionData output.

const testing = std.testing;

fn hexConst(comptime hex: []const u8) [hex.len / 2]u8 {
    @setEvalBranchQuota(100_000);
    var buf: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&buf, hex) catch unreachable;
    return buf;
}

// The WebAuthn v0.0.2 validator address, used as the sample module.
const MODULE = [20]u8{ 0xbA, 0x45, 0xa2, 0xBF, 0xb8, 0xDe, 0x3D, 0x24, 0xcA, 0x9D, 0x7F, 0x1B, 0x55, 0x1E, 0x14, 0xdF, 0xF5, 0xd6, 0x90, 0xFd };
const VALIDATOR_DATA = [_]u8{ 0xaa, 0xbb, 0xcc };

test "installValidatorCallData matches the reference" {
    const cd = try installValidatorCallData(testing.allocator, MODULE, &VALIDATOR_DATA);
    defer testing.allocator.free(cd);
    const expected = hexConst(
        "9517e29f" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "000000000000000000000000ba45a2bfb8de3d24ca9d7f1b551e14dff5d690fd" ++
        "0000000000000000000000000000000000000000000000000000000000000060" ++
        "0000000000000000000000000000000000000000000000000000000000000114" ++
        "0000000000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000060000000000000000000000000" ++
        "00000000000000000000000000000000000000a0000000000000000000000000" ++
        "00000000000000000000000000000000000000c0000000000000000000000000" ++
        "0000000000000000000000000000000000000003aabbcc000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000004e9ae5c530000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000000");
    try testing.expectEqualSlices(u8, &expected, cd);
}

test "changeRootValidatorCallData matches the reference" {
    const cd = try changeRootValidatorCallData(testing.allocator, MODULE, &VALIDATOR_DATA);
    defer testing.allocator.free(cd);
    const expected = hexConst(
        "52141cd9" ++
        "01ba45a2bfb8de3d24ca9d7f1b551e14dff5d690fd0000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000080" ++
        "00000000000000000000000000000000000000000000000000000000000000c0" ++
        "0000000000000000000000000000000000000000000000000000000000000003" ++
        "aabbcc0000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000000");
    try testing.expectEqualSlices(u8, &expected, cd);
}

test "callDataAndNonceHash matches the reference" {
    // cast abi-encode "f(address,bytes,uint256)" 0x..dEaD 0x1234 1, then keccak256.
    const sender = hexConst("000000000000000000000000000000000000dEaD");
    const call_data = hexConst("1234");
    const hash = try callDataAndNonceHash(testing.allocator, sender, &call_data, 1);
    const expected = hexConst("b5d76da38a7472c816cbc6870c22148e8b55461d0ba15327722f36891b4c055d");
    try testing.expectEqualSlices(u8, &expected, &hash);
}

test "approveCallData matches the reference" {
    // cast calldata "approve(bytes32,address)" 0x..beef 0x..dEaD
    const hash = hexConst("000000000000000000000000000000000000000000000000000000000000beef");
    const kernel = hexConst("000000000000000000000000000000000000dEaD");
    const cd = try approveCallData(testing.allocator, hash, kernel);
    defer testing.allocator.free(cd);
    const expected = hexConst(
        "b2e2c99b" ++
        "000000000000000000000000000000000000000000000000000000000000beef" ++
        "000000000000000000000000000000000000000000000000000000000000dead");
    try testing.expectEqualSlices(u8, &expected, cd);
}
