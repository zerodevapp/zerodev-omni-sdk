/**
 * JNI bridge for zerodev-aa Kotlin SDK.
 * Thin wrappers around aa.h — each function maps 1:1 to a native method
 * in dev.zerodev.aa.NativeLib.
 */

#include <jni.h>
#include <string.h>
#include <stdlib.h>
#include "aa.h"

/* ---- Helper: safe string creation (handles non-Modified-UTF-8 bytes) ---- */

static jstring safeNewString(JNIEnv *env, const char *bytes, size_t len) {
    jbyteArray arr = (*env)->NewByteArray(env, (jsize)len);
    (*env)->SetByteArrayRegion(env, arr, 0, (jsize)len, (const jbyte *)bytes);

    jclass strClass = (*env)->FindClass(env, "java/lang/String");
    jmethodID ctor = (*env)->GetMethodID(env, strClass, "<init>", "([BLjava/lang/String;)V");
    jstring charset = (*env)->NewStringUTF(env, "UTF-8");

    jstring result = (jstring)(*env)->NewObject(env, strClass, ctor, arr, charset);
    (*env)->DeleteLocalRef(env, arr);
    (*env)->DeleteLocalRef(env, charset);
    (*env)->DeleteLocalRef(env, strClass);
    return result;
}

/* ---- Context ---- */

JNIEXPORT jint JNICALL Java_dev_zerodev_aa_NativeLib_nContextCreate(
    JNIEnv *env, jclass cls,
    jstring project_id, jstring rpc_url, jstring bundler_url,
    jlong chain_id, jlongArray out)
{
    const char *pid = (*env)->GetStringUTFChars(env, project_id, NULL);
    const char *rpc = (*env)->GetStringUTFChars(env, rpc_url, NULL);
    const char *bundler = (*env)->GetStringUTFChars(env, bundler_url, NULL);

    aa_context_t *ctx = NULL;
    jint status = (jint)aa_context_create(pid, rpc, bundler, (uint64_t)chain_id, &ctx);

    jlong ptr = (jlong)(intptr_t)ctx;
    (*env)->SetLongArrayRegion(env, out, 0, 1, &ptr);

    (*env)->ReleaseStringUTFChars(env, project_id, pid);
    (*env)->ReleaseStringUTFChars(env, rpc_url, rpc);
    (*env)->ReleaseStringUTFChars(env, bundler_url, bundler);
    return status;
}

JNIEXPORT jint JNICALL Java_dev_zerodev_aa_NativeLib_nContextSetGasZeroDev(
    JNIEnv *env, jclass cls, jlong ctx_ptr)
{
    return (jint)aa_context_set_gas_middleware(
        (aa_context_t *)(intptr_t)ctx_ptr, aa_gas_zerodev);
}

JNIEXPORT jint JNICALL Java_dev_zerodev_aa_NativeLib_nContextSetGasPimlico(
    JNIEnv *env, jclass cls, jlong ctx_ptr)
{
    return (jint)aa_context_set_gas_middleware(
        (aa_context_t *)(intptr_t)ctx_ptr, aa_gas_pimlico);
}

JNIEXPORT jint JNICALL Java_dev_zerodev_aa_NativeLib_nContextSetPaymasterZeroDev(
    JNIEnv *env, jclass cls, jlong ctx_ptr)
{
    return (jint)aa_context_set_paymaster_middleware(
        (aa_context_t *)(intptr_t)ctx_ptr, aa_paymaster_zerodev);
}

JNIEXPORT jint JNICALL Java_dev_zerodev_aa_NativeLib_nContextDestroy(
    JNIEnv *env, jclass cls, jlong ctx_ptr)
{
    return (jint)aa_context_destroy((aa_context_t *)(intptr_t)ctx_ptr);
}

/* ---- Signer ---- */

JNIEXPORT jint JNICALL Java_dev_zerodev_aa_NativeLib_nSignerLocal(
    JNIEnv *env, jclass cls, jbyteArray private_key, jlongArray out)
{
    uint8_t key[32];
    (*env)->GetByteArrayRegion(env, private_key, 0, 32, (jbyte *)key);

    aa_signer_t *signer = NULL;
    jint status = (jint)aa_signer_local(key, &signer);

    jlong ptr = (jlong)(intptr_t)signer;
    (*env)->SetLongArrayRegion(env, out, 0, 1, &ptr);
    return status;
}

