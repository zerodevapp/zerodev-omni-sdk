//! Kernel v3 calldata encoding for ERC-7579 execute.
//!
//! Kernel v3 uses `execute(bytes32 execMode, bytes executionCalldata)`.
//!   - Single call: execMode = 0x00..00, executionCalldata = packed(target ++ value ++ data)
//!   - Batch call: execMode = 0x01..00, executionCalldata = abi.encode(Execution[])

const std = @import("std");
const primitives = @import("primitives");

const Address = primitives.Address;

pub const Execution = struct {
    to: Address,
    value: u256,
    data: []const u8,
};

const EXECUTE_SELECTOR = [4]u8{ 0xe9, 0xae, 0x5c, 0x53 };

const EXEC_MODE_SINGLE: [32]u8 = [_]u8{0} ** 32;
const EXEC_MODE_BATCH: [32]u8 = [_]u8{0x01} ++ [_]u8{0} ** 31;

pub fn encodeExecute(allocator: std.mem.Allocator, exec: Execution) ![]u8 {
    // Checked sizing: `exec.data.len` arrives from the host over the C API, so
    // a hostile length must fail here rather than wrap and undersize `buf`.
    const inner_len = try std.math.add(usize, 20 + 32, exec.data.len);
    const padded_inner = try paddedLen(inner_len);
    const total = try std.math.add(usize, 4 + 32 + 32 + 32, padded_inner);
    const buf = try allocator.alloc(u8, total);
    @memset(buf, 0);

    var pos: usize = 0;
    @memcpy(buf[pos .. pos + 4], &EXECUTE_SELECTOR);
    pos += 4;
    @memcpy(buf[pos .. pos + 32], &EXEC_MODE_SINGLE);
    pos += 32;
    writeU256(buf[pos..][0..32], 0x40);
    pos += 32;
    writeU256(buf[pos..][0..32], @intCast(inner_len));
    pos += 32;
    @memcpy(buf[pos .. pos + 20], &exec.to.bytes);
    pos += 20;
    const val_be: [32]u8 = @bitCast(@byteSwap(exec.value));
    @memcpy(buf[pos .. pos + 32], &val_be);
    pos += 32;
    if (exec.data.len > 0) {
        @memcpy(buf[pos .. pos + exec.data.len], exec.data);
    }
    return buf;
}

pub fn encodeExecuteBatch(allocator: std.mem.Allocator, execs: []const Execution) ![]u8 {
    const n = execs.len;
    // Checked sizing throughout: every `data.len` is host-supplied.
    const n_words = try std.math.mul(usize, n, 32);
    var inner_abi_len: usize = try std.math.add(usize, 32 + 32, n_words);
    for (execs) |exec| {
        inner_abi_len = try std.math.add(usize, inner_abi_len, try tupleSize(exec.data.len));
    }
    const padded_inner = try paddedLen(inner_abi_len);
    const total = try std.math.add(usize, 4 + 32 + 32 + 32, padded_inner);
    const buf = try allocator.alloc(u8, total);
    @memset(buf, 0);

    var pos: usize = 0;
    @memcpy(buf[pos .. pos + 4], &EXECUTE_SELECTOR);
    pos += 4;
    @memcpy(buf[pos .. pos + 32], &EXEC_MODE_BATCH);
    pos += 32;
    writeU256(buf[pos..][0..32], 0x40);
    pos += 32;
    writeU256(buf[pos..][0..32], @intCast(inner_abi_len));
    pos += 32;
    writeU256(buf[pos..][0..32], 0x20);
    pos += 32;
    writeU256(buf[pos..][0..32], @intCast(n));
    pos += 32;

    var tuple_offset: usize = n_words;
    for (execs) |exec| {
        writeU256(buf[pos..][0..32], @intCast(tuple_offset));
        pos += 32;
        // Cannot fail: validated in the sizing pass above.
        tuple_offset += try tupleSize(exec.data.len);
    }

    for (execs) |exec| {
        @memcpy(buf[pos + 12 .. pos + 32], &exec.to.bytes);
        pos += 32;
        writeU256(buf[pos..][0..32], exec.value);
        pos += 32;
        writeU256(buf[pos..][0..32], 0x60);
        pos += 32;
        writeU256(buf[pos..][0..32], @intCast(exec.data.len));
        pos += 32;
        if (exec.data.len > 0) {
            @memcpy(buf[pos .. pos + exec.data.len], exec.data);
            // Cannot fail: validated in the sizing pass above.
            pos += try paddedLen(exec.data.len);
        }
    }
    return buf;
}

/// Size of one (address, uint256, bytes) tuple in the batch encoding: four
/// 32-byte words plus the padded data. Checked, since `data_len` is host-supplied.
fn tupleSize(data_len: usize) error{Overflow}!usize {
    return std.math.add(usize, 128, try paddedLen(data_len));
}

