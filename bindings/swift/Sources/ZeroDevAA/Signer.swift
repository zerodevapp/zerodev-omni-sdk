import CZeroDevAA

public final class Signer: @unchecked Sendable {
    let ptr: OpaquePointer

    private init(ptr: OpaquePointer) {
        self.ptr = ptr
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

    deinit {
        aa_signer_destroy(ptr)
    }
}
