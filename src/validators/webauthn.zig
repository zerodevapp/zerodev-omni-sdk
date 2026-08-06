//! WebAuthn (passkey) validator for Kernel v3 smart accounts.
//!
//! The passkey ceremony (Face ID / Touch ID) runs on the host, which is the
//! only place with access to the platform authenticator. The host returns the
//! raw assertion — authenticatorData, clientDataJSON, and the DER-encoded P-256
//! signature — and this validator parses the signature (normalizing to low-S to
//! avoid malleability), locates the type field in the clientDataJSON, and
//! ABI-encodes everything exactly as ZeroDev's on-chain WebAuthn validator
//! expects. The encoding is pinned to @zerodev/passkey-validator in the tests.

const std = @import("std");
const abi = @import("abi");
const Validator = @import("Validator.zig").Validator;
const SignError = @import("Validator.zig").SignError;

/// secp256r1 (P-256) curve order.
const P256_N: u256 = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;

/// WebAuthn validator contract, by on-chain contract version (Kernel v3.x).
pub const ContractVersion = enum { v0_0_1, v0_0_2, v0_0_3 };

pub fn validatorAddress(version: ContractVersion) [20]u8 {
    return switch (version) {
        // 0xD990393C670dCcE8b4d8F858FB98c9912dBFAa06
        .v0_0_1 => .{ 0xD9, 0x90, 0x39, 0x3C, 0x67, 0x0d, 0xCc, 0xE8, 0xb4, 0xd8, 0xF8, 0x58, 0xFB, 0x98, 0xc9, 0x91, 0x2d, 0xBF, 0xAa, 0x06 },
        // 0xbA45a2BFb8De3D24cA9D7F1B551E14dFF5d690Fd
        .v0_0_2 => .{ 0xbA, 0x45, 0xa2, 0xBF, 0xb8, 0xDe, 0x3D, 0x24, 0xcA, 0x9D, 0x7F, 0x1B, 0x55, 0x1E, 0x14, 0xdF, 0xF5, 0xd6, 0x90, 0xFd },
        // 0x7ab16Ff354AcB328452F1D445b3Ddee9a91e9e69
        .v0_0_3 => .{ 0x7a, 0xb1, 0x6F, 0xf3, 0x54, 0xAc, 0xB3, 0x28, 0x45, 0x2F, 0x1D, 0x44, 0x5b, 0x3D, 0xde, 0xe9, 0xa9, 0x1e, 0x9e, 0x69 },
    };
}

/// Networks with the RIP-7212 P-256 precompile. On these the validator sets
/// usePrecompiled so the contract uses the cheap precompile; elsewhere it uses
/// the (universal) Solidity verifier.
const RIP7212_NETWORKS = [_]u64{
    1,       10,      56,      97,      130,     137,     143,     183,     185,     204,
    233,     324,     360,     747,     901,     919,     1301,    1315,    1424,    1514,
    1894,    2741,    3343,    5000,    5003,    6343,    7000,    8008,    8333,    8453,
    8765,    10143,   17000,   28802,   33111,   33139,   34443,   42161,   42170,   42220,
    43111,   43113,   43114,   57073,   59141,   59144,   60808,   80002,   80888,   84532,
    98866,   98867,   421614,  534351,  534352,  656476,  743111,  747474,  763373,  11155111,
    11155420, 666666666, 88153591557,
};

pub fn isRIP7212(chain_id: u64) bool {
    for (RIP7212_NETWORKS) |c| {
        if (c == chain_id) return true;
    }
    return false;
}

/// The raw assertion the host returns after running the passkey ceremony with
/// challenge = userOpHash. The slices must stay valid until signUserOp returns
/// (in practice the host fills them from the same allocator).
pub const Assertion = struct {
    authenticator_data: []const u8,
    client_data_json: []const u8,
    /// The P-256 signature in ASN.1 DER (as the platform authenticator returns
    /// it). This validator parses and low-S-normalizes it.
    der_signature: []const u8,
};

