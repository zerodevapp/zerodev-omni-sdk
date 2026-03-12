package dev.zerodev.aa

import com.sun.jna.NativeLong
import com.sun.jna.Pointer
import com.sun.jna.Structure

@Structure.FieldOrder("target", "value_be", "calldata", "calldata_len")
internal open class AaCallStruct : Structure() {
    @JvmField var target = ByteArray(20)
    @JvmField var value_be = ByteArray(32)
    @JvmField var calldata: Pointer? = null
    @JvmField var calldata_len = NativeLong(0)

    class ByReference : AaCallStruct(), Structure.ByReference
}
