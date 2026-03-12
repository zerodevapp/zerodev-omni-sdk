import Foundation

public struct Address: Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 20, "Address must be 20 bytes")
        self.bytes = bytes
    }

    public func toHex() -> String {
        "0x" + hexEncode(bytes)
    }

    public var description: String { toHex() }
}

public struct Hash: Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 32, "Hash must be 32 bytes")
        self.bytes = bytes
    }

    public func toHex() -> String {
        "0x" + hexEncode(bytes)
    }

    public var isZero: Bool {
        bytes.allSatisfy { $0 == 0 }
    }

    public var description: String { toHex() }
}

public enum KernelVersion: Int32, Sendable {
    case v3_1 = 0
    case v3_2 = 1
    case v3_3 = 2
}

public enum Middleware: Sendable {
    case zeroDev
}

public struct Call: Sendable {
    public let target: Address
    public let value: [UInt8]   // 32 bytes, big-endian u256
    public let calldata: [UInt8]

    public init(target: Address, value: [UInt8] = [UInt8](repeating: 0, count: 32), calldata: [UInt8] = []) {
        precondition(value.count == 32, "Value must be 32 bytes")
        self.target = target
        self.value = value
        self.calldata = calldata
    }
}