JNIEXPORT jint JNICALL Java_dev_zerodev_aa_NativeLib_nSignerGenerate(
    JNIEnv *env, jclass cls, jlongArray out)
{
    aa_signer_t *signer = NULL;
    jint status = (jint)aa_signer_generate(&signer);

    jlong ptr = (jlong)(intptr_t)signer;
    (*env)->SetLongArrayRegion(env, out, 0, 1, &ptr);
    return status;
}

JNIEXPORT jint JNICALL Java_dev_zerodev_aa_NativeLib_nSignerRpc(
    JNIEnv *env, jclass cls, jstring rpc_url, jbyteArray address, jlongArray out)
{
    const char *url = (*env)->GetStringUTFChars(env, rpc_url, NULL);
    uint8_t addr[20];
    (*env)->GetByteArrayRegion(env, address, 0, 20, (jbyte *)addr);

    aa_signer_t *signer = NULL;
    jint status = (jint)aa_signer_rpc(url, addr, &signer);

    jlong ptr = (jlong)(intptr_t)signer;
    (*env)->SetLongArrayRegion(env, out, 0, 1, &ptr);

    (*env)->ReleaseStringUTFChars(env, rpc_url, url);
    return status;
}

/* ---- Custom signer (callbacks from C into Java) ---- */

typedef struct {
    JavaVM *jvm;
    jobject signer_ref;  /* Global ref to SignerImpl */
    jmethodID sign_hash_mid;
    jmethodID sign_message_mid;
    jmethodID sign_typed_data_hash_mid;
    jmethodID get_address_mid;
    jmethodID sign_authorization_mid;  /* Optional — may be NULL if not overridden */
} jni_signer_ctx;

static JNIEnv *get_env(jni_signer_ctx *ctx) {
    JNIEnv *env;
    (*ctx->jvm)->AttachCurrentThread(ctx->jvm, (void **)&env, NULL);
    return env;
}

static int jni_sign_hash(void *raw_ctx, const uint8_t hash[32], uint8_t sig_out[65]) {
    jni_signer_ctx *ctx = (jni_signer_ctx *)raw_ctx;
    JNIEnv *env = get_env(ctx);

    jbyteArray jhash = (*env)->NewByteArray(env, 32);
    (*env)->SetByteArrayRegion(env, jhash, 0, 32, (const jbyte *)hash);

    jbyteArray result = (jbyteArray)(*env)->CallObjectMethod(env, ctx->signer_ref, ctx->sign_hash_mid, jhash);
    (*env)->DeleteLocalRef(env, jhash);

    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return 1; }
    if (result == NULL || (*env)->GetArrayLength(env, result) != 65) return 1;

    (*env)->GetByteArrayRegion(env, result, 0, 65, (jbyte *)sig_out);
    (*env)->DeleteLocalRef(env, result);
    return 0;
}

static int jni_sign_message(void *raw_ctx, const uint8_t *msg, size_t msg_len, uint8_t sig_out[65]) {
    jni_signer_ctx *ctx = (jni_signer_ctx *)raw_ctx;
    JNIEnv *env = get_env(ctx);

    jbyteArray jmsg = (*env)->NewByteArray(env, (jsize)msg_len);
    (*env)->SetByteArrayRegion(env, jmsg, 0, (jsize)msg_len, (const jbyte *)msg);

    jbyteArray result = (jbyteArray)(*env)->CallObjectMethod(env, ctx->signer_ref, ctx->sign_message_mid, jmsg);
    (*env)->DeleteLocalRef(env, jmsg);

    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return 1; }
    if (result == NULL || (*env)->GetArrayLength(env, result) != 65) return 1;

    (*env)->GetByteArrayRegion(env, result, 0, 65, (jbyte *)sig_out);
    (*env)->DeleteLocalRef(env, result);
    return 0;
}

