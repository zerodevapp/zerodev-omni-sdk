import CZeroDevAA

public final class Context: @unchecked Sendable {
    let ptr: OpaquePointer

    public init(projectID: String, rpcURL: String = "", bundlerURL: String = "", chainID: UInt64, gasMiddleware: GasMiddleware, paymasterMiddleware: PaymasterMiddleware = .zeroDev) throws {
        var out: OpaquePointer?
        let status = aa_context_create(projectID, rpcURL, bundlerURL, chainID, &out)
        try checkResult(status)
        guard let p = out else { throw AAError.nullOutPtr }
        self.ptr = p

        switch gasMiddleware {
        case .zeroDev:
            try checkResult(aa_context_set_gas_middleware(ptr, aa_gas_zerodev))
        }

        switch paymasterMiddleware {
        case .zeroDev:
            try checkResult(aa_context_set_paymaster_middleware(ptr, aa_paymaster_zerodev))
        case .none:
            break
        }

        // Use URLSession for all HTTP on Apple platforms (Zig's TLS fails on iOS)
        useURLSessionTransport()
    }

    public func newAccount(signer: Signer, version: KernelVersion, index: UInt32 = 0) throws -> Account {
        var out: OpaquePointer?
        let status = aa_account_create(ptr, signer.ptr, aa_kernel_version(rawValue: UInt32(version.rawValue)), index, &out)
        try checkResult(status)
        guard let p = out else { throw AAError.nullOutPtr }
        return Account(ptr: p, context: self, signer: signer)
    }

    /// Same as ``newAccount(signer:version:index:)`` but pins the sender
    /// address to `address` instead of counterfactually deriving it from
    /// `(signer, version, index)`. Use this to operate a pre-existing
    /// on-chain kernel account whose address this SDK's CREATE2 no longer
    /// computes (e.g. a v3.1 wallet during a v3.1 → v3.3 migration).
    ///
    /// The account is assumed already-deployed: no factory init_code is
    /// emitted on the first UserOp. The caller is trusted; the SDK does not
    /// verify that `address` corresponds to `signer`.
    public func newAccount(signer: Signer, version: KernelVersion, index: UInt32 = 0, address: [UInt8]) throws -> Account {
        precondition(address.count == 20, "address must be 20 bytes")
        var out: OpaquePointer?
        let status = address.withUnsafeBufferPointer { buf in
            aa_account_create_at(
                ptr,
                signer.ptr,
                aa_kernel_version(rawValue: UInt32(version.rawValue)),
                index,
                buf.baseAddress,
                &out
            )
        }
        try checkResult(status)
        guard let p = out else { throw AAError.nullOutPtr }
        return Account(ptr: p, context: self, signer: signer)
    }

    /// Create a Kernel smart account using EIP-7702 delegation.
    ///
    /// The account's address is the signer's EOA address — there is no
    /// CREATE2, no init code, and no index parameter. On the first
    /// UserOperation the SDK signs an authorization tuple
    /// `(chainId, Kernel implementation for version, EOA nonce)` and attaches
    /// it via the `eip7702Auth` field; subsequent UserOps skip the
    /// authorization once delegation is installed on-chain.
    ///
    /// Today only `.v3_3` supports EIP-7702.
    public func newAccount7702(signer: Signer, version: KernelVersion) throws -> Account {
        var out: OpaquePointer?
        let status = aa_context_new_account_7702(ptr, signer.ptr, aa_kernel_version(rawValue: UInt32(version.rawValue)), &out)
        try checkResult(status)
        guard let p = out else { throw AAError.nullOutPtr }
        return Account(ptr: p, context: self, signer: signer)
    }

    deinit {
        aa_context_destroy(ptr)
    }
}
