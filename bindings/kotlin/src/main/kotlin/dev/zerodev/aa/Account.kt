package dev.zerodev.aa

import com.sun.jna.Memory
import com.sun.jna.NativeLong
import com.sun.jna.Pointer
import com.sun.jna.ptr.NativeLongByReference
import com.sun.jna.ptr.PointerByReference

class Account internal constructor(
    internal val ptr: Pointer,
    private val ctx: Context,
) : AutoCloseable {
    private var closed = false

    fun getAddress(): Address {
        check(!closed) { "Account is closed" }
        val addrBytes = ByteArray(20)
        checkStatus(NativeLib.INSTANCE.aa_account_get_address(ptr, addrBytes))
        return Address(addrBytes)
    }

    fun sendUserOp(calls: List<Call>): Hash {
        check(!closed) { "Account is closed" }
        require(calls.isNotEmpty()) { "calls must not be empty" }
        val (callsPtr, callsLen, memories) = marshalCalls(calls)
        try {
            val hashBytes = ByteArray(32)
            checkStatus(NativeLib.INSTANCE.aa_send_userop(ptr, callsPtr, callsLen, hashBytes))
            return Hash(hashBytes)
        } finally {
            // memories will be GC'd, but we hold refs to prevent premature collection
            memories.size
        }
    }

    fun waitForUserOperationReceipt(useropHash: Hash, timeoutMs: Int = 0, pollIntervalMs: Int = 0): UserOperationReceipt {
        check(!closed) { "Account is closed" }
        val jsonPtrRef = PointerByReference()
        val jsonLenRef = NativeLongByReference()
        checkStatus(NativeLib.INSTANCE.aa_wait_for_user_operation_receipt(ptr, useropHash.bytes, timeoutMs, pollIntervalMs, jsonPtrRef, jsonLenRef))
        val jsonPtr = jsonPtrRef.value
        val jsonLen = jsonLenRef.value.toInt()
        val json = String(jsonPtr.getByteArray(0, jsonLen), Charsets.UTF_8)
        NativeLib.INSTANCE.aa_free(jsonPtr)
        return UserOperationReceipt.fromJson(json)
    }

    fun buildUserOp(calls: List<Call>): UserOp {
        check(!closed) { "Account is closed" }
        require(calls.isNotEmpty()) { "calls must not be empty" }
        val (callsPtr, callsLen, memories) = marshalCalls(calls)
        try {
            val ptrRef = PointerByReference()
            checkStatus(NativeLib.INSTANCE.aa_userop_build(ptr, callsPtr, callsLen, ptrRef))
            return UserOp(ptrRef.value, this)
        } finally {
            memories.size
        }
    }

    override fun close() {
        if (!closed) {
            NativeLib.INSTANCE.aa_account_destroy(ptr)
            closed = true
        }
    }
}

private data class MarshaledCalls(
    val pointer: Pointer,
    val length: NativeLong,
    val memories: List<Memory>,
)

private fun marshalCalls(calls: List<Call>): MarshaledCalls {
    val struct = AaCallStruct()
    @Suppress("UNCHECKED_CAST")
    val array = struct.toArray(calls.size) as Array<AaCallStruct>
    val memories = mutableListOf<Memory>()

    calls.forEachIndexed { i, call ->
        System.arraycopy(call.target.bytes, 0, array[i].target, 0, 20)
        System.arraycopy(call.value, 0, array[i].value_be, 0, minOf(call.value.size, 32))
        if (call.calldata.isNotEmpty()) {
            val mem = Memory(call.calldata.size.toLong())
            mem.write(0, call.calldata, 0, call.calldata.size)
            array[i].calldata = mem
            array[i].calldata_len = NativeLong(call.calldata.size.toLong())
            memories.add(mem)
        }
        array[i].write()
    }

    return MarshaledCalls(array[0].pointer, NativeLong(calls.size.toLong()), memories)
}
