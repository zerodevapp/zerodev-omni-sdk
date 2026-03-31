import CZeroDevAA

public enum AAError: Error, Sendable {
    case nullOutPtr
    case invalidUrl
    case outOfMemory
    case invalidPrivateKey
    case invalidKernelVersion
    case nullContext
    case nullAccount
    case nullUserOp
    case getAddressFailed(String)
    case buildUserOpFailed(String)
    case hashUserOpFailed(String)
    case signUserOpFailed(String)
    case sendUserOpFailed(String)
    case estimateGasFailed(String)
    case paymasterFailed(String)
    case noCalls
    case invalidHex
    case applyJsonFailed(String)
    case serializeFailed(String)
    case noGasMiddleware
    case noPaymasterMiddleware
    case receiptTimeout(String)
    case receiptFailed(String)
    case invalidSigner(String)
    case unknown(Int32, String)
}

func lastErrorMessage() -> String {
    guard let ptr = aa_get_last_error() else { return "" }
    return String(cString: ptr)
}

func checkResult(_ status: aa_status) throws {
    guard status != AA_OK else { return }
    let code = Int32(status.rawValue)
    let msg = lastErrorMessage()
    switch code {
    case 1:  throw AAError.nullOutPtr
    case 2:  throw AAError.invalidUrl
    case 3:  throw AAError.outOfMemory
    case 4:  throw AAError.invalidPrivateKey
    case 5:  throw AAError.invalidKernelVersion
    case 6:  throw AAError.nullContext
    case 7:  throw AAError.nullAccount
    case 8:  throw AAError.nullUserOp
    case 9:  throw AAError.getAddressFailed(msg)
    case 10: throw AAError.buildUserOpFailed(msg)
    case 11: throw AAError.hashUserOpFailed(msg)
    case 12: throw AAError.signUserOpFailed(msg)
    case 13: throw AAError.sendUserOpFailed(msg)
    case 14: throw AAError.estimateGasFailed(msg)
    case 15: throw AAError.paymasterFailed(msg)
    case 16: throw AAError.noCalls
    case 17: throw AAError.invalidHex
    case 18: throw AAError.applyJsonFailed(msg)
    case 19: throw AAError.serializeFailed(msg)
    case 20: throw AAError.noGasMiddleware
    case 21: throw AAError.noPaymasterMiddleware
    case 22: throw AAError.receiptTimeout(msg)
    case 23: throw AAError.receiptFailed(msg)
    case 24: throw AAError.invalidSigner(msg)
    default: throw AAError.unknown(code, msg)
    }
}