static int jni_sign_typed_data_hash(void *raw_ctx, const uint8_t hash[32], uint8_t sig_out[65]) {
    jni_signer_ctx *ctx = (jni_signer_ctx *)raw_ctx;
    JNIEnv *env = get_env(ctx);

    jbyteArray jhash = (*env)->NewByteArray(env, 32);
    (*env)->SetByteArrayRegion(env, jhash, 0, 32, (const jbyte *)hash);

    jbyteArray result = (jbyteArray)(*env)->CallObjectMethod(env, ctx->signer_ref, ctx->sign_typed_data_hash_mid, jhash);
    (*env)->DeleteLocalRef(env, jhash);

    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return 1; }
    if (result == NULL || (*env)->GetArrayLength(env, result) != 65) return 1;

    (*env)->GetByteArrayRegion(env, result, 0, 65, (jbyte *)sig_out);
    (*env)->DeleteLocalRef(env, result);
    return 0;
}

static int jni_get_address(void *raw_ctx, uint8_t addr_out[20]) {
    jni_signer_ctx *ctx = (jni_signer_ctx *)raw_ctx;
    JNIEnv *env = get_env(ctx);

    jbyteArray result = (jbyteArray)(*env)->CallObjectMethod(env, ctx->signer_ref, ctx->get_address_mid);

    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return 1; }
    if (result == NULL || (*env)->GetArrayLength(env, result) != 20) return 1;

    (*env)->GetByteArrayRegion(env, result, 0, 20, (jbyte *)addr_out);
    (*env)->DeleteLocalRef(env, result);
    return 0;
}

/* Bridge Kotlin's Authorization return value into the aa_authorization_t
 * out-param. Return 1 to signal "fall back" (either null return or exception);
 * the SDK will then compute keccak256(0x05 || rlp(...)) + sign_hash itself. */
static int jni_sign_authorization(void *raw_ctx, uint64_t chain_id, const uint8_t address[20],
                                   uint64_t nonce, aa_authorization_t *out) {
    jni_signer_ctx *ctx = (jni_signer_ctx *)raw_ctx;
    JNIEnv *env = get_env(ctx);

    jbyteArray jaddr = (*env)->NewByteArray(env, 20);
    (*env)->SetByteArrayRegion(env, jaddr, 0, 20, (const jbyte *)address);

    jobject result = (*env)->CallObjectMethod(
        env, ctx->signer_ref, ctx->sign_authorization_mid,
        (jlong)chain_id, jaddr, (jlong)nonce);
    (*env)->DeleteLocalRef(env, jaddr);

    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return 1; }
    if (result == NULL) return 1;  /* caller returned null -> fall back */

    /* Extract fields from Kotlin Authorization data class via reflection. */
    jclass authCls = (*env)->GetObjectClass(env, result);
    jmethodID get_chain_id = (*env)->GetMethodID(env, authCls, "getChainId", "()J");
    jmethodID get_address = (*env)->GetMethodID(env, authCls, "getAddress", "()[B");
    jmethodID get_nonce = (*env)->GetMethodID(env, authCls, "getNonce", "()J");
    jmethodID get_y_parity = (*env)->GetMethodID(env, authCls, "getYParity", "()B");
    jmethodID get_r = (*env)->GetMethodID(env, authCls, "getR", "()[B");
    jmethodID get_s = (*env)->GetMethodID(env, authCls, "getS", "()[B");

    out->chain_id = (uint64_t)(*env)->CallLongMethod(env, result, get_chain_id);
    out->nonce = (uint64_t)(*env)->CallLongMethod(env, result, get_nonce);
    out->y_parity = (uint8_t)(*env)->CallByteMethod(env, result, get_y_parity);

    jbyteArray addr_arr = (jbyteArray)(*env)->CallObjectMethod(env, result, get_address);
    if (addr_arr != NULL && (*env)->GetArrayLength(env, addr_arr) == 20) {
        (*env)->GetByteArrayRegion(env, addr_arr, 0, 20, (jbyte *)out->address);
        (*env)->DeleteLocalRef(env, addr_arr);
    }

    jbyteArray r_arr = (jbyteArray)(*env)->CallObjectMethod(env, result, get_r);
    if (r_arr != NULL && (*env)->GetArrayLength(env, r_arr) == 32) {
        (*env)->GetByteArrayRegion(env, r_arr, 0, 32, (jbyte *)out->r);
        (*env)->DeleteLocalRef(env, r_arr);
    }

    jbyteArray s_arr = (jbyteArray)(*env)->CallObjectMethod(env, result, get_s);
    if (s_arr != NULL && (*env)->GetArrayLength(env, s_arr) == 32) {
        (*env)->GetByteArrayRegion(env, s_arr, 0, 32, (jbyte *)out->s);
        (*env)->DeleteLocalRef(env, s_arr);
    }

    (*env)->DeleteLocalRef(env, authCls);
    (*env)->DeleteLocalRef(env, result);
    return 0;
}

