import CZeroDevAA

/// Protocol for custom signer implementations.
public protocol SignerProtocol: AnyObject {
    func signHash(_ hash: [UInt8]) throws -> [UInt8]
    func signMessage(_ msg: [UInt8]) throws -> [UInt8]
    func signTypedDataHash(_ hash: [UInt8]) throws -> [UInt8]
    func getAddress() -> [UInt8]
}

// MARK: - C trampoline functions for custom signer vtable

private func swiftSignHash(ctx: UnsafeMutableRawPointer?, hash: UnsafePointer<UInt8>?, sigOut: UnsafeMutablePointer<UInt8>?) -> Int32 {
    guard let ctx = ctx, let hash = hash, let sigOut = sigOut else { return 1 }
    let impl = Unmanaged<AnyObject>.fromOpaque(ctx).takeUnretainedValue() as! SignerProtocol
    do {
        let sig = try impl.signHash(Array(UnsafeBufferPointer(start: hash, count: 32)))
        guard sig.count == 65 else { return 1 }
        for i in 0..<65 { sigOut[i] = sig[i] }
        return 0
    } catch { return 1 }
}

private func swiftSignMessage(ctx: UnsafeMutableRawPointer?, msg: UnsafePointer<UInt8>?, msgLen: Int, sigOut: UnsafeMutablePointer<UInt8>?) -> Int32 {
    guard let ctx = ctx, let msg = msg, let sigOut = sigOut else { return 1 }
    let impl = Unmanaged<AnyObject>.fromOpaque(ctx).takeUnretainedValue() as! SignerProtocol
    do {
        let sig = try impl.signMessage(Array(UnsafeBufferPointer(start: msg, count: msgLen)))
        guard sig.count == 65 else { return 1 }
        for i in 0..<65 { sigOut[i] = sig[i] }
        return 0
    } catch { return 1 }
}

private func swiftSignTypedDataHash(ctx: UnsafeMutableRawPointer?, hash: UnsafePointer<UInt8>?, sigOut: UnsafeMutablePointer<UInt8>?) -> Int32 {
    guard let ctx = ctx, let hash = hash, let sigOut = sigOut else { return 1 }
    let impl = Unmanaged<AnyObject>.fromOpaque(ctx).takeUnretainedValue() as! SignerProtocol
    do {
        let sig = try impl.signTypedDataHash(Array(UnsafeBufferPointer(start: hash, count: 32)))
        guard sig.count == 65 else { return 1 }
        for i in 0..<65 { sigOut[i] = sig[i] }
        return 0
    } catch { return 1 }
}

private func swiftGetAddress(ctx: UnsafeMutableRawPointer?, addrOut: UnsafeMutablePointer<UInt8>?) -> Int32 {
    guard let ctx = ctx, let addrOut = addrOut else { return 1 }
    let impl = Unmanaged<AnyObject>.fromOpaque(ctx).takeUnretainedValue() as! SignerProtocol
    let addr = impl.getAddress()
    guard addr.count == 20 else { return 1 }
    for i in 0..<20 { addrOut[i] = addr[i] }
    return 0
}

nonisolated(unsafe) private var customVTable = aa_signer_vtable(
    sign_hash: swiftSignHash,
    sign_message: swiftSignMessage,
    sign_typed_data_hash: swiftSignTypedDataHash,
    get_address: swiftGetAddress
)

// MARK: - Signer

public final class Signer: @unchecked Sendable {
    let ptr: OpaquePointer
    private var customRef: Unmanaged<AnyObject>?

    private init(ptr: OpaquePointer, customRef: Unmanaged<AnyObject>? = nil) {
        self.ptr = ptr
        self.customRef = customRef
    }

    /// Create a local signer from a 32-byte private key.
    public static func local(privateKey: [UInt8]) throws -> Signer {
        precondition(privateKey.count == 32, "privateKey must be 32 bytes")
        var out: OpaquePointer?
        let status = privateKey.withUnsafeBufferPointer { buf in
            aa_signer_local(buf.baseAddress, &out)
        }
        try checkResult(status)
        guard let p = out else { throw AAError.nullOutPtr }
        return Signer(ptr: p)
    }

    /// Create a signer with a randomly generated private key.
    public static func generate() throws -> Signer {
        var out: OpaquePointer?
        let status = aa_signer_generate(&out)
        try checkResult(status)
        guard let p = out else { throw AAError.nullOutPtr }
        return Signer(ptr: p)
    }

    /// Create a JSON-RPC signer (Privy, custodial wallets, etc.).
    public static func rpc(url: String, address: [UInt8]) throws -> Signer {
        precondition(address.count == 20, "address must be 20 bytes")
        var out: OpaquePointer?
        let status = url.withCString { urlPtr in
            address.withUnsafeBufferPointer { addrBuf in
                aa_signer_rpc(urlPtr, addrBuf.baseAddress, &out)
            }
        }
        try checkResult(status)
        guard let p = out else { throw AAError.nullOutPtr }
        return Signer(ptr: p)
    }

    /// Create a custom signer from a `SignerProtocol` implementation.
    public static func custom(_ impl: SignerProtocol) throws -> Signer {
        let retained = Unmanaged<AnyObject>.passRetained(impl as AnyObject)
        var out: OpaquePointer?
        let status = aa_signer_custom(&customVTable, retained.toOpaque(), &out)
        guard status == AA_OK, let p = out else {
            retained.release()
            try checkResult(status)
            throw AAError.nullOutPtr
        }
        return Signer(ptr: p, customRef: retained)
    }

    deinit {
        aa_signer_destroy(ptr)
        customRef?.release()
    }
}
