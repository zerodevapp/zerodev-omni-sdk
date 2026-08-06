//! C FFI exports for the ZeroDev Omni SDK.
//!
//! Provides opaque-handle-based API for creating Kernel v3 accounts,
//! building/signing/sending UserOperations from any language with C FFI.

const std = @import("std");
const builtin = @import("builtin");
const primitives = @import("primitives");

// Trap on panic instead of dumping a stack trace. The default handler walks
// the loaded images to symbolicate, pulling in dyld lookups the iOS simulator
// runtime does not provide, so the framework can load there.
pub const panic = std.debug.simple_panic;

const Address = primitives.Address;
const Hash = primitives.Hash;
const keccak = @import("core/keccak.zig");

// Internal modules (relative imports within the same package)
const core = @import("core/root.zig");
const KernelVersion = core.KernelVersion;
const create2 = core.create2;
const kernel_mod = core.kernel;
const userop_mod = core.userop;
const entrypoint_mod = core.entrypoint;
const bundler_mod = core.bundler;
const paymaster_mod = core.paymaster;
const transport = @import("transport");
const Client = transport.Client;
const EcdsaValidator = @import("validators/ecdsa.zig").EcdsaValidator;
const Validator = @import("validators/Validator.zig").Validator;
const SignError = @import("validators/Validator.zig").SignError;
const webauthn = @import("validators/webauthn.zig");
const weighted = @import("validators/weighted.zig");
const plugin = @import("plugin");
const signers = @import("signers");
const Signer = signers.Signer;
const LocalSigner = signers.local.LocalSigner;
const JsonRpcSigner = signers.json_rpc.JsonRpcSigner;
const CustomSigner = signers.custom.CustomSigner;
const CVTable = signers.custom.CVTable;

// ---- Allocator ----

fn defaultAllocator() std.mem.Allocator {
    return switch (builtin.target.cpu.arch) {
        .wasm32, .wasm64 => std.heap.wasm_allocator,
        else => std.heap.c_allocator,
    };
}

// ---- Canonical libc allocator exports (audit F-02) ----
//
// Hosts that hand buffers back to the SDK across FFI (HTTP responses,
// paymaster_data) should allocate via `aa_alloc` when they want the SDK to
// free with libc `free`. This mirrors what the SDK itself uses internally
// (c_allocator), so SDK-side `std.c.free` works correctly on pointers from
// aa_alloc on every platform. Hosts whose runtime can't produce libc-malloc
// pointers (Go runtime, Rust global allocator, etc.) must instead register a
// matching free callback via `aa_context_set_http_free_fn` /
// `aa_context_set_paymaster_free_fn`.

pub export fn aa_alloc(size: usize) callconv(.c) ?*anyopaque {
    if (size == 0) return null;
    return std.c.malloc(size);
}

// `aa_free` is defined further down (used to free SDK-owned buffers like
// the receipt JSON); it doubles as the host-side libc free for F-02.

// ---- Thread-local error buffer ----

threadlocal var last_error_buf: [1024]u8 = undefined;
threadlocal var last_error_len: usize = 0;

fn setLastError(comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(&last_error_buf, fmt, args) catch {
        last_error_len = 0;
        return;
    };
    last_error_len = msg.len;
}

fn setLastErrorStr(msg: []const u8) void {
    // Reserve one byte for the NUL terminator. Audit F-03: prior version could
    // fill the buffer to capacity without terminator → OOB read in C caller.
    const copy_len = @min(msg.len, last_error_buf.len - 1);
    @memcpy(last_error_buf[0..copy_len], msg[0..copy_len]);
    last_error_buf[copy_len] = 0;
    last_error_len = copy_len;
}

// ---- Status enum (matches aa.h) ----

pub const Status = enum(c_int) {
    ok = 0,
    null_out_ptr = 1,
    invalid_url = 2,
    out_of_memory = 3,
    invalid_private_key = 4,
    invalid_kernel_version = 5,
    null_context = 6,
    null_account = 7,
    null_userop = 8,
    get_address_failed = 9,
    build_userop_failed = 10,
    hash_userop_failed = 11,
    sign_userop_failed = 12,
    send_userop_failed = 13,
    estimate_gas_failed = 14,
    paymaster_failed = 15,
    no_calls = 16,
    invalid_hex = 17,
    apply_json_failed = 18,
    serialize_failed = 19,
    no_gas_middleware = 20,
    no_paymaster_middleware = 21,
    receipt_timeout = 22,
    receipt_failed = 23,
    invalid_signer = 24,
    encode_failed = 25,
};

// ---- Middleware types ----

pub const GasPrices = extern struct {
    max_fee_per_gas: u64,
    max_priority_fee_per_gas: u64,
};

/// Function pointer type for gas price middleware.
pub const GasPriceFn = *const fn (?*ContextImpl, ?*GasPrices) callconv(.c) Status;

/// Paymaster sponsorship phase.
pub const PaymasterPhase = enum(c_int) {
    stub = 0, // Before gas estimation (pm_getPaymasterStubData)
    final = 1, // After gas estimation (pm_getPaymasterData)
};

/// Result from paymaster middleware.
///
/// **Allocator contract (audit F-02):** `paymaster_data` MUST be either
///   (a) allocated via `aa_alloc` (or libc `malloc`), in which case the SDK
///       frees it via libc `free`, or
///   (b) allocated with a different allocator, in which case the host MUST
///       register a matching free callback via
///       `aa_context_set_paymaster_free_fn`.
///
/// Handing back a Go/Rust/Python-runtime pointer with no free fn registered
/// is undefined behavior. The built-in `aa_paymaster_zerodev` uses libc
/// allocation, so consumers using only the in-tree paymaster need no
/// additional wiring.
pub const PaymasterResult = extern struct {
    paymaster: [20]u8,
    paymaster_verification_gas_limit: u64,
    paymaster_post_op_gas_limit: u64,
    paymaster_data: ?[*]u8,
    paymaster_data_len: usize,
};

/// Function pointer type for paymaster middleware.
/// Receives the serialized UserOp JSON, entry point, chain ID, and phase.
/// Must fill `out` with paymaster address, data, and gas limits.
pub const PaymasterFn = *const fn (
    ?*ContextImpl, // ctx
    ?[*]const u8, // userop_json
    usize, // userop_json_len
    [*:0]const u8, // entry_point hex
    u64, // chain_id
    PaymasterPhase, // phase
    ?*PaymasterResult, // out
) callconv(.c) Status;

/// Optional free callback for `PaymasterResult.paymaster_data`. If set, the
/// SDK invokes this in place of libc `free` after consuming the data.
pub const PaymasterFreeFn = *const fn (
    ?*ContextImpl, // ctx (same as the paymaster middleware ctx)
    [*]u8, // paymaster_data ptr
    usize, // paymaster_data_len
) callconv(.c) void;

// ---- Context ----

pub const ContextImpl = struct {
    allocator: std.mem.Allocator,
    project_id: []u8,
    rpc_url: []u8,
    bundler_url: []u8,
    chain_id: u64,
    gas_middleware: ?GasPriceFn,
    paymaster_middleware: ?PaymasterFn,
    paymaster_free_fn: ?PaymasterFreeFn = null,
    http_fn: ?transport.HttpFn = null,
    http_ctx: ?*anyopaque = null,
    http_free_fn: ?transport.HttpFreeFn = null,
};

/// Copy the host HTTP transport config from a context onto a fresh Client.
/// Keeps the 5 call sites that spin up internal RPC clients in lock-step.
fn wireTransport(rpc: *Client, c: *const ContextImpl) void {
    rpc.http_fn = c.http_fn;
    rpc.http_ctx = c.http_ctx;
    rpc.http_free_fn = c.http_free_fn;
}

/// Release a `PaymasterResult.paymaster_data` buffer. Routes through the
/// host's free callback when registered; otherwise frees via libc (assumes
/// the paymaster middleware allocated via `aa_alloc`/libc malloc).
fn freePaymasterData(c: *ContextImpl, ptr: [*]u8, len: usize) void {
    if (c.paymaster_free_fn) |free_fn| {
        free_fn(c, ptr, len);
    } else {
        c.allocator.free(ptr[0..len]);
    }
}

pub export fn aa_context_create(
    project_id: [*:0]const u8,
    rpc_url: [*:0]const u8,
    bundler_url: [*:0]const u8,
    chain_id: u64,
    out: ?*?*ContextImpl,
) callconv(.c) Status {
    if (out == null) return .null_out_ptr;
    const allocator = defaultAllocator();

    const pid = std.mem.span(project_id);
    const rpc = std.mem.span(rpc_url);
    const bundler = std.mem.span(bundler_url);

    const impl = allocator.create(ContextImpl) catch {
        setLastError("out of memory creating context", .{});
        return .out_of_memory;
    };

    impl.* = .{
        .allocator = allocator,
        .project_id = allocator.dupe(u8, pid) catch {
            allocator.destroy(impl);
            return .out_of_memory;
        },
        .rpc_url = allocator.dupe(u8, rpc) catch {
            allocator.free(impl.project_id);
            allocator.destroy(impl);
            return .out_of_memory;
        },
        .bundler_url = allocator.dupe(u8, bundler) catch {
            allocator.free(impl.project_id);
            allocator.free(impl.rpc_url);
            allocator.destroy(impl);
            return .out_of_memory;
        },
        .chain_id = chain_id,
        .gas_middleware = null,
        .paymaster_middleware = null,
    };

    out.?.* = impl;
    return .ok;
}

pub export fn aa_context_destroy(ctx: ?*ContextImpl) callconv(.c) Status {
    const c = ctx orelse return .null_context;
    const a = c.allocator;
    a.free(c.project_id);
    a.free(c.rpc_url);
    a.free(c.bundler_url);
    a.destroy(c);
    return .ok;
}

// ---- Gas price middleware ----

pub export fn aa_context_set_gas_middleware(
    ctx: ?*ContextImpl,
    middleware: ?GasPriceFn,
) callconv(.c) Status {
    const c = ctx orelse return .null_context;
    c.gas_middleware = middleware;
    return .ok;
}

