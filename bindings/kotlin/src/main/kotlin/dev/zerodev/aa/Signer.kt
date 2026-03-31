package dev.zerodev.aa

import com.sun.jna.Pointer
import com.sun.jna.ptr.PointerByReference

class Signer private constructor(internal val ptr: Pointer) : AutoCloseable {
    private var closed = false

    companion object {
        fun local(privateKey: ByteArray): Signer {
            require(privateKey.size == 32) { "privateKey must be 32 bytes" }
            val ptrRef = PointerByReference()
            checkStatus(NativeLib.INSTANCE.aa_signer_local(privateKey, ptrRef))
            return Signer(ptrRef.value)
        }

        fun rpc(rpcUrl: String, address: ByteArray): Signer {
            require(address.size == 20) { "address must be 20 bytes" }
            val ptrRef = PointerByReference()
            checkStatus(NativeLib.INSTANCE.aa_signer_rpc(rpcUrl, address, ptrRef))
            return Signer(ptrRef.value)
        }
    }

    override fun close() {
        if (!closed) {
            NativeLib.INSTANCE.aa_signer_destroy(ptr)
            closed = true
        }
    }
}
