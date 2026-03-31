package dev.zerodev.aa

import com.sun.jna.Pointer
import com.sun.jna.ptr.PointerByReference

class Context private constructor(internal val ptr: Pointer) : AutoCloseable {
    private var closed = false

    companion object {
        fun create(
            projectId: String,
            rpcUrl: String = "",
            bundlerUrl: String = "",
            chainId: Long = 11155111,
            gasMiddleware: GasMiddleware = GasMiddleware.ZERODEV,
            paymasterMiddleware: PaymasterMiddleware = PaymasterMiddleware.ZERODEV,
        ): Context {
            val ptrRef = PointerByReference()
            checkStatus(NativeLib.INSTANCE.aa_context_create(projectId, rpcUrl, bundlerUrl, chainId, ptrRef))
            val ctx = ptrRef.value

            when (gasMiddleware) {
                GasMiddleware.ZERODEV -> {
                    checkStatus(
                        NativeLib.INSTANCE.aa_context_set_gas_middleware(ctx, NativeLib.getGasZerodevPtr()),
                    )
                }
            }

            when (paymasterMiddleware) {
                PaymasterMiddleware.ZERODEV -> {
                    checkStatus(
                        NativeLib.INSTANCE.aa_context_set_paymaster_middleware(ctx, NativeLib.getPaymasterZerodevPtr()),
                    )
                }
                PaymasterMiddleware.NONE -> { /* No paymaster — send unsponsored */ }
            }

            return Context(ctx)
        }
    }

    fun newAccount(
        signer: Signer,
        version: KernelVersion,
        index: Int = 0,
    ): Account {
        check(!closed) { "Context is closed" }
        val ptrRef = PointerByReference()
        checkStatus(NativeLib.INSTANCE.aa_account_create(ptr, signer.ptr, version.code, index, ptrRef))
        return Account(ptrRef.value, this)
    }

    override fun close() {
        if (!closed) {
            NativeLib.INSTANCE.aa_context_destroy(ptr)
            closed = true
        }
    }
}