/// Built-in: ZeroDev gas price middleware.
/// Calls zd_getUserOperationGasPrice on the context's RPC endpoint.
pub export fn aa_gas_zerodev(
    ctx: ?*ContextImpl,
    out: ?*GasPrices,
) callconv(.c) Status {
    const c = ctx orelse return .null_context;
    if (out == null) return .null_out_ptr;

    const allocator = c.allocator;

    // Gas price is a read, so use the node RPC (rpc_url), not the bundler.
    // Fall back to the bundler URL for callers that predate the rpc_url split.
    const rpc_url: []const u8 = if (c.rpc_url.len > 0)
        c.rpc_url
    else if (c.bundler_url.len > 0)
        c.bundler_url
    else blk: {
        const url = core.buildRpcUrl(allocator, c.project_id, c.chain_id) catch {
            setLastError("failed to build RPC URL for gas price", .{});
            return .send_userop_failed;
        };
        break :blk url;
    };
    const url_allocated = c.rpc_url.len == 0 and c.bundler_url.len == 0;
    defer if (url_allocated) allocator.free(@constCast(rpc_url));

    var rpc = Client.init(allocator, rpc_url) catch {
        setLastError("failed to create RPC client for gas price", .{});
        return .send_userop_failed;
    };
    wireTransport(&rpc, c);
    defer rpc.deinit();

    const result = rpc.callWithParams("zd_getUserOperationGasPrice", &[_]std.json.Value{}) catch |err| {
        setLastError("zd_getUserOperationGasPrice failed: {s}", .{@errorName(err)});
        return .send_userop_failed;
    };
    defer transport.freeValue(allocator, result);

    if (result != .object) {
        setLastError("zd_getUserOperationGasPrice: unexpected response", .{});
        return .send_userop_failed;
    }

    const fast = result.object.get("fast") orelse {
        setLastError("zd_getUserOperationGasPrice: missing 'fast' field", .{});
        return .send_userop_failed;
    };
    if (fast != .object) {
        setLastError("zd_getUserOperationGasPrice: 'fast' is not an object", .{});
        return .send_userop_failed;
    }

    const mfpg = parseGasField(fast.object, "maxFeePerGas") orelse {
        setLastError("zd_getUserOperationGasPrice: missing maxFeePerGas", .{});
        return .send_userop_failed;
    };
    const mpfpg = parseGasField(fast.object, "maxPriorityFeePerGas") orelse {
        setLastError("zd_getUserOperationGasPrice: missing maxPriorityFeePerGas", .{});
        return .send_userop_failed;
    };

    out.?.* = .{
        .max_fee_per_gas = @intCast(mfpg),
        .max_priority_fee_per_gas = @intCast(mpfpg),
    };
    return .ok;
}

fn parseGasField(obj: std.json.ObjectMap, field: []const u8) ?u128 {
    const v = obj.get(field) orelse return null;
    if (v != .string) return null;
    return transport.parseHex(u128, v.string) catch null;
}

// ---- Paymaster middleware ----

pub export fn aa_context_set_paymaster_middleware(
    ctx: ?*ContextImpl,
    middleware: ?PaymasterFn,
) callconv(.c) Status {
    const c = ctx orelse return .null_context;
    c.paymaster_middleware = middleware;
    return .ok;
}

/// Audit F-02. Register a free function for `PaymasterResult.paymaster_data`.
/// Pass NULL to clear (the SDK then assumes libc allocation and frees with
/// libc free — safe for the built-in `aa_paymaster_zerodev`).
pub export fn aa_context_set_paymaster_free_fn(
    ctx: ?*ContextImpl,
    free_fn: ?PaymasterFreeFn,
) callconv(.c) Status {
    const c = ctx orelse return .null_context;
    c.paymaster_free_fn = free_fn;
    return .ok;
}

pub export fn aa_context_set_http_transport(
    ctx: ?*ContextImpl,
    http_fn: ?transport.HttpFn,
    http_ctx: ?*anyopaque,
) callconv(.c) Status {
    const c = ctx orelse return .null_context;
    c.http_fn = http_fn;
    c.http_ctx = http_ctx;
    return .ok;
}

/// Audit F-02. Register a free function for response buffers returned by
/// the HTTP transport. Pass NULL to clear (the SDK then frees with libc
/// free — safe only when the host allocates via `aa_alloc` or libc malloc).
pub export fn aa_context_set_http_free_fn(
    ctx: ?*ContextImpl,
    free_fn: ?transport.HttpFreeFn,
) callconv(.c) Status {
    const c = ctx orelse return .null_context;
    c.http_free_fn = free_fn;
    return .ok;
}

/// Built-in: ZeroDev paymaster middleware.
/// Calls pm_getPaymasterStubData (stub phase) or pm_getPaymasterData (final phase).
pub export fn aa_paymaster_zerodev(
    ctx: ?*ContextImpl,
    userop_json: ?[*]const u8,
    userop_json_len: usize,
    entry_point: [*:0]const u8,
    chain_id: u64,
    phase: PaymasterPhase,
    out: ?*PaymasterResult,
) callconv(.c) Status {
    const c = ctx orelse return .null_context;
    if (out == null) return .null_out_ptr;
    if (userop_json == null) return .paymaster_failed;

    const allocator = c.allocator;
    const json_str = userop_json.?[0..userop_json_len];
    const ep_str = std.mem.span(entry_point);

    // Resolve RPC URL
    const rpc_url: []const u8 = if (c.bundler_url.len > 0)
        c.bundler_url
    else blk: {
        const url = core.buildRpcUrl(allocator, c.project_id, c.chain_id) catch {
            setLastError("failed to build RPC URL for paymaster", .{});
            return .paymaster_failed;
        };
        break :blk url;
    };
    const url_allocated = c.bundler_url.len == 0;
    defer if (url_allocated) allocator.free(@constCast(rpc_url));

    var rpc = Client.init(allocator, rpc_url) catch {
        setLastError("failed to create RPC client for paymaster", .{});
        return .paymaster_failed;
    };
    wireTransport(&rpc, c);
    defer rpc.deinit();

    // Parse the UserOp JSON into a std.json.Value for the RPC call
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        setLastError("failed to parse UserOp JSON in paymaster middleware", .{});
        return .paymaster_failed;
    };
    defer parsed.deinit();

    switch (phase) {
        .stub => {
            const stub = paymaster_mod.getPaymasterStubData(&rpc, allocator, parsed.value, ep_str, chain_id) catch |err| {
                setLastError("pm_getPaymasterStubData failed: {s}", .{@errorName(err)});
                return .paymaster_failed;
            };

            // Copy paymaster_data so it outlives the function (caller frees)
            const data_copy = allocator.alloc(u8, stub.paymaster_data.len) catch return .out_of_memory;
            @memcpy(data_copy, stub.paymaster_data);
            stub.deinit(allocator);

            out.?.* = .{
                .paymaster = stub.paymaster.bytes,
                .paymaster_verification_gas_limit = 0,
                .paymaster_post_op_gas_limit = @intCast(stub.paymaster_post_op_gas_limit),
                .paymaster_data = data_copy.ptr,
                .paymaster_data_len = data_copy.len,
            };
            return .ok;
        },
        .final => {
            const final = paymaster_mod.getPaymasterData(&rpc, allocator, parsed.value, ep_str, chain_id) catch |err| {
                setLastError("pm_getPaymasterData failed: {s}", .{@errorName(err)});
                return .paymaster_failed;
            };

            const data_copy = allocator.alloc(u8, final.paymaster_data.len) catch return .out_of_memory;
            @memcpy(data_copy, final.paymaster_data);
            final.deinit(allocator);

            out.?.* = .{
                .paymaster = final.paymaster.bytes,
                .paymaster_verification_gas_limit = 0,
                .paymaster_post_op_gas_limit = 0,
                .paymaster_data = data_copy.ptr,
                .paymaster_data_len = data_copy.len,
            };
            return .ok;
        },
    }
}

// ---- Signer (opaque handle) ----

const SignerKind = union(enum) {
    local: LocalSigner,
    json_rpc: JsonRpcSigner,
    custom: CustomSigner,
};

pub const SignerImpl = struct {
    allocator: std.mem.Allocator,
    kind: SignerKind,

    pub fn getSigner(self: *SignerImpl) Signer {
        return switch (self.kind) {
            .local => |*l| l.signer(),
            .json_rpc => |*r| r.signer(),
            .custom => |*c| c.signer(),
        };
    }
};

pub export fn aa_signer_local(
    private_key: ?[*]const u8,
    out: ?*?*SignerImpl,
) callconv(.c) Status {
    if (out == null) return .null_out_ptr;
    if (private_key == null) return .invalid_private_key;

    const allocator = defaultAllocator();
    var pk: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &pk); // F-04: don't leave the key on the stack
    @memcpy(&pk, private_key.?[0..32]);

    const local = LocalSigner.init(allocator, pk) catch {
        setLastError("failed to initialize local signer from private key", .{});
        return .invalid_private_key;
    };

    const impl = allocator.create(SignerImpl) catch return .out_of_memory;
    impl.* = .{ .allocator = allocator, .kind = .{ .local = local } };
    out.?.* = impl;
    return .ok;
}

pub export fn aa_signer_generate(
    out: ?*?*SignerImpl,
) callconv(.c) Status {
    if (out == null) return .null_out_ptr;

    const allocator = defaultAllocator();
    var pk: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &pk); // F-04: don't leave the key on the stack

    // Zig 0.16 exposes randomness through `std.Io`. We require the OS CSPRNG;
    // fall back is intentionally absent. Audit F-01: previously a `catch` here
    // dropped to `io.random` (non-cryptographic), producing brute-forceable
    // keys when `getrandom` was unavailable (seccomp, kernel < 3.17, etc).
    const io = std.Io.Threaded.global_single_threaded.io();
    io.randomSecure(&pk) catch {
        setLastError("CSPRNG unavailable; refusing to generate private key", .{});
        return .invalid_private_key;
    };

    const local = LocalSigner.init(allocator, pk) catch {
        setLastError("failed to initialize signer from generated key", .{});
        return .invalid_private_key;
    };

    const impl = allocator.create(SignerImpl) catch return .out_of_memory;
    impl.* = .{ .allocator = allocator, .kind = .{ .local = local } };
    out.?.* = impl;
    return .ok;
}

