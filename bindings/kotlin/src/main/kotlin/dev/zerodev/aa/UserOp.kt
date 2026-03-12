package dev.zerodev.aa

import com.sun.jna.NativeLong
import com.sun.jna.Pointer
import com.sun.jna.ptr.NativeLongByReference
import com.sun.jna.ptr.PointerByReference

class UserOp internal constructor(
    private val ptr: Pointer,
    private val account: Account,
) : AutoCloseable {
    private var closed = false

    fun hash(): Hash {
        check(!closed) { "UserOp is closed" }
        val hashBytes = ByteArray(32)
        checkStatus(NativeLib.INSTANCE.aa_userop_hash(ptr, account.ptr, hashBytes))
        return Hash(hashBytes)
    }

    fun sign() {
        check(!closed) { "UserOp is closed" }
        checkStatus(NativeLib.INSTANCE.aa_userop_sign(ptr, account.ptr))
    }

    fun toJson(): String {
        check(!closed) { "UserOp is closed" }
        val jsonOut = PointerByReference()
        val lenOut = NativeLongByReference()
        checkStatus(NativeLib.INSTANCE.aa_userop_to_json(ptr, jsonOut, lenOut))
        val jsonPtr = jsonOut.value
        val jsonLen = lenOut.value.toInt()
        val result = jsonPtr.getString(0).substring(0, jsonLen)
        NativeLib.INSTANCE.aa_free(jsonPtr)
        return result
    }

    fun applyGasJson(gasJson: String) {
        check(!closed) { "UserOp is closed" }
        checkStatus(
            NativeLib.INSTANCE.aa_userop_apply_gas_json(ptr, gasJson, NativeLong(gasJson.length.toLong())),
        )
    }

    fun applyPaymasterJson(pmJson: String) {
        check(!closed) { "UserOp is closed" }
        checkStatus(
            NativeLib.INSTANCE.aa_userop_apply_paymaster_json(ptr, pmJson, NativeLong(pmJson.length.toLong())),
        )
    }

    override fun close() {
        if (!closed) {
            NativeLib.INSTANCE.aa_userop_destroy(ptr)
            closed = true
        }
    }
}
