package dev.zerodev.aa

class UserOp internal constructor(
    private val ptr: Long,
    private val account: Account,
) : AutoCloseable {
    private var closed = false

    fun hash(): Hash {
        check(!closed) { "UserOp is closed" }
        val hashBytes = ByteArray(32)
        checkStatus(NativeLib.nUserOpHash(ptr, account.ptr, hashBytes))
        return Hash(hashBytes)
    }

    fun sign() {
        check(!closed) { "UserOp is closed" }
        checkStatus(NativeLib.nUserOpSign(ptr, account.ptr))
    }

    fun toJson(): String {
        check(!closed) { "UserOp is closed" }
        return NativeLib.nUserOpToJson(ptr)
            ?: throw AaException(AaStatus.SERIALIZE_FAILED, NativeLib.nGetLastError())
    }

    fun applyGasJson(gasJson: String) {
        check(!closed) { "UserOp is closed" }
        checkStatus(NativeLib.nUserOpApplyGasJson(ptr, gasJson))
    }

    fun applyPaymasterJson(pmJson: String) {
        check(!closed) { "UserOp is closed" }
        checkStatus(NativeLib.nUserOpApplyPaymasterJson(ptr, pmJson))
    }

    override fun close() {
        if (!closed) {
            NativeLib.nUserOpDestroy(ptr)
            closed = true
        }
    }
}
