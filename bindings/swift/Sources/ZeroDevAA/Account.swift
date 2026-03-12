import CZeroDevAA

public final class Account: @unchecked Sendable {
    let ptr: OpaquePointer
    private let context: Context  // strong ref prevents use-after-free

    init(ptr: OpaquePointer, context: Context) {
        self.ptr = ptr
        self.context = context
    }

    public func getAddress() throws -> Address {
        var addr = [UInt8](repeating: 0, count: 20)
        let status = addr.withUnsafeMutableBufferPointer { buf in
            aa_account_get_address(ptr, buf.baseAddress)
        }
        try checkResult(status)
        return Address(bytes: addr)
    }

    public func sendUserOp(calls: [Call]) throws -> Hash {
        let cCalls = try marshalCalls(calls)
        var hashOut = [UInt8](repeating: 0, count: 32)
        let status = cCalls.withUnsafeBufferPointer { callsBuf in
            hashOut.withUnsafeMutableBufferPointer { hashBuf in
                aa_send_userop(ptr, callsBuf.baseAddress, callsBuf.count, hashBuf.baseAddress)
            }
        }
        try checkResult(status)
        return Hash(bytes: hashOut)
    }

    public func buildUserOp(calls: [Call]) throws -> UserOp {
        let cCalls = try marshalCalls(calls)
        var out: OpaquePointer?
        let status = cCalls.withUnsafeBufferPointer { callsBuf in
            aa_userop_build(ptr, callsBuf.baseAddress, callsBuf.count, &out)
        }
        try checkResult(status)
        guard let p = out else { throw AAError.nullOutPtr }
        return UserOp(ptr: p, account: self)
    }

    deinit {
        aa_account_destroy(ptr)
    }
}

private func marshalCalls(_ calls: [Call]) throws -> [aa_call_t] {
    guard !calls.isEmpty else { throw AAError.noCalls }
    return calls.map { call in
        var c = aa_call_t()
        // target and value_be are const in C, so use raw pointer to write
        withUnsafeMutablePointer(to: &c) { ptr in
            let raw = UnsafeMutableRawPointer(ptr)
            let targetOffset = MemoryLayout<aa_call_t>.offset(of: \aa_call_t.target)!
            let valueOffset = MemoryLayout<aa_call_t>.offset(of: \aa_call_t.value_be)!
            call.target.bytes.withUnsafeBufferPointer { src in
                raw.advanced(by: targetOffset).copyMemory(from: src.baseAddress!, byteCount: 20)
            }
            call.value.withUnsafeBufferPointer { src in
                raw.advanced(by: valueOffset).copyMemory(from: src.baseAddress!, byteCount: 32)
            }
        }
        if call.calldata.isEmpty {
            c.calldata = nil
            c.calldata_len = 0
        } else {
            call.calldata.withUnsafeBufferPointer { buf in
                c.calldata = buf.baseAddress
                c.calldata_len = buf.count
            }
        }
        return c
    }
}