/// Round up to a 32-byte boundary. Checked: `len + 31` wraps for `len` within
/// 31 of `usize.max`, which would undersize the output buffer for the memcpy.
fn paddedLen(len: usize) error{Overflow}!usize {
    if (len == 0) return 0;
    const rounded = try std.math.add(usize, len, 31);
    return (rounded / 32) * 32;
}

fn writeU256(dest: *[32]u8, val: u256) void {
    dest.* = @bitCast(@byteSwap(val));
}

// Tests

// Hostile lengths arrive over the C API. These slices are never dereferenced —
// sizing must reject them before any allocation or copy.
test "encodeExecute rejects data lengths that overflow sizing" {
    const allocator = std.testing.allocator;
    const to = try Address.fromHex("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045");
    const max = std.math.maxInt(usize);
    var hostile: []const u8 = &[_]u8{};

    hostile.len = max; // inner_len add overflows
    try std.testing.expectError(error.Overflow, encodeExecute(allocator, .{ .to = to, .value = 0, .data = hostile }));

    hostile.len = max - 60; // inner_len fits; paddedLen's +31 overflows
    try std.testing.expectError(error.Overflow, encodeExecute(allocator, .{ .to = to, .value = 0, .data = hostile }));
}

test "encodeExecuteBatch rejects data lengths that overflow sizing" {
    const allocator = std.testing.allocator;
    const to = try Address.fromHex("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045");
    var hostile: []const u8 = &[_]u8{};

    // paddedLen survives at exactly max-31; the 128-byte tuple header add does not.
    hostile.len = std.math.maxInt(usize) - 31;
    const execs = [_]Execution{.{ .to = to, .value = 0, .data = hostile }};
    try std.testing.expectError(error.Overflow, encodeExecuteBatch(allocator, &execs));
}

test "encodeExecute correct selector" {
    const allocator = std.testing.allocator;
    const to = try Address.fromHex("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045");
    const result = try encodeExecute(allocator, .{ .to = to, .value = 0, .data = &[_]u8{} });
    defer allocator.free(result);
    try std.testing.expectEqualSlices(u8, &EXECUTE_SELECTOR, result[0..4]);
}

test "encodeExecute correct length (empty data)" {
    const allocator = std.testing.allocator;
    const to = try Address.fromHex("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045");
    const result = try encodeExecute(allocator, .{ .to = to, .value = 0, .data = &[_]u8{} });
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 164), result.len);
}

test "encodeExecute with calldata" {
    const allocator = std.testing.allocator;
    const to = try Address.fromHex("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045");
    const data = [_]u8{ 0xab, 0xcd };
    const result = try encodeExecute(allocator, .{ .to = to, .value = 100, .data = &data });
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 164), result.len);
}

test "encodeExecute preserves target in packed encoding" {
    const allocator = std.testing.allocator;
    const to = try Address.fromHex("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045");
    const result = try encodeExecute(allocator, .{ .to = to, .value = 0, .data = &[_]u8{} });
    defer allocator.free(result);
    try std.testing.expectEqualSlices(u8, &to.bytes, result[100..120]);
}

test "encodeExecute preserves value in packed encoding" {
    const allocator = std.testing.allocator;
    const to = try Address.fromHex("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045");
    const result = try encodeExecute(allocator, .{ .to = to, .value = 42, .data = &[_]u8{} });
    defer allocator.free(result);
    try std.testing.expectEqual(@as(u8, 42), result[151]);
}

test "encodeExecute single mode has zero execMode" {
    const allocator = std.testing.allocator;
    const to = try Address.fromHex("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045");
    const result = try encodeExecute(allocator, .{ .to = to, .value = 0, .data = &[_]u8{} });
    defer allocator.free(result);
    for (result[4..36]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "encodeExecuteBatch correct selector" {
    const allocator = std.testing.allocator;
    const to = try Address.fromHex("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045");
    const execs = [_]Execution{.{ .to = to, .value = 0, .data = &[_]u8{} }};
    const result = try encodeExecuteBatch(allocator, &execs);
    defer allocator.free(result);
    try std.testing.expectEqualSlices(u8, &EXECUTE_SELECTOR, result[0..4]);
}

test "encodeExecuteBatch has batch execMode" {
    const allocator = std.testing.allocator;
    const to = try Address.fromHex("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045");
    const execs = [_]Execution{.{ .to = to, .value = 0, .data = &[_]u8{} }};
    const result = try encodeExecuteBatch(allocator, &execs);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(u8, 0x01), result[4]);
    for (result[5..36]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "encodeExecuteBatch two elements" {
    const allocator = std.testing.allocator;
    const to1 = try Address.fromHex("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045");
    const to2 = try Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const execs = [_]Execution{
        .{ .to = to1, .value = 0, .data = &[_]u8{} },
        .{ .to = to2, .value = 1000, .data = &[_]u8{} },
    };
    const result = try encodeExecuteBatch(allocator, &execs);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 484), result.len);
}
