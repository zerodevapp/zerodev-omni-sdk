package dev.zerodev.aa

class Signer private constructor(
    internal val ptr: Long,
    private val customVtablePtr: Long = 0,
    private val customCtxPtr: Long = 0,
    internal var customImpl: Any? = null,
) : AutoCloseable {
    private var closed = false

    companion object {
        fun local(privateKey: ByteArray): Signer {
            require(privateKey.size == 32) { "privateKey must be 32 bytes" }
            val out = LongArray(1)
            checkStatus(NativeLib.nSignerLocal(privateKey, out))
            return Signer(out[0])
        }

        fun generate(): Signer {
            val out = LongArray(1)
            checkStatus(NativeLib.nSignerGenerate(out))
            return Signer(out[0])
        }

        fun rpc(rpcUrl: String, address: ByteArray): Signer {
            require(address.size == 20) { "address must be 20 bytes" }
            val out = LongArray(1)
            checkStatus(NativeLib.nSignerRpc(rpcUrl, address, out))
            return Signer(out[0])
        }

        fun custom(impl: SignerImpl): Signer {
            val out = LongArray(3) // [0]=signer, [1]=vtable, [2]=ctx
            checkStatus(NativeLib.nSignerCustom(impl, out))
            return Signer(
                ptr = out[0],
                customVtablePtr = out[1],
                customCtxPtr = out[2],
                customImpl = impl,
            )
        }
    }

    /**
     * Sign an EIP-7702 authorization tuple `(chainId, delegationTarget, nonce)`.
     *
     * Works on any signer. Custom signers that implement [SignerImpl.signAuthorization]
     * drive this natively; otherwise the SDK falls back to
     * `keccak256(0x05 || rlp([chainId, address, nonce]))` signed via `signHash`.
     */
    fun signAuthorization(chainId: Long, address: ByteArray, nonce: Long): Authorization {
        check(!closed) { "Signer is closed" }
        require(address.size == 20) { "address must be 20 bytes, got ${address.size}" }
        // Packed out: [y_parity(1) || r(32) || s(32) || chainId_be(8)]
        val buf = ByteArray(1 + 32 + 32 + 8)
        checkStatus(NativeLib.nSignerSignAuthorization(ptr, chainId, address, nonce, buf))

        val yParity = buf[0]
        val r = buf.copyOfRange(1, 33)
        val s = buf.copyOfRange(33, 65)
        // The JNI layer echoes the chainId so we can confirm it round-trips,
        // but the caller's chainId is authoritative — use it directly.
        return Authorization(
            chainId = chainId,
            address = address.copyOf(),
            nonce = nonce,
            yParity = yParity,
            r = r,
            s = s,
        )
    }

    override fun close() {
        if (!closed) {
            NativeLib.nSignerDestroy(ptr)
            if (customVtablePtr != 0L || customCtxPtr != 0L) {
                NativeLib.nSignerCustomCleanup(customVtablePtr, customCtxPtr)
            }
            closed = true
        }
    }
}
