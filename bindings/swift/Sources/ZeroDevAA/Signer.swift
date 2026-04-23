import CZeroDevAA

/// Protocol for custom signer implementations (Privy, WalletConnect, HSM, etc.).
///
/// ## Threading Contract
/// These methods are called **synchronously from a background thread** by the
/// Zig C FFI layer. Blocking is safe — you will NOT deadlock the main thread.
///
/// If your signer wraps an async API (e.g. Privy's `wallet.provider.request`),
/// bridge with a semaphore:
/// ```swift
/// func signMessage(_ msg: [UInt8]) throws -> [UInt8] {
///     let semaphore = DispatchSemaphore(value: 0)
///     var result: [UInt8]?
///     Task {
///         result = try await myAsyncSign(msg)
///         semaphore.signal()
///     }
///     semaphore.wait()
///     return result!
/// }
/// ```
///
/// ## Hex Helpers
/// Use `hexEncode(_:)` and `hexDecode(_:)` from this module for conversions.
/// `Address(hex:)` and `Hash(hex:)` also accept 0x-prefixed strings.
public protocol SignerProtocol: AnyObject {
    /// Sign a raw 32-byte hash. Return 65-byte signature (r + s + v).
    func signHash(_ hash: [UInt8]) throws -> [UInt8]
    /// Sign a message with EIP-191 personal_sign wrapping. Return 65-byte signature.
    func signMessage(_ msg: [UInt8]) throws -> [UInt8]
    /// Sign an EIP-712 typed data hash. Return 65-byte signature.
    func signTypedDataHash(_ hash: [UInt8]) throws -> [UInt8]
    /// Return the 20-byte signer address.
    func getAddress() -> [UInt8]

    /// Sign an EIP-7702 authorization tuple `(chainId, address, nonce)`.
    ///
    /// Default: returns `nil`, which instructs the SDK to fall back to hashing
    /// `0x05 || rlp([chainId, address, nonce])` and calling `signHash`.
    ///
    /// Override to install a native EIP-7702 implementation (hardware wallets,
    /// MPC backends). When overridden to return a non-nil value, the FFI
    /// vtable's `sign_authorization` slot is wired up so the SDK invokes this
    /// directly instead of falling back.
    func signAuthorization(chainId: UInt64, address: [UInt8], nonce: UInt64) throws -> Authorization?
}

extension SignerProtocol {
    /// Default implementation — returns `nil` so the SDK falls back to
    /// `signHash` on the EIP-7702 auth-tuple digest.
    public func signAuthorization(chainId: UInt64, address: [UInt8], nonce: UInt64) throws -> Authorization? {
        return nil
    }
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

private func swiftSignAuthorization(ctx: UnsafeMutableRawPointer?, chainId: UInt64, address: UnsafePointer<UInt8>?, nonce: UInt64, out: UnsafeMutablePointer<aa_authorization_t>?) -> Int32 {
    guard let ctx = ctx, let address = address, let out = out else { return 1 }
    let impl = Unmanaged<AnyObject>.fromOpaque(ctx).takeUnretainedValue() as! SignerProtocol
    let addrBytes = Array(UnsafeBufferPointer(start: address, count: 20))
    do {
        guard let auth = try impl.signAuthorization(chainId: chainId, address: addrBytes, nonce: nonce) else {
            // Shouldn't happen: this trampoline is only installed when the impl
            // reports it provides a native sign_authorization. Signal failure
            // so the SDK can propagate the error.
            return 1
        }
        guard auth.address.count == 20, auth.r.count == 32, auth.s.count == 32 else { return 1 }
        out.pointee.chain_id = auth.chainId
        out.pointee.nonce = auth.nonce
        out.pointee.y_parity = auth.yParity
        // out.pointee.address / r / s are fixed-size C arrays — write via raw pointer
        let raw = UnsafeMutableRawPointer(out)
        let addressOffset = MemoryLayout<aa_authorization_t>.offset(of: \aa_authorization_t.address)!
        let rOffset = MemoryLayout<aa_authorization_t>.offset(of: \aa_authorization_t.r)!
        let sOffset = MemoryLayout<aa_authorization_t>.offset(of: \aa_authorization_t.s)!
        auth.address.withUnsafeBufferPointer { src in
            raw.advanced(by: addressOffset).copyMemory(from: src.baseAddress!, byteCount: 20)
        }
        auth.r.withUnsafeBufferPointer { src in
            raw.advanced(by: rOffset).copyMemory(from: src.baseAddress!, byteCount: 32)
        }
        auth.s.withUnsafeBufferPointer { src in
            raw.advanced(by: sOffset).copyMemory(from: src.baseAddress!, byteCount: 32)
        }
        return 0
    } catch { return 1 }
}

// Default vtable — leaves `sign_authorization` NULL so the SDK falls back to
// hashing the EIP-7702 auth tuple and invoking `sign_hash`.
nonisolated(unsafe) private var customVTable = aa_signer_vtable(
    sign_hash: swiftSignHash,
    sign_message: swiftSignMessage,
    sign_typed_data_hash: swiftSignTypedDataHash,
    get_address: swiftGetAddress,
    sign_authorization: nil
)

// Vtable for custom signers that provide a native `signAuthorization`.
// The SDK invokes the callback directly instead of falling back.
nonisolated(unsafe) private var customVTableWithAuth = aa_signer_vtable(
    sign_hash: swiftSignHash,
    sign_message: swiftSignMessage,
    sign_typed_data_hash: swiftSignTypedDataHash,
    get_address: swiftGetAddress,
    sign_authorization: swiftSignAuthorization
)

/// Protocol-level marker for custom signers that implement `signAuthorization`
/// natively. Conforming signers that return `true` from
/// `providesSignAuthorization` wire up the FFI vtable's `sign_authorization`
/// slot; the default is `false` so the SDK falls back to hashing the auth
/// tuple and calling `signHash`.
public protocol SignerProvidesAuthorization {
    var providesSignAuthorization: Bool { get }
}

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
    ///
    /// If `impl` also conforms to `SignerProvidesAuthorization` and returns
    /// `true` from `providesSignAuthorization`, the FFI vtable wires up a
    /// native `sign_authorization` callback; otherwise the slot is left NULL
    /// and the SDK falls back to hashing the auth tuple and invoking
    /// `signHash`.
    public static func custom(_ impl: SignerProtocol) throws -> Signer {
        let retained = Unmanaged<AnyObject>.passRetained(impl as AnyObject)
        let hasAuth = (impl as? SignerProvidesAuthorization)?.providesSignAuthorization ?? false
        var out: OpaquePointer?
        let status = hasAuth
            ? aa_signer_custom(&customVTableWithAuth, retained.toOpaque(), &out)
            : aa_signer_custom(&customVTable, retained.toOpaque(), &out)
        guard status == AA_OK, let p = out else {
            retained.release()
            try checkResult(status)
            throw AAError.nullOutPtr
        }
        return Signer(ptr: p, customRef: retained)
    }