pub export fn aa_signer_rpc(
    rpc_url: ?[*:0]const u8,
    address: ?[*]const u8,
    out: ?*?*SignerImpl,
) callconv(.c) Status {
    if (out == null) return .null_out_ptr;
    const url_ptr = rpc_url orelse return .invalid_signer;
    if (address == null) return .null_out_ptr;

    const allocator = defaultAllocator();
    const url = std.mem.span(url_ptr);

    var addr: [20]u8 = undefined;
    @memcpy(&addr, address.?[0..20]);

    const rpc_signer = JsonRpcSigner.init(allocator, url, addr) catch {
        setLastError("failed to initialize JSON-RPC signer", .{});
        return .out_of_memory;
    };

    const impl = allocator.create(SignerImpl) catch return .out_of_memory;
    impl.* = .{ .allocator = allocator, .kind = .{ .json_rpc = rpc_signer } };
    out.?.* = impl;
    return .ok;
}

pub export fn aa_signer_custom(
    vtable: ?*const CVTable,
    user_ctx: ?*anyopaque,
    out: ?*?*SignerImpl,
) callconv(.c) Status {
    if (out == null) return .null_out_ptr;
    const vt = vtable orelse return .invalid_signer;

    const allocator = defaultAllocator();
    const impl = allocator.create(SignerImpl) catch return .out_of_memory;
    impl.* = .{
        .allocator = allocator,
        .kind = .{ .custom = .{ .vtable = vt, .user_ctx = user_ctx } },
    };
    out.?.* = impl;
    return .ok;
}

/// C-visible EIP-7702 authorization struct. Layout matches `aa_authorization_t`.
pub const CAuthorization = extern struct {
    chain_id: u64,
    address: [20]u8,
    nonce: u64,
    y_parity: u8,
    r: [32]u8,
    s: [32]u8,
};

/// Sign an EIP-7702 authorization (chainId, delegation-target, EOA-nonce).
/// Works on any signer; custom signers may implement this natively via their
/// vtable or fall back to the default hash-then-sign path.
pub export fn aa_signer_sign_authorization(
    signer: ?*SignerImpl,
    chain_id: u64,
    address: ?[*]const u8,
    nonce: u64,
    out: ?*CAuthorization,
) callconv(.c) Status {
    const s = signer orelse return .invalid_signer;
    const addr_ptr = address orelse return .null_out_ptr;
    const o = out orelse return .null_out_ptr;

    var addr: [20]u8 = undefined;
    @memcpy(&addr, addr_ptr[0..20]);

    const sig_iface = s.getSigner();
    const signed = sig_iface.signAuthorization(chain_id, addr, nonce) catch {
        setLastError("signAuthorization failed", .{});
        return .sign_userop_failed;
    };

    o.* = .{
        .chain_id = signed.chain_id,
        .address = signed.address,
        .nonce = signed.nonce,
        .y_parity = signed.y_parity,
        .r = signed.r,
        .s = signed.s,
    };
    return .ok;
}

pub export fn aa_signer_destroy(signer: ?*SignerImpl) callconv(.c) void {
    const s = signer orelse return;
    // Audit F-04: wipe any secret material before releasing the allocation.
    // Capture the allocator first — the broader secureZero below clobbers
    // `s.allocator`'s function pointers, so we'd crash on `s.allocator.destroy(s)`
    // otherwise.
    const allocator = s.allocator;
    switch (s.kind) {
        .local => |*l| l.deinit(),
        .json_rpc => |*r| r.deinit(),
        .custom => {}, // host owns the secret state; nothing to wipe on our side
    }
    std.crypto.secureZero(u8, std.mem.asBytes(&s.kind));
    allocator.destroy(s);
}

// ---- Account ----

pub const AccountMode = enum { kernel_create2, eip7702 };

/// C-facing kernel version constants. Mirror the `aa_kernel_version` enum in
/// include/aa.h — pass these (not raw integers) when calling the FFI.
pub const AA_KERNEL_V3_3: c_int = 0;

/// Raw bytes of the Kernel v3.3 implementation address — the delegation target
/// for EIP-7702 accounts.
pub const KERNEL_V3_3_DELEGATION_TARGET: [20]u8 = core.KERNEL_V3_3_DELEGATION_TARGET;

/// C-visible WebAuthn assertion the host fills after running the passkey
/// ceremony. Its buffers need only stay valid until the sign callback returns.
pub const CWebAuthnAssertion = extern struct {
    authenticator_data: ?[*]const u8,
    authenticator_data_len: usize,
    client_data_json: ?[*]const u8,
    client_data_json_len: usize,
    der_signature: ?[*]const u8,
    der_signature_len: usize,
};

/// Host callback that runs the Face ID / Touch ID ceremony with the challenge
/// (the UserOp hash) and fills the assertion. Returns 0 on success.
pub const WebAuthnSignFn = *const fn (?*anyopaque, *const [32]u8, *CWebAuthnAssertion) callconv(.c) c_int;

/// Bridges the host's passkey callback to the WebAuthn validator's signer. Held
/// at a stable address inside AccountImpl so the validator can point at it.
pub const PasskeyBridge = struct {
    sign_fn: WebAuthnSignFn,
    user_ctx: ?*anyopaque,

    pub fn webAuthnSigner(self: *PasskeyBridge) webauthn.WebAuthnSigner {
        return .{ .ptr = @ptrCast(self), .signFn = signImpl };
    }

    fn signImpl(ptr: *anyopaque, allocator: std.mem.Allocator, challenge: [32]u8) SignError!webauthn.Assertion {
        const self: *PasskeyBridge = @ptrCast(@alignCast(ptr));
        var out: CWebAuthnAssertion = undefined;
        if (self.sign_fn(self.user_ctx, &challenge, &out) != 0) return SignError.SigningFailed;
        // Copy the host's buffers into the arena — they may only live for the call.
        const ad = out.authenticator_data orelse return SignError.SigningFailed;
        const cd = out.client_data_json orelse return SignError.SigningFailed;
        const der = out.der_signature orelse return SignError.SigningFailed;
        return .{
            .authenticator_data = try allocator.dupe(u8, ad[0..out.authenticator_data_len]),
            .client_data_json = try allocator.dupe(u8, cd[0..out.client_data_json_len]),
            .der_signature = try allocator.dupe(u8, der[0..out.der_signature_len]),
        };
    }
};

/// An account's root validator: a local ECDSA owner, or a passkey (WebAuthn)
/// owner driven by a host callback.
pub const AccountValidator = union(enum) {
    ecdsa: EcdsaValidator,
    webauthn: struct {
        bridge: PasskeyBridge,
        validator: webauthn.WebAuthnValidator,
    },
};

pub const AccountImpl = struct {
    context: *ContextImpl,
    /// The local signer, for ECDSA / EIP-7702 accounts. Null for passkey owners.
    signer: ?*SignerImpl,
    validator_kind: AccountValidator,
    kernel_version: KernelVersion,
    index: u32,
    owner_address: Address,
    sender_address: Address,
    mode: AccountMode = .kernel_create2,
    /// Cached on-chain delegation status for EIP-7702 accounts. Null until first lookup.
    delegation_installed: ?bool = null,

    pub fn getValidator(self: *AccountImpl) Validator {
        return switch (self.validator_kind) {
            .ecdsa => |*e| e.validator(),
            .webauthn => |*w| w.validator.validator(),
        };
    }

    /// Whether signing needs a user gesture — then gas estimation uses the stub
    /// so the user is prompted only once, for the final signature.
    pub fn interactiveSigning(self: *AccountImpl) bool {
        return self.validator_kind == .webauthn;
    }

    /// The MetaFactory deploy calldata for this account's first UserOp.
    pub fn buildFactoryData(self: *AccountImpl, allocator: std.mem.Allocator) ![]u8 {
        return switch (self.validator_kind) {
            .ecdsa => create2.buildFactoryCalldata(allocator, self.owner_address, @as(u256, self.index), self.kernel_version),
            .webauthn => |*w| create2.buildFactoryCalldataGeneric(
                allocator,
                Address.fromBytes(w.validator.addr),
                &w.validator.enable_data,
                @as(u256, self.index),
                self.kernel_version,
            ),
        };
    }
};

/// The signature to use for gas estimation: the borrowed stub (duped into the
/// arena) for interactive signers, or a real signature for ECDSA.
fn estimationSignature(allocator: std.mem.Allocator, val: Validator, interactive: bool, hash: [32]u8) SignError![]u8 {
    if (interactive) return allocator.dupe(u8, val.getStubSignature());
    return val.signUserOp(allocator, hash);
}

/// Create a Kernel smart account.
///
/// `address` may be NULL, in which case the sender address is derived
/// counterfactually via CREATE2 from `(owner_address, index, version)` — the
/// standard flow. When non-NULL, it explicitly pins the account's sender to
/// that address.
///
/// This is the migration path for accounts whose original CREATE2 inputs
/// (older kernel version, factory salt) this SDK cannot reproduce — post-
/// upgrade the on-chain address is fixed but `(signer, version, index)` in
/// the new SDK derives a different one. The caller passes the correct
/// address; the SDK has nothing to cross-check against, since the original
/// CREATE2 formula lives in the old SDK this one replaced.
///
/// Pinning affects the sender only. Factory init_code is still emitted on
/// the first UserOp exactly as it would be for a counterfactually-derived
/// account (governed by nonce == 0). Callers pinning an already-deployed
/// account whose EntryPoint nonce is still 0 (rare — funded but never
/// used) should send the first op via the low-level API and drop the
/// factory bytes themselves.
pub export fn aa_account_create(
    ctx: ?*ContextImpl,
    signer: ?*SignerImpl,
    version: c_int,
    index: u32,
    address: ?[*]const u8,
    out: ?*?*AccountImpl,
) callconv(.c) Status {
    if (out == null) return .null_out_ptr;
    const c = ctx orelse return .null_context;
    const s = signer orelse return .invalid_signer;

    const kv = KernelVersion.fromInt(@intCast(version)) orelse {
        setLastError("invalid kernel version: {d}", .{version});
        return .invalid_kernel_version;
    };

    const owner_addr = Address.fromBytes(s.getSigner().getAddress());
    const sender_addr = if (address) |a|
        Address.fromBytes(a[0..20].*)
    else
        create2.getKernelAddress(owner_addr, @as(u256, index), kv) catch {
            setLastError("failed to compute kernel address", .{});
            return .get_address_failed;
        };

    const impl = c.allocator.create(AccountImpl) catch return .out_of_memory;
    impl.* = .{
        .context = c,
        .signer = s,
        .validator_kind = .{ .ecdsa = EcdsaValidator.init(s.getSigner()) },
        .kernel_version = kv,
        .index = index,
        .owner_address = owner_addr,
        .sender_address = sender_addr,
    };

    out.?.* = impl;
    return .ok;
}

