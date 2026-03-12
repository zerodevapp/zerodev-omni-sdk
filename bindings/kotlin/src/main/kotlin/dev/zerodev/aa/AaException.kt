package dev.zerodev.aa

enum class AaStatus(val code: Int) {
    OK(0),
    NULL_OUT_PTR(1),
    INVALID_URL(2),
    OUT_OF_MEMORY(3),
    INVALID_PRIVATE_KEY(4),
    INVALID_KERNEL_VERSION(5),
    NULL_CONTEXT(6),
    NULL_ACCOUNT(7),
    NULL_USEROP(8),
    GET_ADDRESS_FAILED(9),
    BUILD_USEROP_FAILED(10),
    HASH_USEROP_FAILED(11),
    SIGN_USEROP_FAILED(12),
    SEND_USEROP_FAILED(13),
    ESTIMATE_GAS_FAILED(14),
    PAYMASTER_FAILED(15),
    NO_CALLS(16),
    INVALID_HEX(17),
    APPLY_JSON_FAILED(18),
    SERIALIZE_FAILED(19),
    NO_GAS_MIDDLEWARE(20),
    NO_PAYMASTER_MIDDLEWARE(21);

    companion object {
        fun fromCode(code: Int): AaStatus? = entries.find { it.code == code }
    }
}

class AaException(
    val status: AaStatus?,
    val detail: String?,
) : RuntimeException(buildMessage(status, detail)) {

    companion object {
        private fun buildMessage(status: AaStatus?, detail: String?): String {
            val statusPart = status?.name ?: "UNKNOWN"
            val codePart = status?.code?.toString() ?: "?"
            return if (!detail.isNullOrEmpty()) {
                "$statusPart (code $codePart): $detail"
            } else {
                "$statusPart (code $codePart)"
            }
        }
    }
}

internal fun checkStatus(code: Int) {
    if (code != 0) {
        val detail = NativeLib.INSTANCE.aa_get_last_error()
        val status = AaStatus.fromCode(code)
        throw AaException(status, detail)
    }
}
