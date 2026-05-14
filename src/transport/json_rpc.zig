//! Minimal JSON-RPC client built on top of our fixed HTTP transport.

const std = @import("std");
const primitives = @import("primitives");
const http_post = @import("http.zig").post;

const Address = primitives.Address;

/// Parse a hex string (with optional 0x prefix) into an integer of any width.
pub fn parseHex(comptime T: type, hex: []const u8) !T {
    const stripped = if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X'))
        hex[2..]
    else
        hex;
    if (stripped.len == 0) return 0;

    const max_digits = @typeInfo(T).int.bits / 4;
    if (stripped.len > max_digits) return error.Overflow;

    var result: T = 0;
    for (stripped) |c| {
        const digit: T = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.InvalidCharacter,
        };
        result = (result << 4) | digit;
    }
    return result;
}

/// Recursively free a deep-copied std.json.Value and all its owned memory.
pub fn freeValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .null, .bool, .integer, .float => {},
        .number_string => |ns| allocator.free(ns),
        .string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| freeValue(allocator, item);
            var a = arr;
            a.deinit();
        },
        .object => |obj| {
            var o = obj;
            var it = o.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeValue(allocator, entry.value_ptr.*);
            }
            // ObjectMap is unmanaged in Zig 0.16 — deinit takes the allocator.
            o.deinit(allocator);
        },
    }
}

/// C-compatible HTTP transport callback.
/// Host implements: POST url with body, return response.
///
/// **Allocator contract (audit F-02):** the response buffer MUST be either
///   (a) allocated via `aa_alloc` (or equivalently, libc `malloc`), in which
///       case the SDK frees it via libc `free`, or
///   (b) allocated with any other allocator (Go runtime, Rust global,
///       Python, etc.), in which case the host MUST register a matching
///       `HttpFreeFn` via `aa_context_set_http_free_fn`.
///
/// Mixing — handing back a Go/Rust pointer with no free fn registered — is
/// undefined behavior; on macOS libsystem_malloc aborts the process.
pub const HttpFn = *const fn (
    ?*anyopaque, // user context
    [*]const u8, // url (null-terminated)
    [*]const u8, // body
    usize, // body_len
    *[*]u8, // response_out
    *usize, // response_len_out
) callconv(.c) c_int;

/// Optional free callback paired with `HttpFn`. If set, the SDK calls this
/// to release the response buffer instead of libc `free`. Receives the same
/// user context the transport was registered with.
pub const HttpFreeFn = *const fn (
    ?*anyopaque, // user context
    [*]u8, // response ptr (as returned from HttpFn)
    usize, // response len
) callconv(.c) void;