/// Create an EIP-7702 account. The account's address is the signer's EOA address;
/// there is no CREATE2, no init code, and no index — delegation is installed via
/// an authorization tuple on the first UserOperation. Today only Kernel v3.3
/// supports EIP-7702; other versions will be rejected.
pub export fn aa_context_new_account_7702(
    ctx: ?*ContextImpl,
    signer: ?*SignerImpl,
    version: c_int,
    out: ?*?*AccountImpl,
) callconv(.c) Status {
    if (out == null) return .null_out_ptr;
    const c = ctx orelse return .null_context;
    const s = signer orelse return .invalid_signer;

    const kv = KernelVersion.fromInt(@intCast(version)) orelse {
        setLastError("invalid kernel version: {d}", .{version});
        return .invalid_kernel_version;
    };

    if (kv.delegationTarget() == null) {
        setLastError("kernel {s} does not support EIP-7702", .{kv.toString()});
        return .invalid_kernel_version;
    }

    const allocator = c.allocator;
    const owner_addr = Address.fromBytes(s.getSigner().getAddress());

    const impl = allocator.create(AccountImpl) catch return .out_of_memory;
    impl.* = .{
        .context = c,
        .signer = s,
        .validator_kind = .{ .ecdsa = EcdsaValidator.init(s.getSigner()) },
        .kernel_version = kv,
        .index = 0,
        .owner_address = owner_addr,
        // For 7702, sender == owner (EOA).
        .sender_address = owner_addr,
        .mode = .eip7702,
        .delegation_installed = null,
    };

    out.?.* = impl;
    return .ok;
}

/// Create a passkey (WebAuthn) owned account. The account is owned by the
/// credential (pub_x, pub_y, authenticator_id_hash); sign_fn runs the ceremony
/// on the host. contract_version selects the WebAuthn validator (0=v0.0.1,
/// 1=v0.0.2, 2=v0.0.3). The counterfactual address matches @zerodev/sdk.
pub export fn aa_account_create_passkey(
    ctx: ?*ContextImpl,
    sign_fn: ?WebAuthnSignFn,
    user_ctx: ?*anyopaque,
    pub_x: ?[*]const u8,
    pub_y: ?[*]const u8,
    authenticator_id_hash: ?[*]const u8,
    contract_version: c_int,
    chain_id: u64,
    version: c_int,
    index: u32,
    out: ?*?*AccountImpl,
) callconv(.c) Status {
    if (out == null) return .null_out_ptr;
    const c = ctx orelse return .null_context;
    const sfn = sign_fn orelse return .invalid_signer;
    if (pub_x == null or pub_y == null or authenticator_id_hash == null) return .null_out_ptr;

    const kv = KernelVersion.fromInt(@intCast(version)) orelse {
        setLastError("invalid kernel version: {d}", .{version});
        return .invalid_kernel_version;
    };
    const cv: webauthn.ContractVersion = switch (contract_version) {
        0 => .v0_0_1,
        1 => .v0_0_2,
        2 => .v0_0_3,
        else => {
            setLastError("invalid WebAuthn contract version: {d}", .{contract_version});
            return .invalid_signer;
        },
    };

    const x = std.mem.readInt(u256, pub_x.?[0..32], .big);
    const y = std.mem.readInt(u256, pub_y.?[0..32], .big);
    var id_hash: [32]u8 = undefined;
    @memcpy(&id_hash, authenticator_id_hash.?[0..32]);

    const allocator = c.allocator;
    const impl = allocator.create(AccountImpl) catch return .out_of_memory;

    // Place the bridge at its final (heap) address first, then build the
    // validator pointing at it.
    impl.validator_kind = .{ .webauthn = .{
        .bridge = .{ .sign_fn = sfn, .user_ctx = user_ctx },
        .validator = undefined,
    } };
    impl.validator_kind.webauthn.validator = webauthn.WebAuthnValidator.init(
        impl.validator_kind.webauthn.bridge.webAuthnSigner(),
        x,
        y,
        id_hash,
        cv,
        chain_id,
    );

    const validator_addr = Address.fromBytes(webauthn.validatorAddress(cv));
    const enable = webauthn.WebAuthnValidator.encodeEnableData(x, y, id_hash);
    const sender_addr = create2.getKernelAddressGeneric(allocator, validator_addr, &enable, @as(u256, index), kv) catch {
        allocator.destroy(impl);
        setLastError("failed to compute passkey account address", .{});
        return .get_address_failed;
    };

    impl.context = c;
    impl.signer = null;
    impl.kernel_version = kv;
    impl.index = index;
    // No EOA owner; the validator address stands in for owner-address uses.
    impl.owner_address = validator_addr;
    impl.sender_address = sender_addr;
    impl.mode = .kernel_create2;
    impl.delegation_installed = null;

    out.?.* = impl;
    return .ok;
}

pub export fn aa_account_get_address(
    account: ?*AccountImpl,
    addr_out: ?[*]u8,
) callconv(.c) Status {
    const acc = account orelse return .null_account;
    if (addr_out == null) return .null_out_ptr;
    @memcpy(addr_out.?[0..20], &acc.sender_address.bytes);
    return .ok;
}


pub export fn aa_account_destroy(account: ?*AccountImpl) callconv(.c) Status {
    const acc = account orelse return .null_account;
    acc.context.allocator.destroy(acc);
    return .ok;
}

// ---- UserOp ----

const UserOpImpl = struct {
    arena: std.heap.ArenaAllocator,
    sender: Address,
    nonce: u256,
    init_code: []u8,
    call_data: []u8,
    call_gas_limit: u128,
    verification_gas_limit: u128,
    pre_verification_gas: u256,
    max_fee_per_gas: u128,
    max_priority_fee_per_gas: u128,
    paymaster_and_data: []u8,
    signature: []u8,
    chain_id: u64,
    authorization: ?core.Authorization = null,
};

pub const CCall = extern struct {
    target: [20]u8,
    value_be: [32]u8,
    calldata: ?[*]const u8,
    calldata_len: usize,
};

const AuthPrepError = error{ RpcFailed, SignFailed };

/// For an EIP-7702 account, checks on-chain delegation status and signs the
/// authorization tuple if needed. Returns null for non-7702 accounts OR when
/// the delegation is already installed. On error, sets the last error string.
fn prepareEip7702Authorization(
    acc: *AccountImpl,
    rpc: *Client,
    a: std.mem.Allocator,
    chain_id: u64,
) AuthPrepError!?core.Authorization {
    if (acc.mode != .eip7702) return null;

    // Version validated at account creation — unreachable here.
    const target = acc.kernel_version.delegationTarget() orelse unreachable;

    const installed = if (acc.delegation_installed) |cached| cached else blk: {
        const code = rpc.getCode(acc.owner_address) catch |err| {
            setLastError("eth_getCode for 7702 delegation check failed: {s}", .{@errorName(err)});
            return AuthPrepError.RpcFailed;
        };
        defer a.free(code);
        // Delegation marker: 0xef0100 || <20-byte-target>. Total 23 bytes.
        const is_installed = code.len >= 23 and
            code[0] == 0xef and code[1] == 0x01 and code[2] == 0x00 and
            std.mem.eql(u8, code[3..23], &target);
        if (is_installed) acc.delegation_installed = true;
        break :blk is_installed;
    };

    if (installed) return null;

    const eoa_nonce = rpc.getTransactionCountAt(acc.owner_address, "pending") catch |err| {
        setLastError("eth_getTransactionCount(pending) failed: {s}", .{@errorName(err)});
        return AuthPrepError.RpcFailed;
    };
    // EIP-7702 is an EOA path, so a local signer is always present here.
    const signer_impl = acc.signer orelse return AuthPrepError.SignFailed;
    const signer_iface = signer_impl.getSigner();
    const signed = signer_iface.signAuthorization(chain_id, target, eoa_nonce) catch |err| {
        setLastError("signAuthorization failed: {s}", .{@errorName(err)});
        return AuthPrepError.SignFailed;
    };
    return .{
        .chain_id = signed.chain_id,
        .address = signed.address,
        .nonce = signed.nonce,
        .y_parity = signed.y_parity,
        .r = signed.r,
        .s = signed.s,
    };
}

