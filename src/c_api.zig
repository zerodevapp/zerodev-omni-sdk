//! C FFI exports for the ZeroDev Omni SDK.
//!
//! Provides opaque-handle-based API for creating Kernel v3 accounts,
//! building/signing/sending UserOperations from any language with C FFI.

const std = @import("std");
const builtin = @import("builtin");
const zigeth = @import("zigeth");

const Address = zigeth.primitives.Address;
const Hash = zigeth.primitives.Hash;
const keccak = zigeth.crypto.keccak;

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
    const copy_len = @min(msg.len, last_error_buf.len);
    @memcpy(last_error_buf[0..copy_len], msg[0..copy_len]);
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

/// Result from paymaster middleware. paymaster_data is allocated by the
/// middleware and freed by the caller via the context allocator.
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

// ---- Context ----

pub const ContextImpl = struct {
    allocator: std.mem.Allocator,
    project_id: []u8,
    rpc_url: []u8,
    bundler_url: []u8,
    chain_id: u64,
    gas_middleware: ?GasPriceFn,
    paymaster_middleware: ?PaymasterFn,
    http_fn: ?transport.HttpFn = null,
    http_ctx: ?*anyopaque = null,
};

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

    // Resolve RPC URL
    const rpc_url: []const u8 = if (c.bundler_url.len > 0)
        c.bundler_url
    else blk: {
        const url = core.buildRpcUrl(allocator, c.project_id, c.chain_id) catch {
            setLastError("failed to build RPC URL for gas price", .{});
            return .send_userop_failed;
        };
        break :blk url;
    };
    const url_allocated = c.bundler_url.len == 0;
    defer if (url_allocated) allocator.free(@constCast(rpc_url));

    var rpc = Client.init(allocator, rpc_url) catch {
        setLastError("failed to create RPC client for gas price", .{});
        return .send_userop_failed;
    };
    rpc.http_fn = c.http_fn;
    rpc.http_ctx = c.http_ctx;
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
    rpc.http_fn = c.http_fn;
    rpc.http_ctx = c.http_ctx;
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
    std.crypto.random.bytes(&pk);

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

pub export fn aa_signer_destroy(signer: ?*SignerImpl) callconv(.c) void {
    const s = signer orelse return;
    if (s.kind == .json_rpc) {
        var rpc = &s.kind.json_rpc;
        rpc.deinit();
    }
    s.allocator.destroy(s);
}

// ---- Account ----

pub const AccountImpl = struct {
    context: *ContextImpl,
    signer: *SignerImpl,
    ecdsa: EcdsaValidator,
    kernel_version: KernelVersion,
    index: u32,
    owner_address: Address,
    sender_address: Address,

    pub fn getValidator(self: *AccountImpl) Validator {
        return self.ecdsa.validator();
    }
};

pub export fn aa_account_create(
    ctx: ?*ContextImpl,
    signer: ?*SignerImpl,
    version: c_int,
    index: u32,
    out: ?*?*AccountImpl,
) callconv(.c) Status {
    if (out == null) return .null_out_ptr;
    const c = ctx orelse return .null_context;
    const s = signer orelse return .invalid_signer;

    const allocator = c.allocator;

    const kv = KernelVersion.fromInt(@intCast(version)) orelse {
        setLastError("invalid kernel version: {d}", .{version});
        return .invalid_kernel_version;
    };

    // Signer is already heap-allocated — vtable pointer is stable
    const owner_addr = Address.fromBytes(s.getSigner().getAddress());
    const sender_addr = create2.getKernelAddress(owner_addr, @as(u256, index), kv) catch {
        setLastError("failed to compute kernel address", .{});
        return .get_address_failed;
    };

    const impl = allocator.create(AccountImpl) catch {
        return .out_of_memory;
    };
    impl.* = .{
        .context = c,
        .signer = s,
        .ecdsa = EcdsaValidator.init(s.getSigner()),
        .kernel_version = kv,
        .index = index,
        .owner_address = owner_addr,
        .sender_address = sender_addr,
    };

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
};