pub const Client = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    next_id: u64,
    http_fn: ?HttpFn = null,
    http_ctx: ?*anyopaque = null,
    http_free_fn: ?HttpFreeFn = null,

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) !Client {
        return .{
            .allocator = allocator,
            .endpoint = try allocator.dupe(u8, endpoint),
            .next_id = 1,
        };
    }

    pub fn deinit(self: Client) void {
        self.allocator.free(self.endpoint);
    }

    pub fn call(self: *Client, method: []const u8, params: std.json.Value) !std.json.Value {
        const id = self.next_id;
        self.next_id += 1;

        var obj: std.json.ObjectMap = .empty;
        defer obj.deinit(self.allocator);
        try obj.put(self.allocator, "jsonrpc", .{ .string = "2.0" });
        try obj.put(self.allocator, "method", .{ .string = method });
        try obj.put(self.allocator, "params", params);
        try obj.put(self.allocator, "id", .{ .integer = @intCast(id) });

        const request_json = try std.json.Stringify.valueAlloc(self.allocator, std.json.Value{ .object = obj }, .{});
        defer self.allocator.free(request_json);

        const body = if (self.http_fn) |f| blk: {
            // Use host-provided transport (URLSession, OkHttp, etc.)
            var resp_ptr: [*]u8 = undefined;
            var resp_len: usize = 0;

            // Null-terminate the endpoint for C
            const url_z = try self.allocator.dupeZ(u8, self.endpoint);
            defer self.allocator.free(url_z);

            const status = f(self.http_ctx, url_z.ptr, request_json.ptr, request_json.len, &resp_ptr, &resp_len);
            if (status != 0) return error.HttpTransportFailed;

            // Copy response to our allocator, then hand the host's buffer
            // back to its own free function. Falls back to libc free when no
            // free callback is registered — see the HttpFn allocator contract.
            const owned = try self.allocator.dupe(u8, resp_ptr[0..resp_len]);
            if (self.http_free_fn) |free_fn| {
                free_fn(self.http_ctx, resp_ptr, resp_len);
            } else {
                std.c.free(resp_ptr);
            }
            break :blk owned;
        } else try http_post(self.allocator, self.endpoint, request_json);
        defer self.allocator.free(body);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidJsonRpcResponse;
        const rpc = parsed.value.object;

        if (rpc.get("error")) |err_val| {
            if (err_val != .null) {
                if (err_val == .object) {
                    if (err_val.object.get("message")) |msg| {
                        if (msg == .string) {
                            std.log.warn("JSON-RPC error ({s}): {s}", .{ method, msg.string });
                        }
                    }
                }
                return error.JsonRpcError;
            }
        }

        const result = rpc.get("result") orelse return error.MissingResult;
        return try deepCopy(self.allocator, result);
    }

    pub fn callWithParams(self: *Client, method: []const u8, params: []const std.json.Value) !std.json.Value {
        var arr = std.json.Array.init(self.allocator);
        defer arr.deinit();
        for (params) |p| try arr.append(p);
        return try self.call(method, .{ .array = arr });
    }

    pub fn getChainId(self: *Client) !u64 {
        const result = try self.callWithParams("eth_chainId", &[_]std.json.Value{});
        defer freeValue(self.allocator, result);
        if (result != .string) return error.InvalidResponse;
        return parseHex(u64, result.string);
    }

    pub fn getCode(self: *Client, address: Address) ![]u8 {
        const addr_hex = try address.toHex(self.allocator);
        defer self.allocator.free(addr_hex);
        var p = [_]std.json.Value{ .{ .string = addr_hex }, .{ .string = "latest" } };
        const result = try self.callWithParams("eth_getCode", &p);
        if (result != .string) {
            freeValue(self.allocator, result);
            return error.InvalidResponse;
        }
        defer self.allocator.free(result.string);
        return try primitives.hexToBytes(self.allocator, result.string);
    }

    pub fn getBalance(self: *Client, address: Address) !u256 {
        const addr_hex = try address.toHex(self.allocator);
        defer self.allocator.free(addr_hex);
        var p = [_]std.json.Value{ .{ .string = addr_hex }, .{ .string = "latest" } };
        const result = try self.callWithParams("eth_getBalance", &p);
        defer freeValue(self.allocator, result);
        if (result != .string) return error.InvalidResponse;
        return try parseHex(u256, result.string);
    }

    pub fn getTransactionCount(self: *Client, address: Address) !u64 {
        return self.getTransactionCountAt(address, "latest");
    }

    pub fn getTransactionCountAt(self: *Client, address: Address, block_tag: []const u8) !u64 {
        const addr_hex = try address.toHex(self.allocator);
        defer self.allocator.free(addr_hex);
        var p = [_]std.json.Value{ .{ .string = addr_hex }, .{ .string = block_tag } };
        const result = try self.callWithParams("eth_getTransactionCount", &p);
        defer freeValue(self.allocator, result);
        if (result != .string) return error.InvalidResponse;
        return parseHex(u64, result.string);
    }
};

// ---- Audit F-02 tripwire: host-side free callback is invoked instead of
// std.c.free when http_free_fn is registered. Allocates the response with a
// non-libc allocator (Zig's std heap) — under the old contract this would
// SIGABRT on macOS when the SDK tried to libc-free a Zig-allocator pointer.

const testing = std.testing;

const HostState = struct {
    allocator: std.mem.Allocator,
    free_calls: usize = 0,
    response_body: []const u8,
};

fn testHostHttp(
    ctx: ?*anyopaque,
    _: [*]const u8,
    _: [*]const u8,
    _: usize,
    resp_out: *[*]u8,
    resp_len_out: *usize,
) callconv(.c) c_int {
    const state: *HostState = @ptrCast(@alignCast(ctx.?));
    const buf = state.allocator.dupe(u8, state.response_body) catch return 1;
    resp_out.* = buf.ptr;
    resp_len_out.* = buf.len;
    return 0;
}

fn testHostFree(
    ctx: ?*anyopaque,
    ptr: [*]u8,
    len: usize,
) callconv(.c) void {
    const state: *HostState = @ptrCast(@alignCast(ctx.?));
    state.free_calls += 1;
    state.allocator.free(ptr[0..len]);
}

test "http_free_fn is invoked for host-allocated response (audit F-02)" {
    var state = HostState{
        .allocator = testing.allocator,
        .response_body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"0x1\"}",
    };

    var client = try Client.init(testing.allocator, "http://test.invalid");
    defer client.deinit();
    client.http_fn = testHostHttp;
    client.http_ctx = &state;
    client.http_free_fn = testHostFree;

    const result = try client.callWithParams("eth_chainId", &[_]std.json.Value{});
    defer freeValue(testing.allocator, result);

    try testing.expectEqual(@as(usize, 1), state.free_calls);
    try testing.expect(result == .string);
    try testing.expectEqualStrings("0x1", result.string);
}

fn deepCopy(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |ns| .{ .number_string = try allocator.dupe(u8, ns) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var a = std.json.Array.init(allocator);
            for (arr.items) |item| try a.append(try deepCopy(allocator, item));
            break :blk .{ .array = a };
        },
        .object => |obj| blk: {
            var o: std.json.ObjectMap = .empty;
            var it = obj.iterator();
            while (it.next()) |entry| {
                try o.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try deepCopy(allocator, entry.value_ptr.*));
            }
            break :blk .{ .object = o };
        },
    };
}
