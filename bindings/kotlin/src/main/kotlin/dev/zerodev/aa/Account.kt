package dev.zerodev.aa

class Account internal constructor(
    internal val ptr: Long,
    private val ctx: Context,
) : AutoCloseable {
    private var closed = false

    fun getAddress(): Address {
        check(!closed) { "Account is closed" }
        val addrBytes = ByteArray(20)
        checkStatus(NativeLib.nAccountGetAddress(ptr, addrBytes))
        return Address(addrBytes)
    }

    fun sendUserOp(calls: List<Call>): Hash {
        check(!closed) { "Account is closed" }
        require(calls.isNotEmpty()) { "calls must not be empty" }
        val (targets, values, calldatas) = marshalCalls(calls)
        val hashBytes = ByteArray(32)
        checkStatus(NativeLib.nSendUserOp(ptr, targets, values, calldatas, calls.size, hashBytes))
        return Hash(hashBytes)
    }

    fun waitForUserOperationReceipt(
        useropHash: Hash,
        timeoutMs: Int = 0,
        pollIntervalMs: Int = 0,
    ): UserOperationReceipt {
        check(!closed) { "Account is closed" }
        val json = NativeLib.nWaitForReceipt(ptr, useropHash.bytes, timeoutMs, pollIntervalMs)
        if (json == null) {
            val detail = NativeLib.nGetLastError()
            throw AaException(AaStatus.RECEIPT_FAILED, detail)
        }
        return UserOperationReceipt.fromJson(json)
    }

    fun buildUserOp(calls: List<Call>): UserOp {
        check(!closed) { "Account is closed" }
        require(calls.isNotEmpty()) { "calls must not be empty" }
        val (targets, values, calldatas) = marshalCalls(calls)
        val out = LongArray(1)
        checkStatus(NativeLib.nUserOpBuild(ptr, targets, values, calldatas, calls.size, out))
        return UserOp(out[0], this)
    }

    override fun close() {
        if (!closed) {
            NativeLib.nAccountDestroy(ptr)
            closed = true
        }
    }
}

private data class MarshaledCalls(
    val targets: ByteArray,
    val values: ByteArray,
    val calldatas: Array<ByteArray?>,
)

private fun marshalCalls(calls: List<Call>): MarshaledCalls {
    val targets = ByteArray(calls.size * 20)
    val values = ByteArray(calls.size * 32)
    val calldatas = Array<ByteArray?>(calls.size) { null }

    calls.forEachIndexed { i, call ->
        System.arraycopy(call.target.bytes, 0, targets, i * 20, 20)
        System.arraycopy(call.value, 0, values, i * 32, minOf(call.value.size, 32))
        if (call.calldata.isNotEmpty()) {
            calldatas[i] = call.calldata
        }
    }

    return MarshaledCalls(targets, values, calldatas)
}
