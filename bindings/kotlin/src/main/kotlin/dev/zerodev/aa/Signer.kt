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