JNIEXPORT jint JNICALL Java_dev_zerodev_aa_NativeLib_nSignerCustom(
    JNIEnv *env, jclass cls, jobject signer_impl, jlongArray out)
{
    jclass implCls = (*env)->GetObjectClass(env, signer_impl);

    jni_signer_ctx *ctx = (jni_signer_ctx *)malloc(sizeof(jni_signer_ctx));
    (*env)->GetJavaVM(env, &ctx->jvm);
    ctx->signer_ref = (*env)->NewGlobalRef(env, signer_impl);
    ctx->sign_hash_mid = (*env)->GetMethodID(env, implCls, "signHash", "([B)[B");
    ctx->sign_message_mid = (*env)->GetMethodID(env, implCls, "signMessage", "([B)[B");
    ctx->sign_typed_data_hash_mid = (*env)->GetMethodID(env, implCls, "signTypedDataHash", "([B)[B");
    ctx->get_address_mid = (*env)->GetMethodID(env, implCls, "getAddress", "()[B");
    ctx->sign_authorization_mid = (*env)->GetMethodID(env, implCls, "signAuthorization",
        "(J[BJ)Ldev/zerodev/aa/Authorization;");

    /* Check providesSignAuthorization — if false, leave vtable slot NULL so the
     * SDK handles EIP-7702 via keccak(0x05 || rlp) + sign_hash. */
    jmethodID provides_mid = (*env)->GetMethodID(env, implCls, "getProvidesSignAuthorization", "()Z");
    jboolean provides = JNI_FALSE;
    if (provides_mid != NULL) {
        provides = (*env)->CallBooleanMethod(env, signer_impl, provides_mid);
        if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); provides = JNI_FALSE; }
    }

    /* Static vtable — lives for the duration of the signer */
    aa_signer_vtable *vtable = (aa_signer_vtable *)malloc(sizeof(aa_signer_vtable));
    vtable->sign_hash = jni_sign_hash;
    vtable->sign_message = jni_sign_message;
    vtable->sign_typed_data_hash = jni_sign_typed_data_hash;
    vtable->get_address = jni_get_address;
    vtable->sign_authorization = provides == JNI_TRUE ? jni_sign_authorization : NULL;

    aa_signer_t *signer = NULL;
    jint status = (jint)aa_signer_custom(vtable, ctx, &signer);

    jlong ptr = (jlong)(intptr_t)signer;
    (*env)->SetLongArrayRegion(env, out, 0, 1, &ptr);

    /* Store vtable + ctx pointers so we can free them later */
    /* We pack them into out[1] and out[2] */
    jlong vtable_ptr = (jlong)(intptr_t)vtable;
    jlong ctx_long = (jlong)(intptr_t)ctx;
    (*env)->SetLongArrayRegion(env, out, 1, 1, &vtable_ptr);
    (*env)->SetLongArrayRegion(env, out, 2, 1, &ctx_long);

    return status;
}

JNIEXPORT void JNICALL Java_dev_zerodev_aa_NativeLib_nSignerDestroy(
    JNIEnv *env, jclass cls, jlong signer_ptr)
{
    aa_signer_destroy((aa_signer_t *)(intptr_t)signer_ptr);
}

JNIEXPORT void JNICALL Java_dev_zerodev_aa_NativeLib_nSignerCustomCleanup(
    JNIEnv *env, jclass cls, jlong vtable_ptr, jlong ctx_ptr)
{
    if (vtable_ptr != 0) free((void *)(intptr_t)vtable_ptr);
    if (ctx_ptr != 0) {
        jni_signer_ctx *ctx = (jni_signer_ctx *)(intptr_t)ctx_ptr;
        (*env)->DeleteGlobalRef(env, ctx->signer_ref);
        free(ctx);
    }
}

/* ---- Account ---- */

