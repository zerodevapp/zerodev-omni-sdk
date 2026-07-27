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

    /**
     * Create a Kernel smart account.
     *
     * When [address] is null (the default), the sender is derived
     * counterfactually via CREATE2 from `(signer, version, index)`. When
     * supplied as a 20-byte array, the account is pinned to that on-chain
     * address (migration path for kernel-version upgrades or legacy wallets
     * whose CREATE2 salt this SDK no longer computes). Pinned accounts are
     * assumed already-deployed; no factory init_code is emitted on the
     * first UserOp. The caller is trusted; the SDK does not verify that a
     * pinned [address] corresponds to [signer].
     */
    fun newAccount(
        signer: Signer,
        version: KernelVersion,
        index: Int = 0,
        address: ByteArray? = null,
    ): Account {
        check(!closed) { "Context is closed" }
        if (address != null) {
            require(address.size == 20) { "address must be 20 bytes, got ${address.size}" }
        }
        val out = LongArray(1)
        checkStatus(NativeLib.nAccountCreate(ptr, signer.ptr, version.code, index, address, out))
        return Account(out[0], this, signer)
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
        return Account(out[0], this, signer)
    }

    override fun close() {
        if (!closed) {
            NativeLib.nContextDestroy(ptr)
            closed = true
        }
    }
}
