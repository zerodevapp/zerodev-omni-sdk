package dev.zerodev.aa

class Context private constructor(internal val ptr: Long) : AutoCloseable {
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
            val out = LongArray(1)
            checkStatus(NativeLib.nContextCreate(projectId, rpcUrl, bundlerUrl, chainId, out))
            val ctx = out[0]

            when (gasMiddleware) {
                GasMiddleware.ZERODEV -> checkStatus(NativeLib.nContextSetGasZeroDev(ctx))
            }

            when (paymasterMiddleware) {
                PaymasterMiddleware.ZERODEV -> checkStatus(NativeLib.nContextSetPaymasterZeroDev(ctx))
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
        val out = LongArray(1)
        checkStatus(NativeLib.nAccountCreate(ptr, signer.ptr, version.code, index, out))
        return Account(out[0], this)
    }

    override fun close() {
        if (!closed) {
            NativeLib.nContextDestroy(ptr)
            closed = true
        }
    }
}