/// The host-side passkey signer: runs the ceremony and returns the assertion.
pub const WebAuthnSigner = struct {
    ptr: *anyopaque,
    signFn: *const fn (*anyopaque, allocator: std.mem.Allocator, challenge: [32]u8) SignError!Assertion,

    pub fn sign(self: WebAuthnSigner, allocator: std.mem.Allocator, challenge: [32]u8) SignError!Assertion {
        return self.signFn(self.ptr, allocator, challenge);
    }
};

pub const WebAuthnValidator = struct {
    signer: WebAuthnSigner,
    addr: [20]u8,
    use_precompiled: bool,
    // enable data is abi.encode((uint256 x, uint256 y), bytes32 idHash): three
    // static words, so it's built once at init and borrowed by getEnableData.
    enable_data: [96]u8,

    pub fn init(
        signer: WebAuthnSigner,
        pub_x: u256,
        pub_y: u256,
        authenticator_id_hash: [32]u8,
        version: ContractVersion,
        chain_id: u64,
    ) WebAuthnValidator {
        return .{
            .signer = signer,
            .addr = validatorAddress(version),
            .use_precompiled = isRIP7212(chain_id),
            .enable_data = encodeEnableData(pub_x, pub_y, authenticator_id_hash),
        };
    }

    /// abi.encode((uint256 x, uint256 y), bytes32 authenticatorIdHash) — three
    /// static words, so no allocation. Exposed so the host can build enable-data
    /// for an install or owner rotation without a validator instance.
    pub fn encodeEnableData(pub_x: u256, pub_y: u256, authenticator_id_hash: [32]u8) [96]u8 {
        var enable: [96]u8 = undefined;
        const x = abi.word256(pub_x);
        const y = abi.word256(pub_y);
        @memcpy(enable[0..32], &x);
        @memcpy(enable[32..64], &y);
        @memcpy(enable[64..96], &authenticator_id_hash);
        return enable;
    }

    pub fn validator(self: *WebAuthnValidator) Validator {
        return .{
            .ptr = @ptrCast(self),
            .signUserOpFn = signUserOpImpl,
            .getEnableDataFn = getEnableDataImpl,
            .getStubSignatureFn = getStubSignatureImpl,
            .getIdentifierFn = getIdentifierImpl,
            .getNonceKeyFn = getNonceKeyImpl,
        };
    }

    fn signUserOpImpl(ptr: *anyopaque, allocator: std.mem.Allocator, user_op_hash: [32]u8) SignError![]u8 {
        const self: *WebAuthnValidator = @ptrCast(@alignCast(ptr));
        const assertion = try self.signer.sign(allocator, user_op_hash);

        const rs = parseAndNormalizeSig(assertion.der_signature) catch return SignError.SigningFailed;

        // responseTypeLocation: the first occurrence of the type field. The
        // on-chain verifier reads the type at this offset, so it must be the
        // genuine leading field, not a later attacker-influenced copy.
        const loc = std.mem.indexOf(u8, assertion.client_data_json, "\"type\":\"webauthn.get\"") orelse
            return SignError.SigningFailed;

        return abi.encode(allocator, &.{
            .{ .dyn_bytes = assertion.authenticator_data },
            .{ .dyn_bytes = assertion.client_data_json },
            .{ .word = abi.word256(loc) },
            .{ .word = abi.word256(rs.r) },
            .{ .word = abi.word256(rs.s) },
            .{ .word = abi.wordBool(self.use_precompiled) },
        }) catch return SignError.OutOfMemory;
    }

    fn getEnableDataImpl(ptr: *anyopaque) []const u8 {
        const self: *WebAuthnValidator = @ptrCast(@alignCast(ptr));
        return &self.enable_data;
    }

    fn getStubSignatureImpl(_: *anyopaque) []const u8 {
        return &STUB_SIGNATURE;
    }

    fn getIdentifierImpl(ptr: *anyopaque) [20]u8 {
        const self: *WebAuthnValidator = @ptrCast(@alignCast(ptr));
        return self.addr;
    }

    fn getNonceKeyImpl(_: *anyopaque) u192 {
        return 0;
    }
};

const RS = struct { r: u256, s: u256 };

