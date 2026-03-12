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
    }

    public func newAccount(privateKey: [UInt8], version: KernelVersion, index: UInt32 = 0) throws -> Account {
        precondition(privateKey.count == 32, "privateKey must be 32 bytes")
        var out: OpaquePointer?
        let status = privateKey.withUnsafeBufferPointer { buf in
            aa_account_create(ptr, buf.baseAddress, aa_kernel_version(rawValue: UInt32(version.rawValue)), index, &out)
        }
        try checkResult(status)
        guard let p = out else { throw AAError.nullOutPtr }
        return Account(ptr: p, context: self)
    }

    deinit {
        aa_context_destroy(ptr)
    }
}