    /// Sign an EIP-7702 authorization tuple `(chainId, address, nonce)`.
    ///
    /// Works on any signer. For custom signers that did not provide a native
    /// `signAuthorization` hook, the SDK computes
    /// `keccak256(0x05 || rlp([chainId, address, nonce]))` and signs the hash
    /// via `signHash` automatically.
    public func signAuthorization(chainId: UInt64, address: [UInt8], nonce: UInt64) throws -> Authorization {
        precondition(address.count == 20, "address must be 20 bytes")
        var out = aa_authorization_t()
        let status = address.withUnsafeBufferPointer { addrBuf in
            aa_signer_sign_authorization(ptr, chainId, addrBuf.baseAddress, nonce, &out)
        }
        try checkResult(status)
        var addrBytes = [UInt8](repeating: 0, count: 20)
        var rBytes = [UInt8](repeating: 0, count: 32)
        var sBytes = [UInt8](repeating: 0, count: 32)
        withUnsafePointer(to: &out) { opPtr in
            let raw = UnsafeRawPointer(opPtr)
            let addressOffset = MemoryLayout<aa_authorization_t>.offset(of: \aa_authorization_t.address)!
            let rOffset = MemoryLayout<aa_authorization_t>.offset(of: \aa_authorization_t.r)!
            let sOffset = MemoryLayout<aa_authorization_t>.offset(of: \aa_authorization_t.s)!
            addrBytes.withUnsafeMutableBufferPointer { dst in
                UnsafeMutableRawPointer(mutating: dst.baseAddress!).copyMemory(from: raw.advanced(by: addressOffset), byteCount: 20)
            }
            rBytes.withUnsafeMutableBufferPointer { dst in
                UnsafeMutableRawPointer(mutating: dst.baseAddress!).copyMemory(from: raw.advanced(by: rOffset), byteCount: 32)
            }
            sBytes.withUnsafeMutableBufferPointer { dst in
                UnsafeMutableRawPointer(mutating: dst.baseAddress!).copyMemory(from: raw.advanced(by: sOffset), byteCount: 32)
            }
        }
        return Authorization(
            chainId: out.chain_id,
            address: addrBytes,
            nonce: out.nonce,
            yParity: out.y_parity,
            r: rBytes,
            s: sBytes
        )
    }

    /// Create a signer from an async implementation (Privy, WalletConnect, etc.).
    ///
    /// Bridges async signing to the synchronous C FFI using a dedicated dispatch queue,
    /// avoiding the semaphore deadlock that occurs on iOS's cooperative executor.
    ///
    /// Set `providesSignAuthorization: true` to wire the FFI vtable's
    /// `sign_authorization` slot to the impl's `signAuthorization` method.
    /// The default (`false`) leaves the slot NULL and the SDK falls back to
    /// hashing the EIP-7702 auth tuple and invoking `signHash`.
    public static func async(_ impl: AsyncSignerProtocol, providesSignAuthorization: Bool = false) throws -> Signer {
        return try custom(AsyncSignerBridge(impl, providesSignAuthorization: providesSignAuthorization))
    }

    deinit {
        aa_signer_destroy(ptr)
        customRef?.release()
    }
}
