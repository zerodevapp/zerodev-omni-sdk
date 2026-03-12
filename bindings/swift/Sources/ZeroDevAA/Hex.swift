import Foundation

private let hexChars: [UInt8] = Array("0123456789abcdef".utf8)

public func hexEncode(_ bytes: [UInt8]) -> String {
    var out = [UInt8](repeating: 0, count: bytes.count * 2)
    for (i, b) in bytes.enumerated() {
        out[i * 2] = hexChars[Int(b >> 4)]
        out[i * 2 + 1] = hexChars[Int(b & 0x0F)]
    }
    return String(bytes: out, encoding: .ascii)!
}

public func hexDecode(_ hex: String) throws -> [UInt8] {
    var s = hex
    if s.hasPrefix("0x") || s.hasPrefix("0X") {
        s = String(s.dropFirst(2))
    }
    guard s.count % 2 == 0 else {
        throw AAError.invalidHex
    }
    var bytes = [UInt8]()
    bytes.reserveCapacity(s.count / 2)
    var index = s.startIndex
    while index < s.endIndex {
        let nextIndex = s.index(index, offsetBy: 2)
        guard let byte = UInt8(s[index..<nextIndex], radix: 16) else {
            throw AAError.invalidHex
        }
        bytes.append(byte)
        index = nextIndex
    }
    return bytes
}