JNIEXPORT jint JNICALL Java_dev_zerodev_aa_NativeLib_nAccountCreate(
    JNIEnv *env, jclass cls,
    jlong ctx_ptr, jlong signer_ptr, jint version, jint index,
    jbyteArray address, jlongArray out)
{
    uint8_t addr[20];
    const uint8_t *addr_ptr = NULL;
    if (address != NULL) {
        (*env)->GetByteArrayRegion(env, address, 0, 20, (jbyte *)addr);
        addr_ptr = addr;
    }

    aa_account_t *account = NULL;
    jint status = (jint)aa_account_create(
        (aa_context_t *)(intptr_t)ctx_ptr,
        (aa_signer_t *)(intptr_t)signer_ptr,
        (aa_kernel_version)version,
        (uint32_t)index,
        addr_ptr,
        &account);

    jlong ptr = (jlong)(intptr_t)account;
    (*env)->SetLongArrayRegion(env, out, 0, 1, &ptr);
    return status;
}

JNIEXPORT jint JNICALL Java_dev_zerodev_aa_NativeLib_nAccountCreate7702(
    JNIEnv *env, jclass cls,
    jlong ctx_ptr, jlong signer_ptr, jint version, jlongArray out)
{
    aa_account_t *account = NULL;
    jint status = (jint)aa_context_new_account_7702(
        (aa_context_t *)(intptr_t)ctx_ptr,
        (aa_signer_t *)(intptr_t)signer_ptr,
        (aa_kernel_version)version,
        &account);

    jlong ptr = (jlong)(intptr_t)account;
    (*env)->SetLongArrayRegion(env, out, 0, 1, &ptr);
    return status;
}

/* Layout of out buffer: [y_parity(1) || r(32) || s(32) || chain_id_be(8)] = 73 bytes */
JNIEXPORT jint JNICALL Java_dev_zerodev_aa_NativeLib_nSignerSignAuthorization(
    JNIEnv *env, jclass cls,
    jlong signer_ptr, jlong chain_id, jbyteArray address, jlong nonce, jbyteArray auth_out)
{
    uint8_t addr[20];
    (*env)->GetByteArrayRegion(env, address, 0, 20, (jbyte *)addr);

    aa_authorization_t auth;
    jint status = (jint)aa_signer_sign_authorization(
        (aa_signer_t *)(intptr_t)signer_ptr,
        (uint64_t)chain_id, addr, (uint64_t)nonce, &auth);
    if (status != 0) return status;

    /* Pack: [y_parity(1) || r(32) || s(32) || chain_id_be(8)] */
    uint8_t buf[73];
    buf[0] = auth.y_parity;
    memcpy(buf + 1, auth.r, 32);
    memcpy(buf + 33, auth.s, 32);
    for (int i = 0; i < 8; i++) {
        buf[65 + i] = (uint8_t)((auth.chain_id >> (56 - 8 * i)) & 0xff);
    }
    (*env)->SetByteArrayRegion(env, auth_out, 0, 73, (jbyte *)buf);
    return 0;
}

JNIEXPORT jint JNICALL Java_dev_zerodev_aa_NativeLib_nAccountGetAddress(
    JNIEnv *env, jclass cls, jlong account_ptr, jbyteArray addr_out)
{
    uint8_t addr[20];
    jint status = (jint)aa_account_get_address(
        (aa_account_t *)(intptr_t)account_ptr, addr);
    (*env)->SetByteArrayRegion(env, addr_out, 0, 20, (jbyte *)addr);
    return status;
}

JNIEXPORT jint JNICALL Java_dev_zerodev_aa_NativeLib_nAccountDestroy(
    JNIEnv *env, jclass cls, jlong account_ptr)
{
    return (jint)aa_account_destroy((aa_account_t *)(intptr_t)account_ptr);
}

/* ---- SendUserOp ---- */

