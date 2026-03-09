//! ECDSA validator plugin for Kernel v3 smart accounts.
//!
//! Uses secp256k1 signing via zigeth's Wallet. Implements the Validator
//! vtable interface for use with the C API.

const std = @import("std");
const zigeth = @import("zigeth");
const Validator = @import("Validator.zig").Validator;
const SignError = @import("Validator.zig").SignError;

const Wallet = zigeth.signer.Wallet;
const Address = zigeth.primitives.Address;
const Hash = zigeth.primitives.Hash;
const PrivateKey = zigeth.crypto.secp256k1.PrivateKey;

/// ECDSA Validator address (shared across all Kernel versions)
const ECDSA_VALIDATOR_ADDR = [20]u8{
    0x84, 0x5A, 0xDb, 0x2C, 0x71, 0x11, 0x29, 0xd4, 0xf3, 0x96,
    0x67, 0x35, 0xeD, 0x98, 0xa9, 0xF0, 0x9f, 0xC4, 0xcE, 0x57,
};

pub const EcdsaValidator = struct {
    wallet: Wallet,
    owner_address: Address,

    pub fn init(allocator: std.mem.Allocator, private_key: [32]u8) !EcdsaValidator {
        const pk = try PrivateKey.fromBytes(private_key);
        const wallet = try Wallet.init(allocator, pk);
        return .{
            .wallet = wallet,
            .owner_address = wallet.address,
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

        // EIP-191 personal sign: sign(keccak256("\x19Ethereum Signed Message:\n32" ++ hash))
        const prefix = "\x19Ethereum Signed Message:\n32";
        var prefixed: [prefix.len + 32]u8 = undefined;
        @memcpy(prefixed[0..prefix.len], prefix);
        @memcpy(prefixed[prefix.len..], &user_op_hash);

        const keccak = zigeth.crypto.keccak;
        const msg_hash = keccak.hash(&prefixed);

        // Call signer directly with Hash type (wallet.signHash has a type mismatch in zigeth)
        const sig = self.wallet.signer.signHash(msg_hash) catch return SignError.SigningFailed;

        // Convert Signature{r, s, v} to [65]u8
        var result: [65]u8 = undefined;
        @memcpy(result[0..32], &sig.r);
        @memcpy(result[32..64], &sig.s);
        result[64] = sig.v;
        return result;
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

test "EcdsaValidator init and getIdentifier" {
    // Hardhat account #0 private key
    const pk = [_]u8{
        0xac, 0x09, 0x74, 0xbe, 0xc3, 0x9a, 0x17, 0xe3,
        0x6b, 0xa4, 0xa6, 0xb4, 0xd2, 0x38, 0xff, 0x94,
        0x4b, 0xac, 0xb3, 0x5e, 0x5d, 0xc4, 0x70, 0x02,
        0x15, 0x7c, 0xf6, 0x51, 0x43, 0x9d, 0xfb, 0xa4,
    };
    var v = try EcdsaValidator.init(std.testing.allocator, pk);
    const val = v.validator();

    // Should return the ECDSA validator contract address
    const id = val.getIdentifier();
    try std.testing.expectEqualSlices(u8, &ECDSA_VALIDATOR_ADDR, &id);

    // Nonce key should be 0 for ECDSA
    try std.testing.expectEqual(@as(u192, 0), val.getNonceKey());

    // Stub signature should be 65 zero bytes
    const stub = val.getStubSignature();
    for (stub) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "EcdsaValidator signUserOp produces 65-byte signature" {
    const pk = [_]u8{
        0xac, 0x09, 0x74, 0xbe, 0xc3, 0x9a, 0x17, 0xe3,
        0x6b, 0xa4, 0xa6, 0xb4, 0xd2, 0x38, 0xff, 0x94,
        0x4b, 0xac, 0xb3, 0x5e, 0x5d, 0xc4, 0x70, 0x02,
        0x15, 0x7c, 0xf6, 0x51, 0x43, 0x9d, 0xfb, 0xa4,
    };
    var v = try EcdsaValidator.init(std.testing.allocator, pk);
    const val = v.validator();

    const hash = [_]u8{0x42} ** 32;
    const sig = try val.signUserOp(hash);
    try std.testing.expectEqual(@as(usize, 65), sig.len);

    // Signature should not be all zeros
    var all_zero = true;
    for (sig) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try std.testing.expect(!all_zero);
}

test "EcdsaValidator signUserOp is deterministic" {
    const pk = [_]u8{
        0xac, 0x09, 0x74, 0xbe, 0xc3, 0x9a, 0x17, 0xe3,
        0x6b, 0xa4, 0xa6, 0xb4, 0xd2, 0x38, 0xff, 0x94,
        0x4b, 0xac, 0xb3, 0x5e, 0x5d, 0xc4, 0x70, 0x02,
        0x15, 0x7c, 0xf6, 0x51, 0x43, 0x9d, 0xfb, 0xa4,
    };
    var v = try EcdsaValidator.init(std.testing.allocator, pk);
    const val = v.validator();

    const hash = [_]u8{0xab} ** 32;
    const sig1 = try val.signUserOp(hash);
    const sig2 = try val.signUserOp(hash);
    try std.testing.expectEqualSlices(u8, &sig1, &sig2);
}

test "EcdsaValidator getEnableData returns owner address" {
    const pk = [_]u8{
        0xac, 0x09, 0x74, 0xbe, 0xc3, 0x9a, 0x17, 0xe3,
        0x6b, 0xa4, 0xa6, 0xb4, 0xd2, 0x38, 0xff, 0x94,
        0x4b, 0xac, 0xb3, 0x5e, 0x5d, 0xc4, 0x70, 0x02,
        0x15, 0x7c, 0xf6, 0x51, 0x43, 0x9d, 0xfb, 0xa4,
    };
    var v = try EcdsaValidator.init(std.testing.allocator, pk);
    const val = v.validator();

    const enable_data = val.getEnableData();
    try std.testing.expectEqual(@as(usize, 20), enable_data.len);

    // Should be the owner address derived from private key
    // Hardhat account #0: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
    const expected = try Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    try std.testing.expectEqualSlices(u8, &expected.bytes, enable_data);
}
