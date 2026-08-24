//! ERC-1271 personal-sign digest for a Kernel v3 smart account.
//!
//! A message signed on the account's behalf is not signed bare: Kernel wraps the
//! EIP-191 hash of the message in the account's own EIP-712 domain — name "Kernel",
//! the deployed version, the chain, and the account address as verifying contract —
//! so a signature can never be replayed against another account or chain. The owner
//! key signs that wrapped digest raw, and the account's isValidSignature recovers it
//! through the root validator.

const std = @import("std");
const primitives = @import("primitives");

const Address = primitives.Address;
const Keccak256 = std.crypto.hash.sha3.Keccak256;

/// keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
fn domainTypehash() [32]u8 {
    var out: [32]u8 = undefined;
    Keccak256.hash("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)", &out, .{});
    return out;
}

/// keccak256("Kernel(bytes32 hash)") — the struct a Kernel 1271 wrap signs.
fn kernelTypehash() [32]u8 {
    var out: [32]u8 = undefined;
    Keccak256.hash("Kernel(bytes32 hash)", &out, .{});
    return out;
}

/// The EIP-191 personal-message hash:
/// keccak256("\x19Ethereum Signed Message:\n" ++ len(message) ++ message).
pub fn eip191Hash(message: []const u8) [32]u8 {
    var len_buf: [20]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{message.len}) catch unreachable;

    var hasher = Keccak256.init(.{});
    hasher.update("\x19Ethereum Signed Message:\n");
    hasher.update(len_str);
    hasher.update(message);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

/// The digest the owner key signs for a Kernel account's ERC-1271 approval of a
/// personal message: hashTypedData over Kernel(bytes32 hash) in the account's domain,
/// with the EIP-191 message hash as the struct's one field.
pub fn kernelPersonalDigest(
    account: Address,
    chain_id: u64,
    kernel_eip712_version: []const u8,
    message: []const u8,
) [32]u8 {
    const message_hash = eip191Hash(message);

    // structHash = keccak256(typehash ++ hash)
    var struct_buf: [64]u8 = undefined;
    @memcpy(struct_buf[0..32], &kernelTypehash());
    @memcpy(struct_buf[32..64], &message_hash);
    var struct_hash: [32]u8 = undefined;
    Keccak256.hash(&struct_buf, &struct_hash, .{});

    // domainSeparator = keccak256(typehash ++ keccak(name) ++ keccak(version) ++ chainId ++ account)
    var name_hash: [32]u8 = undefined;
    Keccak256.hash("Kernel", &name_hash, .{});
    var version_hash: [32]u8 = undefined;
    Keccak256.hash(kernel_eip712_version, &version_hash, .{});

    var domain_buf: [160]u8 = [_]u8{0} ** 160;
    @memcpy(domain_buf[0..32], &domainTypehash());
    @memcpy(domain_buf[32..64], &name_hash);
    @memcpy(domain_buf[64..96], &version_hash);
    std.mem.writeInt(u64, domain_buf[120..128], chain_id, .big);
    @memcpy(domain_buf[140..160], &account.bytes);
    var domain_sep: [32]u8 = undefined;
    Keccak256.hash(&domain_buf, &domain_sep, .{});

    // digest = keccak256(0x19 0x01 ++ domainSeparator ++ structHash)
    var final_buf: [66]u8 = undefined;
    final_buf[0] = 0x19;
    final_buf[1] = 0x01;
    @memcpy(final_buf[2..34], &domain_sep);
    @memcpy(final_buf[34..66], &struct_hash);
    var digest: [32]u8 = undefined;
    Keccak256.hash(&final_buf, &digest, .{});
    return digest;
}

test "eip191 hash matches viem's hashMessage for 'hello'" {
    const expect = [_]u8{
        0x50, 0xb2, 0xc4, 0x3f, 0xd3, 0x91, 0x06, 0xba,
        0xfb, 0xba, 0x0d, 0xa3, 0x4f, 0xc4, 0x30, 0xe1,
        0xf9, 0x1e, 0x3c, 0x96, 0xea, 0x2a, 0xce, 0xe2,
        0xbc, 0x34, 0x11, 0x9f, 0x92, 0xb3, 0x77, 0x50,
    };
    try std.testing.expectEqualSlices(u8, &expect, &eip191Hash("hello"));
}

test "kernel personal digest matches viem's hashTypedData" {
    // hashTypedData({ domain: { Kernel, 0.3.3, chainId 11155111, verifyingContract
    // 0x1111…11 }, Kernel(bytes32 hash), hash: hashMessage("hello") })
    const account = Address{ .bytes = [_]u8{0x11} ** 20 };
    const expect = [_]u8{
        0x3e, 0x1b, 0x00, 0x64, 0xac, 0x5e, 0x4a, 0xe4,
        0xe1, 0xf2, 0x6b, 0x87, 0x53, 0x68, 0xa1, 0x45,
        0xf3, 0x2e, 0xd3, 0xc1, 0xed, 0xe6, 0xe1, 0x48,
        0xbe, 0xf7, 0xdd, 0xc8, 0x55, 0xc4, 0x74, 0x60,
    };
    const digest = kernelPersonalDigest(account, 11155111, "0.3.3", "hello");
    try std.testing.expectEqualSlices(u8, &expect, &digest);
}