JNIEXPORT jint JNICALL Java_dev_zerodev_aa_NativeLib_nSendUserOp(
    JNIEnv *env, jclass cls,
    jlong account_ptr, jbyteArray targets, jbyteArray values,
    jobjectArray calldatas, jint calls_len, jbyteArray hash_out)
{
    aa_call_t *calls = (aa_call_t *)calloc((size_t)calls_len, sizeof(aa_call_t));
    jbyte *target_bytes = (*env)->GetByteArrayElements(env, targets, NULL);
    jbyte *value_bytes = (*env)->GetByteArrayElements(env, values, NULL);

    /* Temporary array to hold calldata refs */
    jbyte **cd_ptrs = (jbyte **)calloc((size_t)calls_len, sizeof(jbyte *));
    jbyteArray *cd_arrays = (jbyteArray *)calloc((size_t)calls_len, sizeof(jbyteArray));

    for (int i = 0; i < calls_len; i++) {
        memcpy((void *)calls[i].target, target_bytes + i * 20, 20);
        memcpy((void *)calls[i].value_be, value_bytes + i * 32, 32);

        cd_arrays[i] = (jbyteArray)(*env)->GetObjectArrayElement(env, calldatas, i);
        if (cd_arrays[i] != NULL) {
            jsize cd_len = (*env)->GetArrayLength(env, cd_arrays[i]);
            if (cd_len > 0) {
                cd_ptrs[i] = (*env)->GetByteArrayElements(env, cd_arrays[i], NULL);
                calls[i].calldata = (const uint8_t *)cd_ptrs[i];
                calls[i].calldata_len = (size_t)cd_len;
            }
        }
    }

    uint8_t hash[32];
    jint status = (jint)aa_send_userop(
        (aa_account_t *)(intptr_t)account_ptr, calls, (size_t)calls_len, hash);
    (*env)->SetByteArrayRegion(env, hash_out, 0, 32, (jbyte *)hash);

    /* Cleanup */
    for (int i = 0; i < calls_len; i++) {
        if (cd_ptrs[i] != NULL)
            (*env)->ReleaseByteArrayElements(env, cd_arrays[i], cd_ptrs[i], JNI_ABORT);
    }
    (*env)->ReleaseByteArrayElements(env, targets, target_bytes, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, values, value_bytes, JNI_ABORT);
    free(cd_ptrs);
    free(cd_arrays);
    free(calls);
    return status;
}

/* ---- UserOp (low-level) ---- */

JNIEXPORT jint JNICALL Java_dev_zerodev_aa_NativeLib_nUserOpBuild(
    JNIEnv *env, jclass cls,
    jlong account_ptr, jbyteArray targets, jbyteArray values,
    jobjectArray calldatas, jint calls_len, jlongArray out)
{
    aa_call_t *calls = (aa_call_t *)calloc((size_t)calls_len, sizeof(aa_call_t));
    jbyte *target_bytes = (*env)->GetByteArrayElements(env, targets, NULL);
    jbyte *value_bytes = (*env)->GetByteArrayElements(env, values, NULL);

    jbyte **cd_ptrs = (jbyte **)calloc((size_t)calls_len, sizeof(jbyte *));
    jbyteArray *cd_arrays = (jbyteArray *)calloc((size_t)calls_len, sizeof(jbyteArray));

    for (int i = 0; i < calls_len; i++) {
        memcpy((void *)calls[i].target, target_bytes + i * 20, 20);
        memcpy((void *)calls[i].value_be, value_bytes + i * 32, 32);

        cd_arrays[i] = (jbyteArray)(*env)->GetObjectArrayElement(env, calldatas, i);
        if (cd_arrays[i] != NULL) {
            jsize cd_len = (*env)->GetArrayLength(env, cd_arrays[i]);
            if (cd_len > 0) {
                cd_ptrs[i] = (*env)->GetByteArrayElements(env, cd_arrays[i], NULL);
                calls[i].calldata = (const uint8_t *)cd_ptrs[i];
                calls[i].calldata_len = (size_t)cd_len;
            }
        }
    }

    aa_userop_t *op = NULL;
    jint status = (jint)aa_userop_build(
        (aa_account_t *)(intptr_t)account_ptr, calls, (size_t)calls_len, &op);

    jlong ptr = (jlong)(intptr_t)op;
    (*env)->SetLongArrayRegion(env, out, 0, 1, &ptr);

    for (int i = 0; i < calls_len; i++) {
        if (cd_ptrs[i] != NULL)
            (*env)->ReleaseByteArrayElements(env, cd_arrays[i], cd_ptrs[i], JNI_ABORT);
    }
    (*env)->ReleaseByteArrayElements(env, targets, target_bytes, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, values, value_bytes, JNI_ABORT);
    free(cd_ptrs);
    free(cd_arrays);
    free(calls);
    return status;
}

