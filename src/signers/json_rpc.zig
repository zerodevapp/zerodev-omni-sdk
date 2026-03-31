//! JSON-RPC Signer — signs via remote eth_sign / personal_sign endpoint.
//!
//! For Privy embedded wallets, custodial services, or any signer accessible
//! over JSON-RPC. The Zig layer handles the HTTP call so host languages
//! just pass a URL.

const std = @import("std");
const signer_mod = @import("signer.zig");
const Signer = signer_mod.Signer;
const Signature = signer_mod.Signature;
const SignerError = signer_mod.SignerError;
const transport = @import("transport");
const Client = transport.Client;

pub const JsonRpcSigner = struct {
    allocator: std.mem.Allocator,
    rpc_url: []const u8,
    address: [20]u8,

    pub fn init(allocator: std.mem.Allocator, rpc_url: []const u8, address: [20]u8) !JsonRpcSigner {
        return .{
            .allocator = allocator,
            .rpc_url = try allocator.dupe(u8, rpc_url),
            .address = address,
        };
    }

    pub fn deinit(self: *JsonRpcSigner) void {
        self.allocator.free(self.rpc_url);
    }

    pub fn signer(self: *JsonRpcSigner) Signer {
        return .{
            .ptr = @ptrCast(self),
            .getAddressFn = getAddressImpl,
            .signHashFn = signHashImpl,
            .signMessageFn = signMessageImpl,
            .signTypedDataHashFn = signHashImpl,
        };
    }

    fn getAddressImpl(ptr: *anyopaque) [20]u8 {
        const self: *JsonRpcSigner = @ptrCast(@alignCast(ptr));
        return self.address;
    }

    /// Signs via eth_sign(address, hash) JSON-RPC call.
    fn signHashImpl(ptr: *anyopaque, hash: [32]u8) SignerError!Signature {
        const self: *JsonRpcSigner = @ptrCast(@alignCast(ptr));
        return self.rpcSign("eth_sign", &hash) catch return SignerError.RpcError;
    }

    /// Signs via personal_sign(message_hex, address) JSON-RPC call.
    fn signMessageImpl(ptr: *anyopaque, message: []const u8) SignerError!Signature {
        const self: *JsonRpcSigner = @ptrCast(@alignCast(ptr));
        return self.rpcSign("personal_sign", message) catch return SignerError.RpcError;
    }

    fn rpcSign(self: *JsonRpcSigner, method: []const u8, data: []const u8) !Signature {
        var rpc = try Client.init(self.allocator, self.rpc_url);
        defer rpc.deinit();

        // Format address as 0x hex
        var addr_hex: [42]u8 = undefined;
        addr_hex[0] = '0';
        addr_hex[1] = 'x';
        const hex_chars = "0123456789abcdef";
        for (0..20) |i| {
            addr_hex[2 + i * 2] = hex_chars[self.address[i] >> 4];
            addr_hex[2 + i * 2 + 1] = hex_chars[self.address[i] & 0x0f];
        }

        // Format data as 0x hex
        const data_hex = try self.allocator.alloc(u8, 2 + data.len * 2);
        defer self.allocator.free(data_hex);
        data_hex[0] = '0';
        data_hex[1] = 'x';
        for (0..data.len) |i| {
            data_hex[2 + i * 2] = hex_chars[data[i] >> 4];
            data_hex[2 + i * 2 + 1] = hex_chars[data[i] & 0x0f];
        }

        // Build params array — order depends on method
        var params: [2]std.json.Value = undefined;
        if (std.mem.eql(u8, method, "personal_sign")) {
            // personal_sign(data, address)
            params = .{ .{ .string = data_hex }, .{ .string = &addr_hex } };
        } else {
            // eth_sign(address, data)
            params = .{ .{ .string = &addr_hex }, .{ .string = data_hex } };
        }

        const result = try rpc.callWithParams(method, &params);
        defer transport.freeValue(self.allocator, result);

        if (result != .string) return error.InvalidResponse;
        return parseHexSignature(result.string);
    }

    fn parseHexSignature(hex: []const u8) !Signature {
        var offset: usize = 0;
        if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) {
            offset = 2;
        }
        if (hex.len - offset < 130) return error.InvalidSignature;

        var sig: Signature = undefined;
        for (0..32) |i| {
            sig.r[i] = hexByte(hex[offset + i * 2], hex[offset + i * 2 + 1]) orelse
                return error.InvalidSignature;
        }
        offset += 64;
        for (0..32) |i| {
            sig.s[i] = hexByte(hex[offset + i * 2], hex[offset + i * 2 + 1]) orelse
                return error.InvalidSignature;
        }
        offset += 64;
        sig.v = hexByte(hex[offset], hex[offset + 1]) orelse
            return error.InvalidSignature;

        return sig;
    }

    fn hexByte(high: u8, low: u8) ?u8 {
        const h = hexVal(high) orelse return null;
        const l = hexVal(low) orelse return null;
        return (h << 4) | l;
    }

    fn hexVal(c: u8) ?u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => null,
        };
    }
};