pub export fn aa_userop_build(
    account: ?*AccountImpl,
    calls: ?[*]const CCall,
    calls_len: usize,
    out: ?*?*UserOpImpl,
) callconv(.c) Status {
    if (out == null) return .null_out_ptr;
    const acc = account orelse return .null_account;
    if (calls == null or calls_len == 0) return .no_calls;

    const allocator = acc.context.allocator;

    // Convert C calls to kernel Executions and encode
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var execs = a.alloc(kernel_mod.Execution, calls_len) catch {
        return .out_of_memory;
    };

    for (0..calls_len) |i| {
        const c_call = calls.?[i];
        const target = Address.fromBytes(c_call.target);
        const value: u256 = std.mem.readInt(u256, &c_call.value_be, .big);

        var data: []const u8 = &[_]u8{};
        if (c_call.calldata != null and c_call.calldata_len > 0) {
            data = c_call.calldata.?[0..c_call.calldata_len];
        }

        execs[i] = .{
            .to = target,
            .value = value,
            .data = data,
        };
    }

    // Encode calldata using kernel execute
    const call_data = if (calls_len == 1)
        kernel_mod.encodeExecute(a, execs[0]) catch {
            setLastError("failed to encode execute calldata", .{});
            return .build_userop_failed;
        }
    else
        kernel_mod.encodeExecuteBatch(a, execs) catch {
            setLastError("failed to encode batch execute calldata", .{});
            return .build_userop_failed;
        };

    // Build init_code (CREATE2 only) and, for EIP-7702, prepare the authorization
    // tuple for the first UserOp so bindings that use the low-level
    // build/hash/sign/to_json pipeline produce a valid on-chain first op.
    var init_code: []u8 = &[_]u8{};
    var eip7702_auth: ?core.Authorization = null;
    if (acc.mode == .kernel_create2) {
        const factory_data = create2.buildFactoryCalldata(
            a,
            acc.owner_address,
            @as(u256, acc.index),
            acc.kernel_version,
        ) catch {
            setLastError("failed to build factory calldata", .{});
            return .build_userop_failed;
        };

        const meta_factory = Address.fromHex(core.META_FACTORY) catch {
            return .build_userop_failed;
        };
        init_code = a.alloc(u8, 20 + factory_data.len) catch {
            return .out_of_memory;
        };
        @memcpy(init_code[0..20], &meta_factory.bytes);
        @memcpy(init_code[20..], factory_data);
    } else if (acc.mode == .eip7702) {
        // 7702 reads use the node RPC, not the bundler. Fall back to the
        // bundler URL for callers that predate the rpc_url split.
        const read_url: []const u8 = if (acc.context.rpc_url.len > 0)
            acc.context.rpc_url
        else if (acc.context.bundler_url.len > 0)
            acc.context.bundler_url
        else
            core.buildRpcUrl(a, acc.context.project_id, acc.context.chain_id) catch {
                setLastError("failed to build read RPC URL", .{});
                return .build_userop_failed;
            };
        var rpc = Client.init(a, read_url) catch {
            setLastError("failed to create read RPC client", .{});
            return .build_userop_failed;
        };
        wireTransport(&rpc, acc.context);
        eip7702_auth = prepareEip7702Authorization(acc, &rpc, a, acc.context.chain_id) catch |err| switch (err) {
            AuthPrepError.RpcFailed => return .build_userop_failed,
            AuthPrepError.SignFailed => return .sign_userop_failed,
        };
    }

    // Stub signature (65 zero bytes)
    const stub_sig = a.alloc(u8, 65) catch {
        return .out_of_memory;
    };
    @memset(stub_sig, 0);

    const impl = allocator.create(UserOpImpl) catch {
        return .out_of_memory;
    };

    impl.* = .{
        .arena = arena,
        .sender = acc.sender_address,
        .nonce = 0,
        .init_code = init_code,
        .call_data = call_data,
        .call_gas_limit = 0,
        .verification_gas_limit = 0,
        .pre_verification_gas = 0,
        .max_fee_per_gas = 0,
        .max_priority_fee_per_gas = 0,
        .paymaster_and_data = a.alloc(u8, 0) catch return .out_of_memory,
        .signature = stub_sig,
        .chain_id = acc.context.chain_id,
        .authorization = eip7702_auth,
    };

    out.?.* = impl;
    return .ok;
}

pub export fn aa_userop_hash(
    op: ?*UserOpImpl,
    account: ?*AccountImpl,
    hash_out: ?[*]u8,
) callconv(.c) Status {
    const userop = op orelse return .null_userop;
    _ = account orelse return .null_account;
    if (hash_out == null) return .null_out_ptr;

    const entry_point = Address.fromHex(core.ENTRY_POINT_V07) catch {
        return .hash_userop_failed;
    };

    const user_op = userop_mod.UserOp{
        .sender = userop.sender,
        .nonce = userop.nonce,
        .init_code = userop.init_code,
        .call_data = userop.call_data,
        .call_gas_limit = userop.call_gas_limit,
        .verification_gas_limit = userop.verification_gas_limit,
        .pre_verification_gas = userop.pre_verification_gas,
        .max_fee_per_gas = userop.max_fee_per_gas,
        .max_priority_fee_per_gas = userop.max_priority_fee_per_gas,
        .paymaster_and_data = userop.paymaster_and_data,
    };

    const hash = user_op.computeHash(entry_point, @as(u256, userop.chain_id));
    @memcpy(hash_out.?[0..32], &hash.bytes);
    return .ok;
}

pub export fn aa_userop_sign(
    op: ?*UserOpImpl,
    account: ?*AccountImpl,
) callconv(.c) Status {
    const userop = op orelse return .null_userop;
    const acc = account orelse return .null_account;

    const entry_point = Address.fromHex(core.ENTRY_POINT_V07) catch {
        return .sign_userop_failed;
    };

    const user_op = userop_mod.UserOp{
        .sender = userop.sender,
        .nonce = userop.nonce,
        .init_code = userop.init_code,
        .call_data = userop.call_data,
        .call_gas_limit = userop.call_gas_limit,
        .verification_gas_limit = userop.verification_gas_limit,
        .pre_verification_gas = userop.pre_verification_gas,
        .max_fee_per_gas = userop.max_fee_per_gas,
        .max_priority_fee_per_gas = userop.max_priority_fee_per_gas,
        .paymaster_and_data = userop.paymaster_and_data,
    };

    const hash = user_op.computeHash(entry_point, @as(u256, userop.chain_id));

    var val = acc.getValidator();
    // The signature is allocated in the arena, which the UserOp owns and frees.
    const a = userop.arena.allocator();
    const sig = val.signUserOp(a, hash.bytes) catch {
        setLastError("validator signing failed", .{});
        return .sign_userop_failed;
    };
    userop.signature = sig;

    return .ok;
}

