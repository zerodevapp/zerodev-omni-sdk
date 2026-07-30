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

    /// Create a Kernel smart account.
    ///
    /// When `address` is `nil` (the default), the sender is derived
    /// counterfactually via CREATE2 from `(signer, version, index)`. When
    /// supplied, the account's sender is pinned to that address
    /// (migration path for kernel-version upgrades, or operating a
    /// pre-existing wallet whose CREATE2 salt this SDK no longer
    /// computes). Pinning affects the sender only; factory init_code is
    /// still emitted on the first UserOp exactly as it would be for a
    /// counterfactually-derived account (governed by the EntryPoint
    /// nonce). Callers pinning an already-deployed account with
    /// EntryPoint nonce 0 (rare — funded but never used) should drop the
    /// factory bytes via the low-level UserOp API.
    public func newAccount(
        signer: Signer,
        version: KernelVersion,
        index: UInt32 = 0,
        address: [UInt8]? = nil
    ) throws -> Account {
        if let a = address {
            precondition(a.count == 20, "address must be 20 bytes")
        }
        var out: OpaquePointer?
        let status = address?.withUnsafeBufferPointer { buf in
            aa_account_create(
                ptr,
                signer.ptr,
                aa_kernel_version(rawValue: UInt32(version.rawValue)),
                index,
                buf.baseAddress,
                &out
            )
        } ?? aa_account_create(
            ptr,
            signer.ptr,
            aa_kernel_version(rawValue: UInt32(version.rawValue)),
            index,
            nil,
            &out
        )
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
