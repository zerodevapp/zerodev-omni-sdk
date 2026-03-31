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
};