pub export fn aa_userop_to_json(
    op: ?*UserOpImpl,
    json_out: ?*[*]u8,
    len_out: ?*usize,
) callconv(.c) Status {
    const userop = op orelse return .null_userop;
    if (json_out == null or len_out == null) return .null_out_ptr;

    const allocator = defaultAllocator();

    // Build JSON string manually. ArrayListUnmanaged in 0.16 dropped the
    // `.writer(allocator)` adapter — use `.print(allocator, fmt, args)` and
    // `.appendSlice(allocator, …)` instead.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    const sender_hex = userop.sender.toHex(allocator) catch return .serialize_failed;
    defer allocator.free(sender_hex);

    const init_code_hex = primitives.bytesToHex(allocator, userop.init_code) catch return .serialize_failed;
    defer allocator.free(init_code_hex);

    const call_data_hex = primitives.bytesToHex(allocator, userop.call_data) catch return .serialize_failed;
    defer allocator.free(call_data_hex);

    const sig_hex = primitives.bytesToHex(allocator, userop.signature) catch return .serialize_failed;
    defer allocator.free(sig_hex);

    const pm_hex = primitives.bytesToHex(allocator, userop.paymaster_and_data) catch return .serialize_failed;
    defer allocator.free(pm_hex);

    buf.print(allocator,
        \\{{"sender":"{s}","nonce":"0x{x}","initCode":"{s}","callData":"{s}",
    , .{ sender_hex, userop.nonce, init_code_hex, call_data_hex }) catch return .serialize_failed;

    buf.print(allocator,
        \\"callGasLimit":"0x{x}","verificationGasLimit":"0x{x}","preVerificationGas":"0x{x}",
    , .{ userop.call_gas_limit, userop.verification_gas_limit, userop.pre_verification_gas }) catch return .serialize_failed;

    buf.print(allocator,
        \\"maxFeePerGas":"0x{x}","maxPriorityFeePerGas":"0x{x}",
    , .{ userop.max_fee_per_gas, userop.max_priority_fee_per_gas }) catch return .serialize_failed;

    buf.print(allocator,
        \\"paymasterAndData":"{s}","signature":"{s}"
    , .{ pm_hex, sig_hex }) catch return .serialize_failed;

    if (userop.authorization) |auth| {
        const addr = Address.fromBytes(auth.address);
        const addr_hex = addr.toHex(allocator) catch return .serialize_failed;
        defer allocator.free(addr_hex);
        const r_hex = primitives.bytesToHex(allocator, &auth.r) catch return .serialize_failed;
        defer allocator.free(r_hex);
        const s_hex = primitives.bytesToHex(allocator, &auth.s) catch return .serialize_failed;
        defer allocator.free(s_hex);
        buf.print(allocator,
            \\,"eip7702Auth":{{"chainId":"0x{x}","address":"{s}","nonce":"0x{x}","yParity":"0x{x}","r":"{s}","s":"{s}"}}
        , .{ auth.chain_id, addr_hex, auth.nonce, auth.y_parity, r_hex, s_hex }) catch return .serialize_failed;
    }

    buf.appendSlice(allocator, "}") catch return .serialize_failed;

    // Copy to caller-owned buffer
    const result = allocator.alloc(u8, buf.items.len) catch return .out_of_memory;
    @memcpy(result, buf.items);

    json_out.?.* = result.ptr;
    len_out.?.* = result.len;
    return .ok;
}

pub export fn aa_userop_apply_gas_json(
    op: ?*UserOpImpl,
    gas_json: ?[*]const u8,
    gas_json_len: usize,
) callconv(.c) Status {
    const userop = op orelse return .null_userop;
    if (gas_json == null) return .apply_json_failed;

    const allocator = defaultAllocator();
    const json_str = gas_json.?[0..gas_json_len];

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        setLastError("failed to parse gas JSON", .{});
        return .apply_json_failed;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return .apply_json_failed;
    const obj = parsed.value.object;

    const parseField = struct {
        fn call(comptime T: type, o: std.json.ObjectMap, field: []const u8) ?T {
            const val = o.get(field) orelse return null;
            if (val != .string) return null;
            return transport.parseHex(T, val.string) catch null;
        }
    }.call;

    if (parseField(u128, obj, "callGasLimit")) |v| userop.call_gas_limit = v;
    if (parseField(u128, obj, "verificationGasLimit")) |v| userop.verification_gas_limit = v;
    if (parseField(u256, obj, "preVerificationGas")) |v| userop.pre_verification_gas = v;
    if (parseField(u128, obj, "maxFeePerGas")) |v| userop.max_fee_per_gas = v;
    if (parseField(u128, obj, "maxPriorityFeePerGas")) |v| userop.max_priority_fee_per_gas = v;

    return .ok;
}

pub export fn aa_userop_apply_paymaster_json(
    op: ?*UserOpImpl,
    pm_json: ?[*]const u8,
    pm_json_len: usize,
) callconv(.c) Status {
    const userop = op orelse return .null_userop;
    if (pm_json == null) return .apply_json_failed;

    const allocator = defaultAllocator();
    const json_str = pm_json.?[0..pm_json_len];

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        setLastError("failed to parse paymaster JSON", .{});
        return .apply_json_failed;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return .apply_json_failed;
    const obj = parsed.value.object;

    // Extract paymaster address + data and build paymasterAndData bytes
    const pm_addr_val = obj.get("paymaster") orelse return .apply_json_failed;
    if (pm_addr_val != .string) return .apply_json_failed;

    const pm_data_val = obj.get("paymasterData") orelse return .apply_json_failed;
    if (pm_data_val != .string) return .apply_json_failed;

    const pm_addr = Address.fromHex(pm_addr_val.string) catch return .apply_json_failed;
    const pm_data = primitives.hexToBytes(userop.arena.allocator(), pm_data_val.string) catch return .apply_json_failed;

    // paymasterAndData = paymaster(20) ++ data(variable)
    const a = userop.arena.allocator();
    var pmd = a.alloc(u8, 20 + pm_data.len) catch return .out_of_memory;
    @memcpy(pmd[0..20], &pm_addr.bytes);
    @memcpy(pmd[20..], pm_data);
    userop.paymaster_and_data = pmd;

    return .ok;
}

pub export fn aa_userop_destroy(op: ?*UserOpImpl) callconv(.c) Status {
    const userop = op orelse return .null_userop;
    const allocator = defaultAllocator();
    userop.arena.deinit();
    allocator.destroy(userop);
    return .ok;
}

pub export fn aa_free(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| std.c.free(p);
}

pub export fn aa_get_last_error() callconv(.c) [*:0]const u8 {
    if (last_error_len == 0) return "";
    // Always write the NUL terminator within the buffer. Audit F-03.
    last_error_buf[@min(last_error_len, last_error_buf.len - 1)] = 0;
    return @ptrCast(&last_error_buf);
}

threadlocal var last_rpc_error_cstr: [transport.last_rpc_error_max + 1]u8 = undefined;

/// The server's last JSON-RPC error as a C string, or "". aa_get_last_error is
/// the SDK's summary; this is the reason the server sent.
pub export fn aa_get_last_rpc_error() callconv(.c) [*:0]const u8 {
    const detail = transport.lastRpcError();
    if (detail.len == 0) return "";
    const n = @min(detail.len, last_rpc_error_cstr.len - 1);
    @memcpy(last_rpc_error_cstr[0..n], detail[0..n]);
    last_rpc_error_cstr[n] = 0;
    return @ptrCast(&last_rpc_error_cstr);
}

// ---- High-level send (full pipeline: nonce → build → paymaster → estimate → sign → send) ----

pub export fn aa_send_userop(
    account: ?*AccountImpl,
    calls: ?[*]const CCall,
    calls_len: usize,
    hash_out: ?[*]u8,
) callconv(.c) Status {
    const acc = account orelse return .null_account;
    if (calls == null or calls_len == 0) return .no_calls;
    if (hash_out == null) return .null_out_ptr;

    const allocator = acc.context.allocator;

    // Arena for all intermediate allocations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Reads use the node RPC; the bundler and paymaster use the bundler URL.
    // They may be different providers, so each needs its own client. Reads
    // fall back to the bundler URL for callers that predate the rpc_url split.
    const read_url: []const u8 = if (acc.context.rpc_url.len > 0)
        acc.context.rpc_url
    else if (acc.context.bundler_url.len > 0)
        acc.context.bundler_url
    else
        core.buildRpcUrl(a, acc.context.project_id, acc.context.chain_id) catch {
            setLastError("failed to build read RPC URL", .{});
            return .send_userop_failed;
        };
    var read_rpc = Client.init(a, read_url) catch {
        setLastError("failed to create read RPC client", .{});
        return .send_userop_failed;
    };
    wireTransport(&read_rpc, acc.context);

    const bundler_url: []const u8 = if (acc.context.bundler_url.len > 0)
        acc.context.bundler_url
    else
        core.buildRpcUrl(a, acc.context.project_id, acc.context.chain_id) catch {
            setLastError("failed to build bundler RPC URL", .{});
            return .send_userop_failed;
        };
    var rpc = Client.init(a, bundler_url) catch {
        setLastError("failed to create bundler RPC client", .{});
        return .send_userop_failed;
    };
    wireTransport(&rpc, acc.context);

    const chain_id = acc.context.chain_id;
    const entry_point = Address.fromHex(core.ENTRY_POINT_V07) catch return .send_userop_failed;

    // Step 1: Get nonce
    const nonce = entrypoint_mod.getNonce(&read_rpc, a, core.ENTRY_POINT_V07, acc.sender_address, 0) catch |err| {
        setLastError("getNonce failed: {s}", .{@errorName(err)});
        return .send_userop_failed;
    };

    // Step 2: Encode calldata
    var execs = a.alloc(kernel_mod.Execution, calls_len) catch return .out_of_memory;
    for (0..calls_len) |i| {
        const c_call = calls.?[i];
        var data: []const u8 = &[_]u8{};
        if (c_call.calldata != null and c_call.calldata_len > 0) {
            data = c_call.calldata.?[0..c_call.calldata_len];
        }
        execs[i] = .{
            .to = Address.fromBytes(c_call.target),
            .value = std.mem.readInt(u256, &c_call.value_be, .big),
            .data = data,
        };
    }

    const call_data = if (calls_len == 1)
        kernel_mod.encodeExecute(a, execs[0]) catch {
            setLastError("failed to encode execute calldata", .{});
            return .build_userop_failed;
        }
    else
        kernel_mod.encodeExecuteBatch(a, execs) catch {
            setLastError("failed to encode batch calldata", .{});
            return .build_userop_failed;
        };

    // Step 3: Build init_code (CREATE2 only) and optionally sign an EIP-7702
    // authorization for the first 7702 UserOp.
    var init_code: []u8 = &[_]u8{};
    var eip7702_auth: ?core.Authorization = null;
    if (acc.mode == .kernel_create2) {
        if (nonce == 0) {
            const factory_data = acc.buildFactoryData(a) catch {
                setLastError("failed to build factory calldata", .{});
                return .build_userop_failed;
            };
            const meta_factory = Address.fromHex(core.META_FACTORY) catch return .build_userop_failed;
            init_code = a.alloc(u8, 20 + factory_data.len) catch return .out_of_memory;
            @memcpy(init_code[0..20], &meta_factory.bytes);
            @memcpy(init_code[20..], factory_data);
        }
    } else {
        eip7702_auth = prepareEip7702Authorization(acc, &read_rpc, a, chain_id) catch |err| switch (err) {
            AuthPrepError.RpcFailed => return .send_userop_failed,
            AuthPrepError.SignFailed => return .sign_userop_failed,
        };
    }

    // Step 4: Get gas prices via middleware
    const gas_mw = acc.context.gas_middleware orelse {
        setLastError("no gas price middleware set — call aa_context_set_gas_middleware first", .{});
        return .no_gas_middleware;
    };
    var gas_prices: GasPrices = undefined;
    const gp_status = gas_mw(acc.context, &gas_prices);
    if (gp_status != .ok) return gp_status;

    // Step 5: Build UserOp with stub gas values
    var user_op = userop_mod.UserOp{
        .sender = acc.sender_address,
        .nonce = nonce,
        .init_code = init_code,
        .call_data = call_data,
        .call_gas_limit = 100_000,
        .verification_gas_limit = 500_000,
        .pre_verification_gas = 100_000,
        .max_fee_per_gas = @intCast(gas_prices.max_fee_per_gas),
        .max_priority_fee_per_gas = @intCast(gas_prices.max_priority_fee_per_gas),
        .paymaster_and_data = &[_]u8{},
        .authorization = eip7702_auth,
    };

    var val = acc.getValidator();
    // Gas estimation uses the stub for interactive (passkey) signing so the user
    // is prompted only once — for the final signature; ECDSA signs for real
    // throughout, exactly as before.
    const interactive = acc.interactiveSigning();

    // Paymaster middleware is optional — if not set, send unsponsored (user pays gas)
    const pm_mw = acc.context.paymaster_middleware;

    // Helper: sign UserOp, serialize to JSON string, call paymaster middleware
    const ep_hex: [*:0]const u8 = core.ENTRY_POINT_V07;

    // Step 6: Paymaster stub (before gas estimation) — skip if no paymaster
    if (pm_mw) |mw| {
        const stub_hash = user_op.computeHash(entry_point, @as(u256, chain_id));
        const stub_sig = estimationSignature(a, val, interactive, stub_hash.bytes) catch {
            setLastError("signing for paymaster stub failed", .{});
            return .sign_userop_failed;
        };
        const stub_json_val = user_op.toJsonValue(a, stub_sig) catch return .serialize_failed;
        const stub_json_str = std.json.Stringify.valueAlloc(a, stub_json_val, .{}) catch return .serialize_failed;

        var pm_result: PaymasterResult = undefined;
        const pm_status = mw(acc.context, stub_json_str.ptr, stub_json_str.len, ep_hex, chain_id, .stub, &pm_result);
        if (pm_status != .ok) return pm_status;
        defer if (pm_result.paymaster_data) |p| freePaymasterData(acc.context, p, pm_result.paymaster_data_len);

        const pm_addr = Address.fromBytes(pm_result.paymaster);
        const pm_data: []const u8 = if (pm_result.paymaster_data) |p| p[0..pm_result.paymaster_data_len] else &[_]u8{};

        const pm_packed_stub = paymaster_mod.packPaymasterAndData(
            a,
            pm_addr,
            500_000, // stub verification gas
            @intCast(pm_result.paymaster_post_op_gas_limit),
            pm_data,
        ) catch return .out_of_memory;
        user_op.paymaster_and_data = pm_packed_stub;
    }

    // Step 7: Estimate gas
    const gas = blk: {
        const est_hash = user_op.computeHash(entry_point, @as(u256, chain_id));
        const est_sig = estimationSignature(a, val, interactive, est_hash.bytes) catch {
            setLastError("signing for gas estimation failed", .{});
            return .sign_userop_failed;
        };
        const est_json = user_op.toJsonValue(a, est_sig) catch return .serialize_failed;

        break :blk bundler_mod.estimateUserOperationGas(&rpc, a, est_json, core.ENTRY_POINT_V07) catch |err| {
            setLastError("eth_estimateUserOperationGas failed: {s}", .{@errorName(err)});
            return .estimate_gas_failed;
        };
    };

    // Step 8: Apply gas estimates with 20% buffer
    user_op.call_gas_limit = gas.call_gas_limit + gas.call_gas_limit / 5;
    user_op.verification_gas_limit = gas.verification_gas_limit + gas.verification_gas_limit / 5;
    const pvg_u128: u128 = @truncate(gas.pre_verification_gas);
    user_op.pre_verification_gas = gas.pre_verification_gas + pvg_u128 / 5;

    // Step 9: Paymaster final (paymaster signs over the final gas values) — skip if no paymaster
    if (pm_mw) |mw| {
        // First repack with estimated gas limits so the paymaster sees correct values
        const pm_packed_est = paymaster_mod.packPaymasterAndData(
            a,
            Address.fromBytes(user_op.paymaster_and_data[0..20].*),
            gas.paymaster_verification_gas_limit,
            gas.paymaster_post_op_gas_limit,
            user_op.paymaster_and_data[52..],
        ) catch return .out_of_memory;
        user_op.paymaster_and_data = pm_packed_est;

        const final_hash = user_op.computeHash(entry_point, @as(u256, chain_id));
        const final_sig = val.signUserOp(a, final_hash.bytes) catch {
            setLastError("signing for final paymaster failed", .{});
            return .sign_userop_failed;
        };
        const final_json_val = user_op.toJsonValue(a, final_sig) catch return .serialize_failed;
        const final_json_str = std.json.Stringify.valueAlloc(a, final_json_val, .{}) catch return .serialize_failed;

        var pm_result: PaymasterResult = undefined;
        const pm_status = mw(acc.context, final_json_str.ptr, final_json_str.len, ep_hex, chain_id, .final, &pm_result);
        if (pm_status != .ok) return pm_status;
        defer if (pm_result.paymaster_data) |p| freePaymasterData(acc.context, p, pm_result.paymaster_data_len);

        const pm_addr = Address.fromBytes(pm_result.paymaster);
        const pm_data: []const u8 = if (pm_result.paymaster_data) |p| p[0..pm_result.paymaster_data_len] else &[_]u8{};

        const pm_packed_final = paymaster_mod.packPaymasterAndData(
            a,
            pm_addr,
            gas.paymaster_verification_gas_limit,
            gas.paymaster_post_op_gas_limit,
            pm_data,
        ) catch return .out_of_memory;
        user_op.paymaster_and_data = pm_packed_final;
    }

    // Step 10: Final sign
    const op_hash = user_op.computeHash(entry_point, @as(u256, chain_id));
    const real_sig = val.signUserOp(a, op_hash.bytes) catch {
        setLastError("final validator signing failed", .{});
        return .sign_userop_failed;
    };

    // Step 11: Send
    const send_json = user_op.toJsonValue(a, real_sig) catch {
        setLastError("failed to serialize final UserOp", .{});
        return .serialize_failed;
    };

    const op_hash_hex = bundler_mod.sendUserOperation(&rpc, a, send_json, core.ENTRY_POINT_V07) catch |err| {
        setLastError("eth_sendUserOperation failed: {s}", .{@errorName(err)});
        return .send_userop_failed;
    };

    // Copy UserOp hash bytes to output
    @memcpy(hash_out.?[0..32], &op_hash.bytes);

    // Also store the hex hash for potential debugging (log it)
    _ = op_hash_hex;

    return .ok;
}

// ---- Receipt polling ----

pub export fn aa_wait_for_user_operation_receipt(
    account: ?*AccountImpl,
    userop_hash: ?[*]const u8,
    timeout_ms: u32,
    poll_interval_ms: u32,
    json_out: ?*[*]u8,
    json_len_out: ?*usize,
) callconv(.c) Status {
    const acc = account orelse return .null_account;
    if (userop_hash == null) return .null_out_ptr;
    if (json_out == null) return .null_out_ptr;
    if (json_len_out == null) return .null_out_ptr;

    const allocator = acc.context.allocator;

    // Defaults: 60s timeout, 2s poll interval
    const timeout: u64 = if (timeout_ms == 0) 60_000 else @as(u64, timeout_ms);
    const interval: u64 = if (poll_interval_ms == 0) 2_000 else @as(u64, poll_interval_ms);

    // Build 0x-prefixed hex string from hash bytes
    var hash_hex_buf: [66]u8 = undefined;
    hash_hex_buf[0] = '0';
    hash_hex_buf[1] = 'x';
    const hex_chars = "0123456789abcdef";
    for (0..32) |i| {
        const b = userop_hash.?[i];
        hash_hex_buf[2 + i * 2] = hex_chars[b >> 4];
        hash_hex_buf[2 + i * 2 + 1] = hex_chars[b & 0x0f];
    }

    // Resolve RPC URL
    const rpc_url: []const u8 = if (acc.context.bundler_url.len > 0)
        acc.context.bundler_url
    else
        core.buildRpcUrl(allocator, acc.context.project_id, acc.context.chain_id) catch {
            setLastError("failed to build RPC URL for receipt polling", .{});
            return .receipt_failed;
        };
    const url_allocated = acc.context.bundler_url.len == 0;
    defer if (url_allocated) allocator.free(@constCast(rpc_url));

    var rpc = Client.init(allocator, rpc_url) catch {
        setLastError("failed to create RPC client for receipt polling", .{});
        return .receipt_failed;
    };
    wireTransport(&rpc, acc.context);
    defer rpc.deinit();

    // Build RPC params: [userOpHash]
    var params_arr = std.json.Array.init(allocator);
    defer params_arr.deinit();
    params_arr.append(.{ .string = &hash_hex_buf }) catch {
        setLastError("failed to build RPC params", .{});
        return .receipt_failed;
    };

    // Zig 0.16 removed std.Thread.sleep; sleeping is now an Io operation.
    const io = std.Io.Threaded.global_single_threaded.io();
    const sleep_duration = std.Io.Duration.fromMilliseconds(@intCast(interval));

    // Poll loop
    var elapsed: u64 = 0;
    while (elapsed < timeout) {
        const result = rpc.call("eth_getUserOperationReceipt", .{ .array = params_arr }) catch |err| {
            if (err == error.JsonRpcError) {
                // Not found yet, keep polling
                io.sleep(sleep_duration, .awake) catch {};
                elapsed += interval;
                continue;
            }
            setLastError("eth_getUserOperationReceipt failed: {s}", .{@errorName(err)});
            return .receipt_failed;
        };

        if (result == .null) {
            transport.freeValue(allocator, result);
            io.sleep(sleep_duration, .awake) catch {};
            elapsed += interval;
            continue;
        }

        defer transport.freeValue(allocator, result);

        // Stringify the full receipt JSON
        const json_str = std.json.Stringify.valueAlloc(allocator, result, .{}) catch {
            setLastError("failed to serialize receipt JSON", .{});
            return .serialize_failed;
        };

        json_out.?.* = json_str.ptr;
        json_len_out.?.* = json_str.len;
        return .ok;
    }

    setLastError("receipt polling timed out after {d}ms", .{timeout});
    return .receipt_timeout;
}

// ---- Validator enable-data and plugin lifecycle calldata ----
//
// These let the host install a validator (co-ownership / guardians) or rotate
// the account's owner. The account signs the resulting call with its current
// sudo validator, so it's sent as a normal UserOp targeting the account itself.
// Every returned buffer is heap-allocated; free it with aa_free.

/// abi.encode((uint256 x, uint256 y), bytes32 authenticatorIdHash) for a passkey
/// (WebAuthn) validator. Writes exactly 96 bytes into out[0..96].
pub export fn aa_encode_webauthn_enable_data(
    pub_x: ?[*]const u8,
    pub_y: ?[*]const u8,
    authenticator_id_hash: ?[*]const u8,
    out: ?[*]u8,
) callconv(.c) Status {
    if (pub_x == null or pub_y == null or authenticator_id_hash == null or out == null) return .null_out_ptr;
    const x = std.mem.readInt(u256, pub_x.?[0..32], .big);
    const y = std.mem.readInt(u256, pub_y.?[0..32], .big);
    var hash: [32]u8 = undefined;
    @memcpy(&hash, authenticator_id_hash.?[0..32]);
    const enable = webauthn.WebAuthnValidator.encodeEnableData(x, y, hash);
    @memcpy(out.?[0..96], &enable);
    return .ok;
}

/// abi.encode(address[] guardians, uint24[] weights, uint24 threshold, uint48
/// delay) for the weighted-ECDSA validator. guardians is count*20 bytes;
/// weights is count entries. The result is allocated into out/out_len.
pub export fn aa_encode_weighted_enable_data(
    guardians: ?[*]const u8,
    weights: ?[*]const u32,
    count: usize,
    threshold: u32,
    delay: u64,
    out: ?*[*]u8,
    out_len: ?*usize,
) callconv(.c) Status {
    if (out == null or out_len == null) return .null_out_ptr;
    if (guardians == null or weights == null or count == 0) return .encode_failed;

    const allocator = defaultAllocator();
    const set = allocator.alloc(weighted.Guardian, count) catch return .out_of_memory;
    defer allocator.free(set);
    for (0..count) |i| {
        var addr: [20]u8 = undefined;
        @memcpy(&addr, guardians.?[i * 20 .. i * 20 + 20]);
        // The abi fields are narrower than the C ints, so a value that does
        // not fit would silently wrap in ReleaseFast. Reject it instead.
        const weight = std.math.cast(u24, weights.?[i]) orelse {
            setLastError("guardian weight exceeds the uint24 abi field", .{});
            return .encode_failed;
        };
        set[i] = .{ .address = addr, .weight = weight };
    }

    const threshold_u24 = std.math.cast(u24, threshold) orelse {
        setLastError("threshold exceeds the uint24 abi field", .{});
        return .encode_failed;
    };
    const delay_u48 = std.math.cast(u48, delay) orelse {
        setLastError("delay exceeds the uint48 abi field", .{});
        return .encode_failed;
    };
    const data = weighted.WeightedValidator.encodeEnableData(allocator, set, threshold_u24, delay_u48) catch {
        setLastError("failed to encode weighted enable-data", .{});
        return .encode_failed;
    };
    out.?.* = data.ptr;
    out_len.?.* = data.len;
    return .ok;
}

/// Calldata to install `module` as a secondary validator with `validator_data`
/// (its enable-data). Send it to the account as a UserOp.
pub export fn aa_encode_install_validator(
    module: ?[*]const u8,
    validator_data: ?[*]const u8,
    validator_data_len: usize,
    out: ?*[*]u8,
    out_len: ?*usize,
) callconv(.c) Status {
    return encodePluginCall(true, module, validator_data, validator_data_len, out, out_len);
}

/// Calldata to make `module` the account's root (sudo) validator with
/// `validator_data` (its enable-data). Send it to the account as a UserOp.
pub export fn aa_encode_change_root_validator(
    module: ?[*]const u8,
    validator_data: ?[*]const u8,
    validator_data_len: usize,
    out: ?*[*]u8,
    out_len: ?*usize,
) callconv(.c) Status {
    return encodePluginCall(false, module, validator_data, validator_data_len, out, out_len);
}

/// The value guardians approve for a recovery, written into out[0..32]:
/// keccak256(abi.encode(sender, callData, nonce)). `nonce_be` is a 32-byte
/// big-endian uint256. Both guardian kinds approve this exact hash.
pub export fn aa_recovery_hash(
    sender: ?[*]const u8,
    call_data: ?[*]const u8,
    call_data_len: usize,
    nonce_be: ?[*]const u8,
    out: ?[*]u8,
) callconv(.c) Status {
    if (out == null or sender == null or nonce_be == null) return .null_out_ptr;
    var s: [20]u8 = undefined;
    @memcpy(&s, sender.?[0..20]);
    const cd: []const u8 = if (call_data) |p| p[0..call_data_len] else &[_]u8{};
    const nonce = std.mem.readInt(u256, nonce_be.?[0..32], .big);
    const h = plugin.callDataAndNonceHash(defaultAllocator(), s, cd, nonce) catch {
        setLastError("failed to compute recovery hash", .{});
        return .encode_failed;
    };
    @memcpy(out.?[0..32], &h);
    return .ok;
}

/// Calldata for approve(hash, kernel) on the weighted validator, for a smart
/// account guardian to record its approval on chain. Send it to the validator.
pub export fn aa_encode_approve(
    hash: ?[*]const u8,
    kernel: ?[*]const u8,
    out: ?*[*]u8,
    out_len: ?*usize,
) callconv(.c) Status {
    if (out == null or out_len == null or hash == null or kernel == null) return .null_out_ptr;
    var h: [32]u8 = undefined;
    @memcpy(&h, hash.?[0..32]);
    var k: [20]u8 = undefined;
    @memcpy(&k, kernel.?[0..20]);
    const cd = plugin.approveCallData(defaultAllocator(), h, k) catch {
        setLastError("failed to encode approve calldata", .{});
        return .encode_failed;
    };
    out.?.* = cd.ptr;
    out_len.?.* = cd.len;
    return .ok;
}

/// The account's next nonce for a userop validated by `validator` (a secondary
/// validator such as the weighted guardian validator), written into out[0..32]
/// big-endian. This is the nonce the recovery hash binds to. The nonce key is
/// the Kernel v3 encoding: mode 0x00 (default), type 0x01 (secondary), the
/// validator address, then a zero custom key, matching what EntryPoint expects.
pub export fn aa_account_nonce_for_validator(
    account: ?*AccountImpl,
    validator: ?[*]const u8,
    out: ?[*]u8,
) callconv(.c) Status {
    const acc = account orelse return .null_account;
    if (out == null or validator == null) return .null_out_ptr;

    var key_bytes: [24]u8 = [_]u8{0} ** 24;
    key_bytes[1] = 0x01; // secondary validator; mode and custom key stay zero
    @memcpy(key_bytes[2..22], validator.?[0..20]);
    const key: u192 = std.mem.readInt(u192, &key_bytes, .big);

    var arena = std.heap.ArenaAllocator.init(acc.context.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Reads fall back to the bundler URL for callers that predate the split.
    const read_url: []const u8 = if (acc.context.rpc_url.len > 0)
        acc.context.rpc_url
    else if (acc.context.bundler_url.len > 0)
        acc.context.bundler_url
    else
        core.buildRpcUrl(a, acc.context.project_id, acc.context.chain_id) catch {
            setLastError("failed to build read RPC URL", .{});
            return .send_userop_failed;
        };
    var rpc = Client.init(a, read_url) catch {
        setLastError("failed to create read RPC client", .{});
        return .send_userop_failed;
    };
    wireTransport(&rpc, acc.context);

    const nonce = entrypoint_mod.getNonce(&rpc, a, core.ENTRY_POINT_V07, acc.sender_address, key) catch |err| {
        setLastError("getNonce failed: {s}", .{@errorName(err)});
        return .send_userop_failed;
    };
    var buf: [32]u8 = undefined;
    std.mem.writeInt(u256, &buf, nonce, .big);
    @memcpy(out.?[0..32], &buf);
    return .ok;
}

/// Keccak-256 of `data`, written into out[0..32]. Useful for host-side
/// derivations (e.g. a passkey's authenticatorIdHash = keccak256(credentialId)).
pub export fn aa_keccak256(
    data: ?[*]const u8,
    len: usize,
    out: ?[*]u8,
) callconv(.c) Status {
    if (out == null) return .null_out_ptr;
    const bytes: []const u8 = if (data) |p| p[0..len] else &[_]u8{};
    const h = keccak.hashBytes(bytes);
    @memcpy(out.?[0..32], &h);
    return .ok;
}

fn encodePluginCall(
    install: bool,
    module: ?[*]const u8,
    validator_data: ?[*]const u8,
    validator_data_len: usize,
    out: ?*[*]u8,
    out_len: ?*usize,
) Status {
    if (out == null or out_len == null) return .null_out_ptr;
    if (module == null) return .null_out_ptr;

    const allocator = defaultAllocator();
    var mod: [20]u8 = undefined;
    @memcpy(&mod, module.?[0..20]);
    const vdata: []const u8 = if (validator_data) |p| p[0..validator_data_len] else &[_]u8{};

    const cd = (if (install)
        plugin.installValidatorCallData(allocator, mod, vdata)
    else
        plugin.changeRootValidatorCallData(allocator, mod, vdata)) catch {
        setLastError("failed to encode plugin calldata", .{});
        return .encode_failed;
    };
    out.?.* = cd.ptr;
    out_len.?.* = cd.len;
    return .ok;
}

// ---- Tests (offline; exercise the address-pinning branch of aa_account_create) ----

const testing = std.testing;

fn testCreateCtxAndSigner() struct { ctx: *ContextImpl, signer: *SignerImpl } {
    var ctx_out: ?*ContextImpl = null;
    _ = aa_context_create("proj", "", "", 11155111, &ctx_out);

    // Deterministic key so the CREATE2 derivation is reproducible below.
    var pk: [32]u8 = undefined;
    for (&pk, 0..) |*b, i| b.* = @intCast(i + 1);
    var signer_out: ?*SignerImpl = null;
    _ = aa_signer_local(&pk, &signer_out);

    return .{ .ctx = ctx_out.?, .signer = signer_out.? };
}

test "aa_account_create: nil address → counterfactual CREATE2 derivation" {
    const env = testCreateCtxAndSigner();
    defer _ = aa_context_destroy(env.ctx);
    defer aa_signer_destroy(env.signer);

    var acc: ?*AccountImpl = null;
    const status = aa_account_create(env.ctx, env.signer, 0, 0, null, &acc);
    try testing.expectEqual(Status.ok, status);
    defer _ = aa_account_destroy(acc);

    // sender_address must equal the CREATE2-derived address for this signer.
    const expected = try create2.getKernelAddress(acc.?.owner_address, 0, .v3_3);
    try testing.expectEqualSlices(u8, &expected.bytes, &acc.?.sender_address.bytes);
}

test "aa_account_create: non-nil address → sender = passed bytes" {
    const env = testCreateCtxAndSigner();
    defer _ = aa_context_destroy(env.ctx);
    defer aa_signer_destroy(env.signer);

    // Legacy address the caller wants to keep operating under a new kernel version.
    const pinned_bytes = [_]u8{
        0xde, 0xad, 0xbe, 0xef, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05,
        0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    };

    var acc: ?*AccountImpl = null;
    const status = aa_account_create(env.ctx, env.signer, 0, 0, &pinned_bytes, &acc);
    try testing.expectEqual(Status.ok, status);
    defer _ = aa_account_destroy(acc);

    try testing.expectEqualSlices(u8, &pinned_bytes, &acc.?.sender_address.bytes);

    // aa_account_get_address must return the pinned address, not counterfactual.
    var addr_out: [20]u8 = undefined;
    try testing.expectEqual(Status.ok, aa_account_get_address(acc, &addr_out));
    try testing.expectEqualSlices(u8, &pinned_bytes, &addr_out);

    // Counterfactual for this signer must differ — confirms we're actually
    // using the pinned bytes and not silently ignoring them.
    const counterfactual = try create2.getKernelAddress(acc.?.owner_address, 0, .v3_3);
    try testing.expect(!std.mem.eql(u8, &counterfactual.bytes, &pinned_bytes));
}
