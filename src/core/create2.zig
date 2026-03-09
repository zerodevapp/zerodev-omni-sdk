//! CREATE2 address derivation for Kernel v3 smart accounts.
//!
//! Computes the deterministic counterfactual address where a Kernel smart account
//! will be deployed, using the CREATE2 formula:
//!   address = keccak256(0xff ++ factory ++ salt ++ bytecodeHash)[12:]

const std = @import("std");
const zigeth = @import("zigeth");

const Address = zigeth.primitives.Address;
const Hash = zigeth.primitives.Hash;
const keccak = zigeth.crypto.keccak;
const zerodev = @import("root.zig");

/// Compute the keccak256 hash of the Solady ERC1967 minimal proxy initcode
/// with the given implementation address embedded.
///
/// The initcode is 95 bytes:
///   prefix(9) ++ implementation(20) ++ mid(2) ++ suffix(64)
pub fn initCodeHashERC1967(implementation: Address) Hash {
    var initcode: [95]u8 = undefined;

    @memcpy(initcode[0..9], &[_]u8{ 0x60, 0x3d, 0x3d, 0x81, 0x60, 0x22, 0x3d, 0x39, 0x73 });
    @memcpy(initcode[9..29], &implementation.bytes);
    @memcpy(initcode[29..31], &[_]u8{ 0x60, 0x09 });
    @memcpy(initcode[31..63], &[_]u8{
        0x51, 0x55, 0xf3, 0x36, 0x3d, 0x3d, 0x37, 0x3d,
        0x3d, 0x36, 0x3d, 0x7f, 0x36, 0x08, 0x94, 0xa1,
        0x3b, 0xa1, 0xa3, 0x21, 0x06, 0x67, 0xc8, 0x28,
        0x49, 0x2d, 0xb9, 0x8d, 0xca, 0x3e, 0x20, 0x76,
    });
    @memcpy(initcode[63..95], &[_]u8{
        0xcc, 0x37, 0x35, 0xa9, 0x20, 0xa3, 0xca, 0x50,
        0x5d, 0x38, 0x2b, 0xbc, 0x54, 0x5a, 0xf4, 0x3d,
        0x60, 0x00, 0x80, 0x3e, 0x60, 0x38, 0x57, 0x3d,
        0x60, 0x00, 0xfd, 0x5b, 0x3d, 0x60, 0x00, 0xf3,
    });

    return keccak.hash(&initcode);
}

/// Encode the `Kernel.initialize(bytes21,address,bytes,bytes,bytes[])` calldata.
///
/// Default case: ECDSA validator as root, no hook, no hookData, no initConfig.
/// Returns 292 bytes of ABI-encoded calldata.
pub fn computeInitializeCalldata(owner: Address, ecdsa_validator: Address) [292]u8 {
    var data: [292]u8 = [_]u8{0} ** 292;

    const selector = keccak.functionSelector("initialize(bytes21,address,bytes,bytes,bytes[])");
    @memcpy(data[0..4], &selector);

    data[4] = 0x01;
    @memcpy(data[5..25], &ecdsa_validator.bytes);

    data[99] = 0xa0;
    data[131] = 0xe0;
    data[162] = 0x01;
    data[163] = 0x00;

    data[195] = 0x14;
    @memcpy(data[196..216], &owner.bytes);

    return data;
}

/// Build the MetaFactory's `deployWithFactory(address,bytes,bytes32)` calldata.
pub fn buildFactoryCalldata(
    allocator: std.mem.Allocator,
    owner_addr: Address,
    index: u256,
    kernel_version: zerodev.KernelVersion,
) ![]u8 {
    const factory_addr = try Address.fromHex(kernel_version.factoryAddress());
    const ecdsa_validator = try Address.fromHex(zerodev.ECDSA_VALIDATOR);
    const init_data = computeInitializeCalldata(owner_addr, ecdsa_validator);

    const total_len = 452;
    const buf = try allocator.alloc(u8, total_len);
    @memset(buf, 0);

    const selector = keccak.functionSelector("deployWithFactory(address,bytes,bytes32)");
    @memcpy(buf[0..4], &selector);

    @memcpy(buf[16..36], &factory_addr.bytes);

    buf[67] = 0x60;

    const salt_be: [32]u8 = @bitCast(@byteSwap(index));
    @memcpy(buf[68..100], &salt_be);

    const len_be: [32]u8 = @bitCast(@byteSwap(@as(u256, 292)));
    @memcpy(buf[100..132], &len_be);

    @memcpy(buf[132..424], &init_data);

    return buf;
}

