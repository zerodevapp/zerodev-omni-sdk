//! Mozilla CA roots baked into the binary, so HTTPS works where the system
//! trust store can't be scanned. Zig's `Certificate.Bundle.rescan` has no iOS
//! branch — on iOS it yields an empty bundle and every TLS handshake fails for
//! want of a root to verify against — so the built-in HTTP client falls back to
//! these roots there. Desktop and Android keep using the system store.

const std = @import("std");
const Bundle = std.crypto.Certificate.Bundle;

// cacert.pem is curl's extract of Mozilla's CA store, from
// https://curl.se/docs/caextract.html, dated 2026-07-16. Its own SHA-256 —
// the download checksum curl publishes — is
//   3ff344e30b9b1ed2971044eabb438a08f2e2245ddb5f8ab1a3ad8b63ab4eaf91
// It was extracted from Mozilla's certdata.txt, whose SHA-256 the file header
// records as e57912808daef7b2b0fa4df2ccf17e47aeaf26c839a38f85c76003ebafd866bd.
// Roots expire and get added, so refresh it periodically: replace the file,
// verify its SHA-256 against the one curl publishes, and update these lines.
pub const pem = @embedFile("cacert.pem");

/// The SHA-256 of [pem], for the test and for callers that want to check it.
pub const pem_sha256 = "3ff344e30b9b1ed2971044eabb438a08f2e2245ddb5f8ab1a3ad8b63ab4eaf91";

/// Parse the embedded PEM roots into `cb`. `now_sec` is the current Unix time;
/// it is threaded through to certificate parsing, as `Bundle` requires.
pub fn addEmbedded(cb: *Bundle, gpa: std.mem.Allocator, now_sec: i64) !void {
    // Like std's `addCertsFromFile`, but over a slice so it works on @embedFile
    // data with no filesystem access.
    const base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");
    const begin_marker = "-----BEGIN CERTIFICATE-----";
    const end_marker = "-----END CERTIFICATE-----";

    var start_index: usize = 0;
    while (std.mem.findPos(u8, pem, start_index, begin_marker)) |begin_marker_start| {
        const cert_start = begin_marker_start + begin_marker.len;
        const cert_end = std.mem.findPos(u8, pem, cert_start, end_marker) orelse
            return error.MissingEndCertificateMarker;
        start_index = cert_end + end_marker.len;
        const encoded_cert = std.mem.trim(u8, pem[cert_start..cert_end], " \t\r\n");
        const decoded_start: u32 = @intCast(cb.bytes.items.len);
        try cb.bytes.ensureUnusedCapacity(gpa, encoded_cert.len / 4 * 3 + 3);
        const dest_buf = cb.bytes.allocatedSlice()[decoded_start..];
        cb.bytes.items.len += try base64.decode(dest_buf, encoded_cert);
        try cb.parseCert(gpa, decoded_start, now_sec);
    }
}

test "the embedded bundle matches its documented sha-256" {
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pem, &actual, .{});
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, pem_sha256);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "addEmbedded loads the Mozilla roots into an empty bundle" {
    var cb: Bundle = .empty;
    defer cb.deinit(std.testing.allocator);
    // A timestamp inside the bundle's validity window (2026-07-15).
    try addEmbedded(&cb, std.testing.allocator, 1_752_537_600);
    // The Mozilla store carries well over a hundred roots.
    try std.testing.expect(cb.map.count() > 100);
}
