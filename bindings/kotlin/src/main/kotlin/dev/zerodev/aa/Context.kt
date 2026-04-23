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

    /**
     * Create an EIP-7702 account. The account address IS the signer's EOA —
     * no CREATE2, no init code, no index. On the first UserOp the SDK signs
     * an authorization tuple and attaches it via `eip7702Auth`; subsequent
     * ops reuse the delegation. Today only [KernelVersion.V3_3] supports 7702.
     */
    fun newAccount7702(
        signer: Signer,
        version: KernelVersion,
    ): Account {
        check(!closed) { "Context is closed" }
        val out = LongArray(1)
        checkStatus(NativeLib.nAccountCreate7702(ptr, signer.ptr, version.code, out))
        return Account(out[0], this)
    }

    override fun close() {
        if (!closed) {
            NativeLib.nContextDestroy(ptr)
            closed = true
        }
    }
}
