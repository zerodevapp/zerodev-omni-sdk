package dev.zerodev.aa

import com.sun.jna.Callback
import com.sun.jna.Library
import com.sun.jna.Native
import com.sun.jna.NativeLibrary
import com.sun.jna.NativeLong
import com.sun.jna.Pointer
import com.sun.jna.Structure
import com.sun.jna.ptr.NativeLongByReference
import com.sun.jna.ptr.PointerByReference

@Structure.FieldOrder("sign_hash", "sign_message", "sign_typed_data_hash", "get_address")
internal class AaSignerVtable : Structure() {
    @JvmField var sign_hash: Callback? = null
    @JvmField var sign_message: Callback? = null
    @JvmField var sign_typed_data_hash: Callback? = null
    @JvmField var get_address: Callback? = null
}

internal interface NativeLib : Library {
    companion object {
        val INSTANCE: NativeLib = Native.load("zerodev_aa", NativeLib::class.java)

        private val nativeLib: NativeLibrary = NativeLibrary.getInstance("zerodev_aa")

        fun getGasZerodevPtr(): Pointer = nativeLib.getFunction("aa_gas_zerodev")
        fun getPaymasterZerodevPtr(): Pointer = nativeLib.getFunction("aa_paymaster_zerodev")
    }

    fun aa_context_create(
        project_id: String,
        rpc_url: String,
        bundler_url: String,
        chain_id: Long,
        out: PointerByReference,
    ): Int

    fun aa_context_set_gas_middleware(ctx: Pointer, middleware: Pointer?): Int
    fun aa_context_set_paymaster_middleware(ctx: Pointer, middleware: Pointer?): Int
    fun aa_context_destroy(ctx: Pointer): Int

    fun aa_signer_generate(out: PointerByReference): Int
    fun aa_signer_local(private_key: ByteArray, out: PointerByReference): Int
    fun aa_signer_rpc(rpc_url: String, address: ByteArray, out: PointerByReference): Int
    fun aa_signer_custom(vtable: Pointer, ctx: Pointer?, out: PointerByReference): Int
    fun aa_signer_destroy(signer: Pointer)

    fun aa_account_create(
        ctx: Pointer,
        signer: Pointer,
        version: Int,
        index: Int,
        out: PointerByReference,
    ): Int

    fun aa_account_get_address(account: Pointer, addr_out: ByteArray): Int
    fun aa_account_destroy(account: Pointer): Int

    fun aa_send_userop(
        account: Pointer,
        calls: Pointer,
        calls_len: NativeLong,
        hash_out: ByteArray,
    ): Int

    fun aa_userop_build(
        account: Pointer,
        calls: Pointer,
        calls_len: NativeLong,
        out: PointerByReference,
    ): Int

    fun aa_userop_hash(op: Pointer, account: Pointer, hash_out: ByteArray): Int
    fun aa_userop_sign(op: Pointer, account: Pointer): Int
    fun aa_userop_to_json(op: Pointer, json_out: PointerByReference, len_out: NativeLongByReference): Int
    fun aa_userop_apply_gas_json(op: Pointer, gas_json: String, gas_json_len: NativeLong): Int
    fun aa_userop_apply_paymaster_json(op: Pointer, pm_json: String, pm_json_len: NativeLong): Int
    fun aa_userop_destroy(op: Pointer): Int

    fun aa_wait_for_user_operation_receipt(
        account: Pointer,
        userop_hash: ByteArray,
        timeout_ms: Int,
        poll_interval_ms: Int,
        json_out: PointerByReference,
        json_len_out: NativeLongByReference,
    ): Int

    fun aa_free(ptr: Pointer)
    fun aa_get_last_error(): String?
}