pub const CCall = extern struct {
    target: [20]u8,
    value_be: [32]u8,
    calldata: ?[*]const u8,
    calldata_len: usize,
};

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

    // Build factory data for account deployment
    const factory_data = create2.buildFactoryCalldata(
        a,
        acc.owner_address,
        @as(u256, acc.index),
        acc.kernel_version,
    ) catch {
        setLastError("failed to build factory calldata", .{});
        return .build_userop_failed;
    };

    // Build init_code = meta_factory_address ++ factory_data
    const meta_factory = Address.fromHex(core.META_FACTORY) catch {
        return .build_userop_failed;
    };
    var init_code = a.alloc(u8, 20 + factory_data.len) catch {
        return .out_of_memory;
    };
    @memcpy(init_code[0..20], &meta_factory.bytes);
    @memcpy(init_code[20..], factory_data);

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
    const sig = val.signUserOp(hash.bytes) catch {
        setLastError("ECDSA signing failed", .{});
        return .sign_userop_failed;
    };

    // Store signature in the arena
    const a = userop.arena.allocator();
    const sig_copy = a.alloc(u8, 65) catch {
        return .out_of_memory;
    };
    @memcpy(sig_copy, &sig);
    userop.signature = sig_copy;

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

    // Build JSON string manually
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    const writer = buf.writer(allocator);

    const sender_hex = userop.sender.toHex(allocator) catch return .serialize_failed;
    defer allocator.free(sender_hex);

    const init_code_hex = zigeth.utils.hex.bytesToHex(allocator, userop.init_code) catch return .serialize_failed;
    defer allocator.free(init_code_hex);

    const call_data_hex = zigeth.utils.hex.bytesToHex(allocator, userop.call_data) catch return .serialize_failed;
    defer allocator.free(call_data_hex);

    const sig_hex = zigeth.utils.hex.bytesToHex(allocator, userop.signature) catch return .serialize_failed;
    defer allocator.free(sig_hex);

    const pm_hex = zigeth.utils.hex.bytesToHex(allocator, userop.paymaster_and_data) catch return .serialize_failed;
    defer allocator.free(pm_hex);

    writer.print(
        \\{{"sender":"{s}","nonce":"0x{x}","initCode":"{s}","callData":"{s}",
    , .{ sender_hex, userop.nonce, init_code_hex, call_data_hex }) catch return .serialize_failed;

    writer.print(
        \\"callGasLimit":"0x{x}","verificationGasLimit":"0x{x}","preVerificationGas":"0x{x}",
    , .{ userop.call_gas_limit, userop.verification_gas_limit, userop.pre_verification_gas }) catch return .serialize_failed;

    writer.print(
        \\"maxFeePerGas":"0x{x}","maxPriorityFeePerGas":"0x{x}",
    , .{ userop.max_fee_per_gas, userop.max_priority_fee_per_gas }) catch return .serialize_failed;

    writer.print(
        \\"paymasterAndData":"{s}","signature":"{s}"}}
    , .{ pm_hex, sig_hex }) catch return .serialize_failed;

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
    const pm_data = zigeth.utils.hex.hexToBytes(userop.arena.allocator(), pm_data_val.string) catch return .apply_json_failed;

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
    // Null-terminate
    if (last_error_len < last_error_buf.len) {
        last_error_buf[last_error_len] = 0;
    }
    return @ptrCast(&last_error_buf);
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

    // Resolve RPC URL: use bundler_url if set, else derive from project_id + chain_id
    const rpc_url: []const u8 = if (acc.context.bundler_url.len > 0)
        acc.context.bundler_url
    else
        core.buildRpcUrl(a, acc.context.project_id, acc.context.chain_id) catch {
            setLastError("failed to build RPC URL from project_id", .{});
            return .send_userop_failed;
        };

    var rpc = Client.init(a, rpc_url) catch {
        setLastError("failed to create RPC client", .{});
        return .send_userop_failed;
    };
    rpc.http_fn = acc.context.http_fn;
    rpc.http_ctx = acc.context.http_ctx;

    const chain_id = acc.context.chain_id;
    const entry_point = Address.fromHex(core.ENTRY_POINT_V07) catch return .send_userop_failed;

    // Step 1: Get nonce
    const nonce = entrypoint_mod.getNonce(&rpc, a, core.ENTRY_POINT_V07, acc.sender_address, 0) catch |err| {
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

    // Step 3: Build init_code if nonce == 0 (account not yet deployed)
    var init_code: []u8 = &[_]u8{};
    if (nonce == 0) {
        const factory_data = create2.buildFactoryCalldata(a, acc.owner_address, @as(u256, acc.index), acc.kernel_version) catch {
            setLastError("failed to build factory calldata", .{});
            return .build_userop_failed;
        };
        const meta_factory = Address.fromHex(core.META_FACTORY) catch return .build_userop_failed;
        init_code = a.alloc(u8, 20 + factory_data.len) catch return .out_of_memory;
        @memcpy(init_code[0..20], &meta_factory.bytes);
        @memcpy(init_code[20..], factory_data);
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
    };

    var val = acc.getValidator();

    // Paymaster middleware is optional — if not set, send unsponsored (user pays gas)
    const pm_mw = acc.context.paymaster_middleware;

    // Helper: sign UserOp, serialize to JSON string, call paymaster middleware
    const ep_hex: [*:0]const u8 = core.ENTRY_POINT_V07;

    // Step 6: Paymaster stub (before gas estimation) — skip if no paymaster
    if (pm_mw) |mw| {
        const stub_hash = user_op.computeHash(entry_point, @as(u256, chain_id));
        const stub_sig = val.signUserOp(stub_hash.bytes) catch {
            setLastError("signing for paymaster stub failed", .{});
            return .sign_userop_failed;
        };
        const stub_json_val = user_op.toJsonValue(a, &stub_sig) catch return .serialize_failed;
        const stub_json_str = std.json.Stringify.valueAlloc(a, stub_json_val, .{}) catch return .serialize_failed;

        var pm_result: PaymasterResult = undefined;
        const pm_status = mw(acc.context, stub_json_str.ptr, stub_json_str.len, ep_hex, chain_id, .stub, &pm_result);
        if (pm_status != .ok) return pm_status;
        defer if (pm_result.paymaster_data) |p| allocator.free(p[0..pm_result.paymaster_data_len]);

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
        const est_sig = val.signUserOp(est_hash.bytes) catch {
            setLastError("signing for gas estimation failed", .{});
            return .sign_userop_failed;
        };
        const est_json = user_op.toJsonValue(a, &est_sig) catch return .serialize_failed;

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
        const final_sig = val.signUserOp(final_hash.bytes) catch {
            setLastError("signing for final paymaster failed", .{});
            return .sign_userop_failed;
        };
        const final_json_val = user_op.toJsonValue(a, &final_sig) catch return .serialize_failed;
        const final_json_str = std.json.Stringify.valueAlloc(a, final_json_val, .{}) catch return .serialize_failed;

        var pm_result: PaymasterResult = undefined;
        const pm_status = mw(acc.context, final_json_str.ptr, final_json_str.len, ep_hex, chain_id, .final, &pm_result);
        if (pm_status != .ok) return pm_status;
        defer if (pm_result.paymaster_data) |p| allocator.free(p[0..pm_result.paymaster_data_len]);

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
    const real_sig = val.signUserOp(op_hash.bytes) catch {
        setLastError("final ECDSA signing failed", .{});
        return .sign_userop_failed;
    };

    // Step 11: Send
    const send_json = user_op.toJsonValue(a, &real_sig) catch {
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
    rpc.http_fn = acc.context.http_fn;
    rpc.http_ctx = acc.context.http_ctx;
    defer rpc.deinit();

    // Build RPC params: [userOpHash]
    var params_arr = std.json.Array.init(allocator);
    defer params_arr.deinit();
    params_arr.append(.{ .string = &hash_hex_buf }) catch {
        setLastError("failed to build RPC params", .{});
        return .receipt_failed;
    };

    // Poll loop
    var elapsed: u64 = 0;
    while (elapsed < timeout) {
        const result = rpc.call("eth_getUserOperationReceipt", .{ .array = params_arr }) catch |err| {
            if (err == error.JsonRpcError) {
                // Not found yet, keep polling
                std.Thread.sleep(interval * std.time.ns_per_ms);
                elapsed += interval;
                continue;
            }
            setLastError("eth_getUserOperationReceipt failed: {s}", .{@errorName(err)});
            return .receipt_failed;
        };

        if (result == .null) {
            transport.freeValue(allocator, result);
            std.Thread.sleep(interval * std.time.ns_per_ms);
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