/// Parse an ASN.1 DER ECDSA signature into (r, s) and normalize s to the lower
/// half of the curve order (matching @zerodev/webauthn-key's parseAndNormalizeSig,
/// so the on-chain verifier accepts it and the signature isn't malleable).
fn parseAndNormalizeSig(der: []const u8) !RS {
    // SEQUENCE { INTEGER r, INTEGER s }. ECDSA signatures are short (~70 bytes),
    // so the length fields are always single-byte short-form.
    if (der.len < 8 or der[0] != 0x30) return error.BadDer;
    if (der[1] & 0x80 != 0) return error.BadDer; // long-form length not expected
    var i: usize = 2;

    const r = try readDerInt(der, &i);
    const s_raw = try readDerInt(der, &i);

    // A valid P-256 signature has 1 <= r,s < N. Reject zero or out-of-range
    // scalars up front: they are malformed, and passing them on would just be
    // rejected on-chain after the user already paid to sign.
    if (r == 0 or r >= P256_N or s_raw == 0 or s_raw >= P256_N) return error.BadDer;

    const s = if (s_raw > P256_N / 2) P256_N - s_raw else s_raw;
    return .{ .r = r, .s = s };
}

fn readDerInt(der: []const u8, i: *usize) !u256 {
    if (i.* + 2 > der.len or der[i.*] != 0x02) return error.BadDer;
    const len = der[i.* + 1];
    const start = i.* + 2;
    const end = start + len;
    if (end > der.len) return error.BadDer;
    i.* = end;
    return beToU256(der[start..end]);
}

/// Big-endian bytes (with an optional single leading 0x00 sign byte, or fewer
/// than 32 significant bytes) into a u256.
fn beToU256(bytes: []const u8) !u256 {
    var start: usize = 0;
    while (start < bytes.len and bytes[start] == 0) start += 1;
    if (bytes.len - start > 32) return error.IntTooLong;
    var v: u256 = 0;
    for (bytes[start..]) |b| v = (v << 8) | b;
    return v;
}

// The fixed dummy signature for gas estimation, taken verbatim from
// @zerodev/passkey-validator's getStubSignature and pre-encoded so it can be
// borrowed without allocating.
const STUB_HEX =
    "00000000000000000000000000000000000000000000000000000000000000c0" ++
    "0000000000000000000000000000000000000000000000000000000000000120" ++
    "0000000000000000000000000000000000000000000000000000000000000001" ++
    "635bc6d0f68ff895cae8a288ecf7542a6a9cd555df784b73e1e2ea7e9104b1db" ++
    "15e9015d280cb19527881c625fee43fd3a405d5b0d199a8c8e6589a7381209e4" ++
    "0000000000000000000000000000000000000000000000000000000000000000" ++
    "0000000000000000000000000000000000000000000000000000000000000025" ++
    "49960de5880e8c687434170f6476605b8fe4aeb9a28632c7995cf3ba831d9763" ++
    "1d00000000000000000000000000000000000000000000000000000000000000" ++
    "00000000000000000000000000000000000000000000000000000000000000f4" ++
    "7b2274797065223a22776562617574686e2e676574222c226368616c6c656e67" ++
    "65223a22746278584e465339585f3442797231634d77714b724947422d5f3330" ++
    "613051685a36793775634d30424f45222c226f726967696e223a22687474703a" ++
    "2f2f6c6f63616c686f73743a33303030222c2263726f73734f726967696e223a" ++
    "66616c73652c20226f746865725f6b6579735f63616e5f62655f61646465645f" ++
    "68657265223a22646f206e6f7420636f6d7061726520636c69656e7444617461" ++
    "4a534f4e20616761696e737420612074656d706c6174652e2053656520687474" ++
    "70733a2f2f676f6f2e676c2f796162506578227d000000000000000000000000";

fn hexConst(comptime hex: []const u8) [hex.len / 2]u8 {
    @setEvalBranchQuota(100_000);
    var buf: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&buf, hex) catch unreachable;
    return buf;
}

const STUB_SIGNATURE = hexConst(STUB_HEX);

// ── Tests ────────────────────────────────────────────────────────────────
// Encodings and vectors are pinned to @zerodev/passkey-validator +
// @zerodev/webauthn-key (via viem/noble oracles).

const testing = std.testing;

