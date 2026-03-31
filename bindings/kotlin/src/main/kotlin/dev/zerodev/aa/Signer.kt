package dev.zerodev.aa

import com.sun.jna.Callback
import com.sun.jna.Pointer
import com.sun.jna.ptr.PointerByReference

private interface SignHashCallback : Callback {
    fun invoke(ctx: Pointer?, hash: Pointer?, sigOut: Pointer?): Int
}

private interface SignMessageCallback : Callback {
    fun invoke(ctx: Pointer?, msg: Pointer?, msgLen: Long, sigOut: Pointer?): Int
}

private interface SignTypedDataHashCallback : Callback {
    fun invoke(ctx: Pointer?, hash: Pointer?, sigOut: Pointer?): Int
}

private interface GetAddressCallback : Callback {
    fun invoke(ctx: Pointer?, addrOut: Pointer?): Int
}

class Signer private constructor(internal val ptr: Pointer) : AutoCloseable {
    private var closed = false
    internal var customImpl: Any? = null
    internal var customVtable: Any? = null

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

        fun custom(impl: SignerImpl): Signer {
            val vtable = AaSignerVtable()

            vtable.sign_hash = object : SignHashCallback {
                override fun invoke(ctx: Pointer?, hash: Pointer?, sigOut: Pointer?): Int {
                    if (hash == null || sigOut == null) return 1
                    return try {
                        val sig = impl.signHash(hash.getByteArray(0, 32))
                        if (sig.size != 65) return 1
                        sigOut.write(0, sig, 0, 65)
                        0
                    } catch (_: Exception) { 1 }
                }
            }

            vtable.sign_message = object : SignMessageCallback {
                override fun invoke(ctx: Pointer?, msg: Pointer?, msgLen: Long, sigOut: Pointer?): Int {
                    if (msg == null || sigOut == null) return 1
                    return try {
                        val sig = impl.signMessage(msg.getByteArray(0, msgLen.toInt()))
                        if (sig.size != 65) return 1
                        sigOut.write(0, sig, 0, 65)
                        0
                    } catch (_: Exception) { 1 }
                }
            }

            vtable.sign_typed_data_hash = object : SignTypedDataHashCallback {
                override fun invoke(ctx: Pointer?, hash: Pointer?, sigOut: Pointer?): Int {
                    if (hash == null || sigOut == null) return 1
                    return try {
                        val sig = impl.signTypedDataHash(hash.getByteArray(0, 32))
                        if (sig.size != 65) return 1
                        sigOut.write(0, sig, 0, 65)
                        0
                    } catch (_: Exception) { 1 }
                }
            }

            vtable.get_address = object : GetAddressCallback {
                override fun invoke(ctx: Pointer?, addrOut: Pointer?): Int {
                    if (addrOut == null) return 1
                    return try {
                        val addr = impl.getAddress()
                        if (addr.size != 20) return 1
                        addrOut.write(0, addr, 0, 20)
                        0
                    } catch (_: Exception) { 1 }
                }
            }

            vtable.write()
            val ptrRef = PointerByReference()
            checkStatus(NativeLib.INSTANCE.aa_signer_custom(vtable.pointer, null, ptrRef))
            val signer = Signer(ptrRef.value)
            signer.customImpl = impl
            signer.customVtable = vtable
            return signer
        }
    }

    override fun close() {
        if (!closed) {
            NativeLib.INSTANCE.aa_signer_destroy(ptr)
            closed = true
        }
    }
}
