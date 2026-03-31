package dev.zerodev.aa

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement

@JvmInline
value class Address(val bytes: ByteArray) {
    init {
        require(bytes.size == 20) { "Address must be 20 bytes, got ${bytes.size}" }
    }

    fun toHex(): String = "0x" + bytes.joinToString("") { "%02x".format(it) }

    override fun toString(): String = toHex()

    companion object {
        fun fromHex(hex: String): Address {
            val stripped = hex.removePrefix("0x").removePrefix("0X")
            require(stripped.length == 40) { "Address hex must be 40 characters, got ${stripped.length}" }
            val bytes = ByteArray(20) { stripped.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
            return Address(bytes)
        }
    }
}

@JvmInline
value class Hash(val bytes: ByteArray) {
    init {
        require(bytes.size == 32) { "Hash must be 32 bytes, got ${bytes.size}" }
    }

    fun toHex(): String = "0x" + bytes.joinToString("") { "%02x".format(it) }

    val isZero: Boolean get() = bytes.all { it == 0.toByte() }

    override fun toString(): String = toHex()
}

enum class KernelVersion(val code: Int) {
    V3_1(0),
    V3_2(1),
    V3_3(2),
}

/** Gas pricing middleware provider. */
enum class GasMiddleware {
    /** ZeroDev: calls zd_getUserOperationGasPrice. */
    ZERODEV,
}

/** Paymaster sponsorship middleware provider. */
enum class PaymasterMiddleware {
    /** No paymaster — send unsponsored (user pays gas). */
    NONE,
    /** ZeroDev: calls pm_getPaymasterStubData / pm_getPaymasterData. */
    ZERODEV,
}

/**
 * Full receipt from eth_getUserOperationReceipt.
 * Matches the viem UserOperationReceipt type.
 */
@Serializable
data class UserOperationReceipt(
    /** Hash of the user operation. */
    val userOpHash: String = "",
    /** Entrypoint address. */
    val entryPoint: String = "",
    /** Sender address. */
    val sender: String = "",
    /** Anti-replay parameter (hex string). */
    val nonce: String = "",
    /** Paymaster address, if any. */
    val paymaster: String? = null,
    /** Actual gas cost (hex string). */
    val actualGasCost: String = "",
    /** Actual gas used (hex string). */
    val actualGasUsed: String = "",
    /** If the user operation execution was successful. */
    val success: Boolean = false,
    /** Revert reason, if unsuccessful. */
    val reason: String? = null,
    /** Logs emitted during execution. */
    val logs: List<JsonElement> = emptyList(),
    /** Transaction receipt of the user operation execution. */
    val receipt: JsonElement? = null,
) {
    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        fun fromJson(jsonStr: String): UserOperationReceipt =
            json.decodeFromString(serializer(), jsonStr)
    }
}

interface SignerImpl {
    fun signHash(hash: ByteArray): ByteArray
    fun signMessage(msg: ByteArray): ByteArray
    fun signTypedDataHash(hash: ByteArray): ByteArray
    fun getAddress(): ByteArray
}

data class Call(
    val target: Address,
    val value: ByteArray = ByteArray(32),
    val calldata: ByteArray = ByteArray(0),
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is Call) return false
        return target == other.target &&
            value.contentEquals(other.value) &&
            calldata.contentEquals(other.calldata)
    }

    override fun hashCode(): Int {
        var result = target.hashCode()
        result = 31 * result + value.contentHashCode()
        result = 31 * result + calldata.contentHashCode()
        return result
    }
}

