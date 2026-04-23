package dev.zerodev.aa

/**
 * JNI declarations for the zerodev-aa native library.
 * All opaque handles (context, signer, account, userop) are passed as Long (native pointer).
 */
internal object NativeLib {
    init {
        NativeLoader.load()
    }

    /* ---- Context ---- */
    @JvmStatic external fun nContextCreate(
        projectId: String, rpcUrl: String, bundlerUrl: String,
        chainId: Long, out: LongArray,
    ): Int

    @JvmStatic external fun nContextSetGasZeroDev(ctxPtr: Long): Int
    @JvmStatic external fun nContextSetPaymasterZeroDev(ctxPtr: Long): Int
    @JvmStatic external fun nContextDestroy(ctxPtr: Long): Int

    /* ---- Signer ---- */
    @JvmStatic external fun nSignerLocal(privateKey: ByteArray, out: LongArray): Int
    @JvmStatic external fun nSignerGenerate(out: LongArray): Int
    @JvmStatic external fun nSignerRpc(rpcUrl: String, address: ByteArray, out: LongArray): Int
    @JvmStatic external fun nSignerCustom(signerImpl: Any, out: LongArray): Int
    @JvmStatic external fun nSignerDestroy(signerPtr: Long)
    @JvmStatic external fun nSignerCustomCleanup(vtablePtr: Long, ctxPtr: Long)

    /* ---- Account ---- */
    @JvmStatic external fun nAccountCreate(
        ctxPtr: Long, signerPtr: Long, version: Int, index: Int, out: LongArray,
    ): Int

    /**
     * Create an EIP-7702 account. Account address is the signer's EOA; no
     * CREATE2 / init code / index. Today only V3_3 supports 7702.
     */
    @JvmStatic external fun nAccountCreate7702(
        ctxPtr: Long, signerPtr: Long, version: Int, out: LongArray,
    ): Int

    @JvmStatic external fun nAccountGetAddress(accountPtr: Long, addrOut: ByteArray): Int
    @JvmStatic external fun nAccountDestroy(accountPtr: Long): Int

    /* ---- EIP-7702 authorization ---- */

    /**
     * Sign an EIP-7702 authorization tuple (chainId, delegation-target, nonce).
     * Works on any signer. Packs output into a 73-byte buffer laid out as:
     * `[y_parity(1) || r(32) || s(32) || chain_id_be(8)]` (nonce and address
     * are passthroughs from the caller's args).
     */
    @JvmStatic external fun nSignerSignAuthorization(
        signerPtr: Long, chainId: Long, address: ByteArray, nonce: Long, authOut: ByteArray,
    ): Int

    /* ---- SendUserOp ---- */
    @JvmStatic external fun nSendUserOp(
        accountPtr: Long, targets: ByteArray, values: ByteArray,
        calldatas: Array<ByteArray?>, callsLen: Int, hashOut: ByteArray,
    ): Int

    /* ---- UserOp (low-level) ---- */
    @JvmStatic external fun nUserOpBuild(
        accountPtr: Long, targets: ByteArray, values: ByteArray,
        calldatas: Array<ByteArray?>, callsLen: Int, out: LongArray,
    ): Int

    @JvmStatic external fun nUserOpHash(opPtr: Long, accountPtr: Long, hashOut: ByteArray): Int
    @JvmStatic external fun nUserOpSign(opPtr: Long, accountPtr: Long): Int
    @JvmStatic external fun nUserOpToJson(opPtr: Long): String?
    @JvmStatic external fun nUserOpApplyGasJson(opPtr: Long, gasJson: String): Int
    @JvmStatic external fun nUserOpApplyPaymasterJson(opPtr: Long, pmJson: String): Int
    @JvmStatic external fun nUserOpDestroy(opPtr: Long): Int

    /* ---- Receipt ---- */
    @JvmStatic external fun nWaitForReceipt(
        accountPtr: Long, useropHash: ByteArray, timeoutMs: Int, pollIntervalMs: Int,
    ): String?

    /* ---- Utility ---- */
    @JvmStatic external fun nGetLastError(): String?
}
