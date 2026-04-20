//! Signer Interface — unified signing abstraction for Ethereum.
//!
//! All signer implementations (local private key, JSON-RPC, C callback)
//! conform to this vtable interface. Validators use a Signer to sign
//! UserOperation hashes without knowing the signing mechanism.
//!
//! Matches Voltaire's Signer interface surface:
//! - signHash: raw 32-byte hash (no prefixing)
//! - signMessage: EIP-191 personal_sign
//! - signTypedDataHash: EIP-712 typed data
//! - signAuthorization: EIP-7702 authorization tuple

/// EIP-7702 authorization tuple — canonical type, re-used by core modules.
pub const Authorization = struct {
    chain_id: u64,
    address: [20]u8,
    nonce: u64,
    y_parity: u8,
    r: [32]u8,
    s: [32]u8,
};

pub const SignerError = error{
    SigningFailed,
    InvalidKey,
    NotConnected,
    RpcError,
    OutOfMemory,
};

pub const Signature = struct {
    r: [32]u8,
    s: [32]u8,
    v: u8,

    pub fn toBytes(self: Signature) [65]u8 {
        var out: [65]u8 = undefined;
        @memcpy(out[0..32], &self.r);
        @memcpy(out[32..64], &self.s);
        out[64] = self.v;
        return out;
    }

    pub fn fromBytes(bytes: [65]u8) Signature {
        return .{
            .r = bytes[0..32].*,
            .s = bytes[32..64].*,
            .v = bytes[64],
        };
    }
};

pub const Signer = struct {
    ptr: *anyopaque,
    getAddressFn: *const fn (*anyopaque) [20]u8,
    signHashFn: *const fn (*anyopaque, hash: [32]u8) SignerError!Signature,
    signMessageFn: *const fn (*anyopaque, message: []const u8) SignerError!Signature,
    signTypedDataHashFn: *const fn (*anyopaque, hash: [32]u8) SignerError!Signature,
    /// Optional. If null, default path: compute auth hash from (chainId, address, nonce)
    /// and call signHash.
    signAuthorizationFn: ?*const fn (*anyopaque, chain_id: u64, address: [20]u8, nonce: u64) SignerError!Authorization = null,

    pub fn getAddress(self: Signer) [20]u8 {
        return self.getAddressFn(self.ptr);
    }

    /// Sign a raw 32-byte hash (no prefixing).
    pub fn signHash(self: Signer, hash: [32]u8) SignerError!Signature {
        return self.signHashFn(self.ptr, hash);
    }

    /// Sign a message with EIP-191 personal_sign prefix.
    pub fn signMessage(self: Signer, message: []const u8) SignerError!Signature {
        return self.signMessageFn(self.ptr, message);
    }

    /// Sign an EIP-712 typed data hash.
    pub fn signTypedDataHash(self: Signer, hash: [32]u8) SignerError!Signature {
        return self.signTypedDataHashFn(self.ptr, hash);
    }

    /// Sign an EIP-7702 authorization tuple. Uses the signer's native implementation
    /// if provided, otherwise falls back to hashing then signHash.
    pub fn signAuthorization(
        self: Signer,
        chain_id: u64,
        address: [20]u8,
        nonce: u64,
    ) SignerError!Authorization {
        if (self.signAuthorizationFn) |f| return f(self.ptr, chain_id, address, nonce);
        return defaultSignAuthorization(self, chain_id, address, nonce);
    }
};

/// Default signAuthorization: compute keccak256(0x05 || rlp([chainId, address, nonce]))
/// and call signHash.
pub fn defaultSignAuthorization(
    self: Signer,
    chain_id: u64,
    address: [20]u8,
    nonce: u64,
) SignerError!Authorization {
    const hash = computeAuthHashLocal(chain_id, address, nonce);
    const sig = try self.signHashFn(self.ptr, hash);
    const y_parity: u8 = switch (sig.v) {
        0, 1 => sig.v,
        27 => 0,
        28 => 1,
        else => return SignerError.SigningFailed,
    };
    return .{
        .chain_id = chain_id,
        .address = address,
        .nonce = nonce,
        .y_parity = y_parity,
        .r = sig.r,
        .s = sig.s,
    };
}

// Local copy of computeAuthHash kept here so signer has no dependency on core/.
// Mirrored by core/authorization.zig's public API.
fn computeAuthHashLocal(chain_id: u64, address: [20]u8, nonce: u64) [32]u8 {
    const std_ = @import("std");
    var rlp_buf: [96]u8 = undefined;
    const rlp_len = encodeAuthRlp(chain_id, address, nonce, &rlp_buf);

    var hasher = std_.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(&[_]u8{0x05});
    hasher.update(rlp_buf[0..rlp_len]);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

fn uintMinimalBE(value: u64, out: *[8]u8) []const u8 {
    const std_ = @import("std");
    if (value == 0) return out[0..0];
    std_.mem.writeInt(u64, out, value, .big);
    var i: usize = 0;
    while (i < 8 and out[i] == 0) : (i += 1) {}
    return out[i..];
}

fn encodeAuthRlp(chain_id: u64, address: [20]u8, nonce: u64, out: *[96]u8) usize {
    var payload: [96]u8 = undefined;
    var p: usize = 0;

    // chainId
    var tmp: [8]u8 = undefined;
    const cid = uintMinimalBE(chain_id, &tmp);
    if (cid.len == 1 and cid[0] < 0x80) {
        payload[p] = cid[0];
        p += 1;
    } else {
        payload[p] = 0x80 + @as(u8, @intCast(cid.len));
        p += 1;
        @memcpy(payload[p .. p + cid.len], cid);
        p += cid.len;
    }

    // address (always 20 bytes, always encoded as 0x94 || bytes)
    payload[p] = 0x80 + 20;
    p += 1;
    @memcpy(payload[p .. p + 20], &address);
    p += 20;

    // nonce
    var tmp2: [8]u8 = undefined;
    const non = uintMinimalBE(nonce, &tmp2);
    if (non.len == 1 and non[0] < 0x80) {
        payload[p] = non[0];
        p += 1;
    } else {
        payload[p] = 0x80 + @as(u8, @intCast(non.len));
        p += 1;
        @memcpy(payload[p .. p + non.len], non);
        p += non.len;
    }

    // Wrap with list prefix (payload will always be <= 55 bytes for u64+addr+u64)
    out[0] = 0xc0 + @as(u8, @intCast(p));
    @memcpy(out[1 .. 1 + p], payload[0..p]);
    return 1 + p;
}