JNIEXPORT jint JNICALL Java_dev_zerodev_aa_NativeLib_nUserOpHash(
    JNIEnv *env, jclass cls, jlong op_ptr, jlong account_ptr, jbyteArray hash_out)
{
    uint8_t hash[32];
    jint status = (jint)aa_userop_hash(
        (aa_userop_t *)(intptr_t)op_ptr,
        (aa_account_t *)(intptr_t)account_ptr, hash);
    (*env)->SetByteArrayRegion(env, hash_out, 0, 32, (jbyte *)hash);
    return status;
}

JNIEXPORT jint JNICALL Java_dev_zerodev_aa_NativeLib_nUserOpSign(
    JNIEnv *env, jclass cls, jlong op_ptr, jlong account_ptr)
{
    return (jint)aa_userop_sign(
        (aa_userop_t *)(intptr_t)op_ptr,
        (aa_account_t *)(intptr_t)account_ptr);
}

JNIEXPORT jstring JNICALL Java_dev_zerodev_aa_NativeLib_nUserOpToJson(
    JNIEnv *env, jclass cls, jlong op_ptr)
{
    char *json = NULL;
    size_t len = 0;
    jint status = (jint)aa_userop_to_json((aa_userop_t *)(intptr_t)op_ptr, &json, &len);
    if (status != 0 || json == NULL) return NULL;

    jstring result = safeNewString(env, json, len);
    aa_free(json);
    return result;
}

JNIEXPORT jint JNICALL Java_dev_zerodev_aa_NativeLib_nUserOpApplyGasJson(
    JNIEnv *env, jclass cls, jlong op_ptr, jstring gas_json)
{
    const char *json = (*env)->GetStringUTFChars(env, gas_json, NULL);
    jsize len = (*env)->GetStringUTFLength(env, gas_json);
    jint status = (jint)aa_userop_apply_gas_json(
        (aa_userop_t *)(intptr_t)op_ptr, json, (size_t)len);
    (*env)->ReleaseStringUTFChars(env, gas_json, json);
    return status;
}

JNIEXPORT jint JNICALL Java_dev_zerodev_aa_NativeLib_nUserOpApplyPaymasterJson(
    JNIEnv *env, jclass cls, jlong op_ptr, jstring pm_json)
{
    const char *json = (*env)->GetStringUTFChars(env, pm_json, NULL);
    jsize len = (*env)->GetStringUTFLength(env, pm_json);
    jint status = (jint)aa_userop_apply_paymaster_json(
        (aa_userop_t *)(intptr_t)op_ptr, json, (size_t)len);
    (*env)->ReleaseStringUTFChars(env, pm_json, json);
    return status;
}

JNIEXPORT jint JNICALL Java_dev_zerodev_aa_NativeLib_nUserOpDestroy(
    JNIEnv *env, jclass cls, jlong op_ptr)
{
    return (jint)aa_userop_destroy((aa_userop_t *)(intptr_t)op_ptr);
}

/* ---- Receipt ---- */

JNIEXPORT jstring JNICALL Java_dev_zerodev_aa_NativeLib_nWaitForReceipt(
    JNIEnv *env, jclass cls,
    jlong account_ptr, jbyteArray userop_hash,
    jint timeout_ms, jint poll_interval_ms)
{
    uint8_t hash[32];
    (*env)->GetByteArrayRegion(env, userop_hash, 0, 32, (jbyte *)hash);

    char *json = NULL;
    size_t json_len = 0;
    jint status = (jint)aa_wait_for_user_operation_receipt(
        (aa_account_t *)(intptr_t)account_ptr,
        hash, (uint32_t)timeout_ms, (uint32_t)poll_interval_ms,
        &json, &json_len);

    if (status != 0) {
        /* Throw with status code so Kotlin can map it */
        jclass excCls = (*env)->FindClass(env, "dev/zerodev/aa/AaException");
        if (excCls != NULL) {
            const char *err = aa_get_last_error();
            char msg[512];
            snprintf(msg, sizeof(msg), "status=%d detail=%s", status, err ? err : "");
            (*env)->ThrowNew(env, excCls, msg);
        }
        return NULL;
    }

    jstring result = safeNewString(env, json, json_len);
    aa_free(json);
    return result;
}

/* ---- Utility ---- */

JNIEXPORT jstring JNICALL Java_dev_zerodev_aa_NativeLib_nGetLastError(
    JNIEnv *env, jclass cls)
{
    const char *err = aa_get_last_error();
    if (err == NULL) return NULL;
    return safeNewString(env, err, strlen(err));
}