test "validator address (v0.0.2, kernel v3)" {
    const addr = validatorAddress(.v0_0_2);
    const expected = [_]u8{ 0xbA, 0x45, 0xa2, 0xBF, 0xb8, 0xDe, 0x3D, 0x24, 0xcA, 0x9D, 0x7F, 0x1B, 0x55, 0x1E, 0x14, 0xdF, 0xF5, 0xd6, 0x90, 0xFd };
    try testing.expectEqualSlices(u8, &expected, &addr);
}

test "isRIP7212: Sepolia yes, unknown no" {
    try testing.expect(isRIP7212(11155111));
    try testing.expect(isRIP7212(8453));
    try testing.expect(!isRIP7212(1234567));
}

test "getEnableData: abi.encode((x,y), idHash)" {
    var mock = MockSigner{};
    var v = WebAuthnValidator.init(mock.signer(), 0x1111, 0x2222, [_]u8{0x33} ** 32, .v0_0_2, 11155111);
    const enable = v.validator().getEnableData();
    const expected = hexConst("000000000000000000000000000000000000000000000000000000000000111100000000000000000000000000000000000000000000000000000000000022223333333333333333333333333333333333333333333333333333333333333333");
    try testing.expectEqualSlices(u8, &expected, enable);
}

test "getStubSignature matches the reference dummy" {
    var mock = MockSigner{};
    var v = WebAuthnValidator.init(mock.signer(), 1, 2, [_]u8{0} ** 32, .v0_0_2, 11155111);
    const stub = v.validator().getStubSignature();
    try testing.expectEqualSlices(u8, &STUB_SIGNATURE, stub);
    // sanity: the long dummy clientDataJSON makes this a 576-byte encoding
    try testing.expectEqual(@as(usize, 576), stub.len);
}

test "parseAndNormalizeSig: DER with high-S normalizes to low-S" {
    // DER of (r, N-sLow); low-S normalization must return (r, sLow).
    const der = hexConst("304502201234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef022100f012345e6789abcef012345f6789abcdacf92f0d0ea14a52e3cbff2263ecd11f");
    const rs = try parseAndNormalizeSig(&der);
    try testing.expectEqual(@as(u256, 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef), rs.r);
    try testing.expectEqual(@as(u256, 0x0fedcba0987654320fedcba0987654320fedcba0987654320fedcba098765432), rs.s);
}

test "signUserOp: full assertion encodes as the reference does" {
    // The mock returns a DER for (r, high-S); signUserOp must parse, low-S it,
    // find the type location, and ABI-encode to the viem oracle output.
    var mock = MockSigner{};
    var v = WebAuthnValidator.init(mock.signer(), 1, 2, [_]u8{0} ** 32, .v0_0_2, 11155111);
    const sig = try v.validator().signUserOp(testing.allocator, [_]u8{0xAB} ** 32);
    defer testing.allocator.free(sig);
    const expected = hexConst(
        "00000000000000000000000000000000000000000000000000000000000000c0" ++
        "0000000000000000000000000000000000000000000000000000000000000100" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef" ++
        "0fedcba0987654320fedcba0987654320fedcba0987654320fedcba098765432" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000004" ++
        "0102030400000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000028" ++
        "7b2274797065223a22776562617574686e2e676574222c226368616c6c656e67" ++
        "65223a224141227d000000000000000000000000000000000000000000000000");
    try testing.expectEqualSlices(u8, &expected, sig);
}

// A mock host signer returning a fixed assertion, for the encoding tests.
const MockSigner = struct {
    const auth_data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const cdj = "{\"type\":\"webauthn.get\",\"challenge\":\"AA\"}";
    // DER of (r, N-sLow) — high-S, so signUserOp exercises low-S normalization.
    const der = hexConst("304502201234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef022100f012345e6789abcef012345f6789abcdacf92f0d0ea14a52e3cbff2263ecd11f");

    fn signer(self: *MockSigner) WebAuthnSigner {
        return .{ .ptr = @ptrCast(self), .signFn = signImpl };
    }
    fn signImpl(_: *anyopaque, _: std.mem.Allocator, _: [32]u8) SignError!Assertion {
        return .{ .authenticator_data = &auth_data, .client_data_json = cdj, .der_signature = &der };
    }
};
