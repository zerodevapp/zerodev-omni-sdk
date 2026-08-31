import Foundation

public struct Address: Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 20, "Address must be 20 bytes")
        self.bytes = bytes
    }

    /// Create from a 0x-prefixed hex string.
    public init(hex: String) throws {
        let decoded = try hexDecode(hex)
        guard decoded.count == 20 else {
            throw AAError.getAddressFailed("Address hex must decode to 20 bytes, got \(decoded.count)")
        }
        self.bytes = decoded
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

    /// Create from a 0x-prefixed hex string.
    public init(hex: String) throws {
        let decoded = try hexDecode(hex)
        guard decoded.count == 32 else {
            throw AAError.invalidHex
        }
        self.bytes = decoded
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
    case v3_3 = 0
}

/// EIP-7702 authorization tuple.
///
/// `yParity`, `r`, and `s` together form the signature over
/// `keccak256(0x05 || rlp([chainId, address, nonce]))`. The SDK produces these
/// values via `Signer.signAuthorization(...)` and attaches them to the first
/// UserOperation of an EIP-7702 account so the EOA delegates its code to the
/// Kernel implementation.
public struct Authorization: Sendable {
    /// Chain ID this authorization is valid on (0 = any chain).
    public let chainId: UInt64
    /// Delegation target (Kernel implementation address). 20 bytes.
    public let address: [UInt8]
    /// EOA nonce at the time of signing.
    public let nonce: UInt64
    /// Signature y-parity (0 or 1).
    public let yParity: UInt8
    /// Signature r component. 32 bytes.
    public let r: [UInt8]
    /// Signature s component. 32 bytes.
    public let s: [UInt8]

    public init(chainId: UInt64, address: [UInt8], nonce: UInt64, yParity: UInt8, r: [UInt8], s: [UInt8]) {
        precondition(address.count == 20, "address must be 20 bytes")
        precondition(r.count == 32, "r must be 32 bytes")
        precondition(s.count == 32, "s must be 32 bytes")
        self.chainId = chainId
        self.address = address
        self.nonce = nonce
        self.yParity = yParity
        self.r = r
        self.s = s
    }
}

/// Gas pricing middleware provider.
public enum GasMiddleware: Sendable {
    /// ZeroDev: calls zd_getUserOperationGasPrice.
    case zeroDev
    /// Pimlico: calls pimlico_getUserOperationGasPrice.
    case pimlico
}

/// Paymaster sponsorship middleware provider.
public enum PaymasterMiddleware: Sendable {
    /// No paymaster — send unsponsored (user pays gas).
    case none
    /// ZeroDev: calls pm_getPaymasterStubData / pm_getPaymasterData.
    case zeroDev
}

/// Full receipt from eth_getUserOperationReceipt.
/// Matches the viem UserOperationReceipt type.
/// Provides both raw JSON access and parsed convenience fields.
public struct UserOperationReceipt: Sendable {
    /// The raw JSON response string.
    public let json: String

    /// Hash of the user operation.
    public var userOpHash: String { extract("userOpHash") ?? "" }
    /// Entrypoint address.
    public var entryPoint: String { extract("entryPoint") ?? "" }
    /// Sender address.
    public var sender: String { extract("sender") ?? "" }
    /// Anti-replay parameter (hex string).
    public var nonce: String { extract("nonce") ?? "" }
    /// Paymaster address, if any.
    public var paymaster: String? { extract("paymaster") }
    /// Actual gas cost (hex string).
    public var actualGasCost: String { extract("actualGasCost") ?? "" }
    /// Actual gas used (hex string).
    public var actualGasUsed: String { extract("actualGasUsed") ?? "" }
    /// If the user operation execution was successful.
    public var success: Bool { parsed?["success"] as? Bool ?? false }
    /// Revert reason, if unsuccessful.
    public var reason: String? { extract("reason") }
    /// Logs emitted during execution.
    public var logs: [[String: Any]] { parsed?["logs"] as? [[String: Any]] ?? [] }
    /// Transaction receipt of the user operation execution.
    public var receipt: [String: Any]? { parsed?["receipt"] as? [String: Any] }

    private var parsed: [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func extract(_ key: String) -> String? {
        parsed?[key] as? String
    }
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