/// Compute the counterfactual CREATE2 address for a Kernel v3 smart account.
pub fn getKernelAddress(owner: Address, index: u256, kernel_version: zerodev.KernelVersion) !Address {
    const impl_addr = try Address.fromHex(kernel_version.implementationAddress());
    const factory_addr = try Address.fromHex(kernel_version.factoryAddress());
    const ecdsa_validator = try Address.fromHex(zerodev.ECDSA_VALIDATOR);

    const bytecode_hash = initCodeHashERC1967(impl_addr);
    const init_data = computeInitializeCalldata(owner, ecdsa_validator);

    var salt_input: [292 + 32]u8 = undefined;
    @memcpy(salt_input[0..292], &init_data);
    const index_be: [32]u8 = @bitCast(@byteSwap(index));
    @memcpy(salt_input[292..324], &index_be);
    const salt = keccak.hash(&salt_input);

    var create2_input: [85]u8 = undefined;
    create2_input[0] = 0xff;
    @memcpy(create2_input[1..21], &factory_addr.bytes);
    @memcpy(create2_input[21..53], &salt.bytes);
    @memcpy(create2_input[53..85], &bytecode_hash.bytes);

    const create2_hash = keccak.hash(&create2_input);
    return Address.fromBytes(create2_hash.bytes[12..32].*);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "initCodeHashERC1967 produces non-zero hash" {
    const impl = try Address.fromHex("0xd6CEDDe84be40893d153Be9d467CD6aD37875b28");
    const h = initCodeHashERC1967(impl);
    try std.testing.expect(!h.isZero());
}

test "initCodeHashERC1967 is deterministic" {
    const impl = try Address.fromHex("0xd6CEDDe84be40893d153Be9d467CD6aD37875b28");
    const h1 = initCodeHashERC1967(impl);
    const h2 = initCodeHashERC1967(impl);
    try std.testing.expect(h1.eql(h2));
}

test "initCodeHashERC1967 differs per implementation" {
    const impl1 = try Address.fromHex("0xd6CEDDe84be40893d153Be9d467CD6aD37875b28");
    const impl2 = try Address.fromHex("0xD830D15D3dc0C269F3dBAa0F3e8626d33CFdaBe1");
    const h1 = initCodeHashERC1967(impl1);
    const h2 = initCodeHashERC1967(impl2);
    try std.testing.expect(!h1.eql(h2));
}

test "initialize selector is non-zero and deterministic" {
    const selector = keccak.functionSelector("initialize(bytes21,address,bytes,bytes,bytes[])");
    try std.testing.expect(selector[0] != 0 or selector[1] != 0 or selector[2] != 0 or selector[3] != 0);
    const selector2 = keccak.functionSelector("initialize(bytes21,address,bytes,bytes,bytes[])");
    try std.testing.expectEqualSlices(u8, &selector, &selector2);
}

test "computeInitializeCalldata structure" {
    const owner = try Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const validator = try Address.fromHex("0x845ADb2C711129d4f3966735eD98a9F09fC4cE57");
    const data = computeInitializeCalldata(owner, validator);

    const expected_selector = keccak.functionSelector("initialize(bytes21,address,bytes,bytes,bytes[])");
    try std.testing.expectEqualSlices(u8, &expected_selector, data[0..4]);
    try std.testing.expectEqual(@as(u8, 0x01), data[4]);
    try std.testing.expectEqualSlices(u8, &validator.bytes, data[5..25]);
    for (data[25..36]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    for (data[36..68]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try std.testing.expectEqual(@as(u8, 0xa0), data[99]);
    try std.testing.expectEqual(@as(u8, 0xe0), data[131]);
    try std.testing.expectEqual(@as(u8, 0x01), data[162]);
    try std.testing.expectEqual(@as(u8, 0x00), data[163]);
    try std.testing.expectEqual(@as(u8, 0x14), data[195]);
    try std.testing.expectEqualSlices(u8, &owner.bytes, data[196..216]);
}

test "getKernelAddress produces valid address" {
    const owner = try Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const addr = try getKernelAddress(owner, 0, .v3_3);
    try std.testing.expect(!addr.isZero());
}

test "getKernelAddress is deterministic" {
    const owner = try Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const addr1 = try getKernelAddress(owner, 0, .v3_3);
    const addr2 = try getKernelAddress(owner, 0, .v3_3);
    try std.testing.expectEqualSlices(u8, &addr1.bytes, &addr2.bytes);
}

test "getKernelAddress differs by index" {
    const owner = try Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const addr0 = try getKernelAddress(owner, 0, .v3_3);
    const addr1 = try getKernelAddress(owner, 1, .v3_3);
    try std.testing.expect(!std.mem.eql(u8, &addr0.bytes, &addr1.bytes));
}

test "getKernelAddress differs by version" {
    const owner = try Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const addr_v33 = try getKernelAddress(owner, 0, .v3_3);
    const addr_v32 = try getKernelAddress(owner, 0, .v3_2);
    try std.testing.expect(!std.mem.eql(u8, &addr_v33.bytes, &addr_v32.bytes));
}

test "getKernelAddress differs by owner" {
    const owner1 = try Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const owner2 = try Address.fromHex("0x70997970C51812dc3A010C7d01b50e0d17dc79C8");
    const addr1 = try getKernelAddress(owner1, 0, .v3_3);
    const addr2 = try getKernelAddress(owner2, 0, .v3_3);
    try std.testing.expect(!std.mem.eql(u8, &addr1.bytes, &addr2.bytes));
}

// SDK-verified test vectors
test "initCodeHash matches SDK constant — v3.1" {
    const impl = try Address.fromHex("0xBAC849bB641841b44E965fB01A4Bf5F074f84b4D");
    const h = initCodeHashERC1967(impl);
    const expected = try Hash.fromHex("0x85d96aa1c9a65886d094915d76ccae85f14027a02c1647dde659f869460f03e6");
    try std.testing.expect(h.eql(expected));
}

test "initCodeHash matches SDK constant — v3.2" {
    const impl = try Address.fromHex("0xD830D15D3dc0C269F3dBAa0F3e8626d33CFdaBe1");
    const h = initCodeHashERC1967(impl);
    const expected = try Hash.fromHex("0xc7c48c9dd12de68b8a4689b6f8c8c07b61d4d6fa4ddecdd86a6980d045fa67eb");
    try std.testing.expect(h.eql(expected));
}

test "initCodeHash matches SDK constant — v3.3" {
    const impl = try Address.fromHex("0xd6CEDDe84be40893d153Be9d467CD6aD37875b28");
    const h = initCodeHashERC1967(impl);
    const expected = try Hash.fromHex("0xc452397f1e7518f8cea0566ac057e243bb1643f6298aba8eec8cdee78ee3b3dd");
    try std.testing.expect(h.eql(expected));
}

test "initialize selector matches SDK — 0x3c3b752b" {
    const selector = keccak.functionSelector("initialize(bytes21,address,bytes,bytes,bytes[])");
    try std.testing.expectEqual(@as(u8, 0x3c), selector[0]);
    try std.testing.expectEqual(@as(u8, 0x3b), selector[1]);
    try std.testing.expectEqual(@as(u8, 0x75), selector[2]);
    try std.testing.expectEqual(@as(u8, 0x2b), selector[3]);
}

test "getKernelAddress matches SDK — v3.1, index=0" {
    const owner = try Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const addr = try getKernelAddress(owner, 0, .v3_1);
    const expected = try Address.fromHex("0xB3729F7e1Ab0B4a50E7De5599Ecc321B8775d30d");
    try std.testing.expectEqualSlices(u8, &expected.bytes, &addr.bytes);
}

test "getKernelAddress matches SDK — v3.2, index=0" {
    const owner = try Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const addr = try getKernelAddress(owner, 0, .v3_2);
    const expected = try Address.fromHex("0xDA3e042335c74953F4F282B748Bb8aA8585fac68");
    try std.testing.expectEqualSlices(u8, &expected.bytes, &addr.bytes);
}

test "getKernelAddress matches SDK — v3.3, index=0" {
    const owner = try Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const addr = try getKernelAddress(owner, 0, .v3_3);
    const expected = try Address.fromHex("0xCfC4C807Ed404ae1a65fbe0EdaA09EF002E75838");
    try std.testing.expectEqualSlices(u8, &expected.bytes, &addr.bytes);
}

test "getKernelAddress matches SDK — v3.3, index=1" {
    const owner = try Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const addr = try getKernelAddress(owner, 1, .v3_3);
    const expected = try Address.fromHex("0x26260b593292B5452f66B7257675743F10767526");
    try std.testing.expectEqualSlices(u8, &expected.bytes, &addr.bytes);
}

test "getKernelAddress matches SDK — different owner, v3.3, index=0" {
    const owner = try Address.fromHex("0x70997970C51812dc3A010C7d01b50e0d17dc79C8");
    const addr = try getKernelAddress(owner, 0, .v3_3);
    const expected = try Address.fromHex("0xCF0c37F1390A0dc25615EE05bfcab32aAd704D02");
    try std.testing.expectEqualSlices(u8, &expected.bytes, &addr.bytes);
}

test "buildFactoryCalldata output is 452 bytes" {
    const allocator = std.testing.allocator;
    const owner = try Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const result = try buildFactoryCalldata(allocator, owner, 0, .v3_3);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 452), result.len);
}

test "buildFactoryCalldata correct selector" {
    const allocator = std.testing.allocator;
    const owner = try Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const result = try buildFactoryCalldata(allocator, owner, 0, .v3_3);
    defer allocator.free(result);
    const expected_sel = keccak.functionSelector("deployWithFactory(address,bytes,bytes32)");
    try std.testing.expectEqualSlices(u8, &expected_sel, result[0..4]);
}

test "buildFactoryCalldata embeds factory address" {
    const allocator = std.testing.allocator;
    const owner = try Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const result = try buildFactoryCalldata(allocator, owner, 0, .v3_3);
    defer allocator.free(result);
    const factory = try Address.fromHex(zerodev.KernelVersion.v3_3.factoryAddress());
    try std.testing.expectEqualSlices(u8, &factory.bytes, result[16..36]);
    for (result[4..16]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "buildFactoryCalldata bytes offset is 0x60" {
    const allocator = std.testing.allocator;
    const owner = try Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const result = try buildFactoryCalldata(allocator, owner, 0, .v3_3);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(u8, 0x60), result[67]);
    for (result[36..67]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "buildFactoryCalldata salt is zero for index=0" {
    const allocator = std.testing.allocator;
    const owner = try Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const result = try buildFactoryCalldata(allocator, owner, 0, .v3_3);
    defer allocator.free(result);
    for (result[68..100]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "buildFactoryCalldata salt is 1 for index=1" {
    const allocator = std.testing.allocator;
    const owner = try Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const result = try buildFactoryCalldata(allocator, owner, 1, .v3_3);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(u8, 1), result[99]);
    for (result[68..99]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "buildFactoryCalldata bytes length is 292" {
    const allocator = std.testing.allocator;
    const owner = try Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const result = try buildFactoryCalldata(allocator, owner, 0, .v3_3);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(u8, 0x01), result[130]);
    try std.testing.expectEqual(@as(u8, 0x24), result[131]);
}

test "buildFactoryCalldata initData matches computeInitializeCalldata" {
    const allocator = std.testing.allocator;
    const owner = try Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const result = try buildFactoryCalldata(allocator, owner, 0, .v3_3);
    defer allocator.free(result);
    const ecdsa_validator = try Address.fromHex(zerodev.ECDSA_VALIDATOR);
    const expected_init = computeInitializeCalldata(owner, ecdsa_validator);
    try std.testing.expectEqualSlices(u8, &expected_init, result[132..424]);
    for (result[424..452]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}
