import CZeroDevAA
import Foundation

public final class UserOp: @unchecked Sendable {
    let ptr: OpaquePointer
    private let account: Account  // strong ref

    init(ptr: OpaquePointer, account: Account) {
        self.ptr = ptr
        self.account = account
    }

    public func hash() throws -> Hash {
        var hashOut = [UInt8](repeating: 0, count: 32)
        let status = hashOut.withUnsafeMutableBufferPointer { buf in
            aa_userop_hash(ptr, account.ptr, buf.baseAddress)
        }
        try checkResult(status)
        return Hash(bytes: hashOut)
    }

    public func sign() throws {
        let status = aa_userop_sign(ptr, account.ptr)
        try checkResult(status)
    }

    public func toJSON() throws -> String {
        var jsonPtr: UnsafeMutablePointer<CChar>?
        var jsonLen: Int = 0
        let status = aa_userop_to_json(ptr, &jsonPtr, &jsonLen)
        try checkResult(status)
        guard let p = jsonPtr else { throw AAError.serializeFailed("null json pointer") }
        let result = String(cString: p)
        aa_free(p)
        return result
    }

    public func applyGasJSON(_ gasJSON: String) throws {
        let status = gasJSON.withCString { cStr in
            aa_userop_apply_gas_json(ptr, cStr, gasJSON.utf8.count)
        }
        try checkResult(status)
    }

    public func applyPaymasterJSON(_ pmJSON: String) throws {
        let status = pmJSON.withCString { cStr in
            aa_userop_apply_paymaster_json(ptr, cStr, pmJSON.utf8.count)
        }
        try checkResult(status)
    }

    deinit {
        aa_userop_destroy(ptr)
    }
}
