//! Minimal JSON-RPC client built on top of our fixed HTTP transport.

const std = @import("std");
const zigeth = @import("zigeth");
const http_post = @import("http.zig").post;

const Address = zigeth.primitives.Address;

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
            o.deinit();
        },
    }
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    next_id: u64,

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

        var obj = std.json.ObjectMap.init(self.allocator);
        defer obj.deinit();
        try obj.put("jsonrpc", .{ .string = "2.0" });
        try obj.put("method", .{ .string = method });
        try obj.put("params", params);
        try obj.put("id", .{ .integer = @intCast(id) });

        const request_json = try std.json.Stringify.valueAlloc(self.allocator, std.json.Value{ .object = obj }, .{});
        defer self.allocator.free(request_json);

        const body = try http_post(self.allocator, self.endpoint, request_json);
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
        return try zigeth.utils.hex.hexToBytes(self.allocator, result.string);
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
        const addr_hex = try address.toHex(self.allocator);
        defer self.allocator.free(addr_hex);
        var p = [_]std.json.Value{ .{ .string = addr_hex }, .{ .string = "latest" } };
        const result = try self.callWithParams("eth_getTransactionCount", &p);
        defer freeValue(self.allocator, result);
        if (result != .string) return error.InvalidResponse;
        return parseHex(u64, result.string);
    }
};

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
            var o = std.json.ObjectMap.init(allocator);
            var it = obj.iterator();
            while (it.next()) |entry| {
                try o.put(try allocator.dupe(u8, entry.key_ptr.*), try deepCopy(allocator, entry.value_ptr.*));
            }
            break :blk .{ .object = o };
        },
    };
}
