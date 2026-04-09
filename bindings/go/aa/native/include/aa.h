#ifndef AA_H
#define AA_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Status codes ---- */

typedef enum {
    AA_OK = 0,
    AA_NULL_OUT_PTR = 1,
    AA_INVALID_URL = 2,
    AA_OUT_OF_MEMORY = 3,
    AA_INVALID_PRIVATE_KEY = 4,
    AA_INVALID_KERNEL_VERSION = 5,
    AA_NULL_CONTEXT = 6,
    AA_NULL_ACCOUNT = 7,
    AA_NULL_USEROP = 8,
    AA_GET_ADDRESS_FAILED = 9,
    AA_BUILD_USEROP_FAILED = 10,
    AA_HASH_USEROP_FAILED = 11,
    AA_SIGN_USEROP_FAILED = 12,
    AA_SEND_USEROP_FAILED = 13,
    AA_ESTIMATE_GAS_FAILED = 14,
    AA_PAYMASTER_FAILED = 15,
    AA_NO_CALLS = 16,
    AA_INVALID_HEX = 17,
    AA_APPLY_JSON_FAILED = 18,
    AA_SERIALIZE_FAILED = 19,
    AA_NO_GAS_MIDDLEWARE = 20,
    AA_NO_PAYMASTER_MIDDLEWARE = 21,
    AA_RECEIPT_TIMEOUT = 22,
    AA_RECEIPT_FAILED = 23,
    AA_INVALID_SIGNER = 24,
} aa_status;

/* ---- Kernel version enum ---- */

typedef enum {
    AA_KERNEL_V3_1 = 0,
    AA_KERNEL_V3_2 = 1,
    AA_KERNEL_V3_3 = 2,
} aa_kernel_version;

/* ---- Opaque handles ---- */

typedef struct aa_context aa_context_t;
typedef struct aa_signer aa_signer_t;
typedef struct aa_account aa_account_t;
typedef struct aa_userop aa_userop_t;

/* ---- Call struct ---- */

typedef struct aa_call {
    const uint8_t target[20];
    const uint8_t value_be[32];    /* u256, big-endian */
    const uint8_t *calldata;
    size_t calldata_len;
} aa_call_t;

/* ---- Gas price middleware ---- */

typedef struct {
    uint64_t max_fee_per_gas;
    uint64_t max_priority_fee_per_gas;
} aa_gas_prices_t;

/**
 * Gas price middleware function pointer.
 * Called by aa_send_userop to fetch current gas prices.
 */
typedef aa_status (*aa_gas_price_fn)(aa_context_t *ctx, aa_gas_prices_t *out);

/* ---- Paymaster middleware ---- */

typedef enum {
    AA_PM_STUB = 0,     /* Before gas estimation */
    AA_PM_FINAL = 1,    /* After gas estimation */
} aa_pm_phase;

typedef struct {
    uint8_t paymaster[20];
    uint64_t paymaster_verification_gas_limit;
    uint64_t paymaster_post_op_gas_limit;
    uint8_t *paymaster_data;
    size_t paymaster_data_len;
} aa_paymaster_result_t;

/**
 * Paymaster middleware function pointer.
 * Called by aa_send_userop to sponsor UserOperations.
 * Receives UserOp JSON, entry point, chain ID, and phase.
 * paymaster_data in result is allocated by the middleware; freed by the caller.
 *
 * Optional: if not set, aa_send_userop sends unsponsored (user pays gas).
 */
typedef aa_status (*aa_paymaster_fn)(aa_context_t *ctx,
                                     const char *userop_json,
                                     size_t userop_json_len,
                                     const char *entry_point,
                                     uint64_t chain_id,
                                     aa_pm_phase phase,
                                     aa_paymaster_result_t *out);

/* ---- Context (holds RPC URLs, chain config) ---- */

aa_status aa_context_create(const char *project_id,
                            const char *rpc_url,
                            const char *bundler_url,
                            uint64_t chain_id,
                            aa_context_t **out);

aa_status aa_context_set_gas_middleware(aa_context_t *ctx,
                                        aa_gas_price_fn middleware);

aa_status aa_context_set_paymaster_middleware(aa_context_t *ctx,
                                              aa_paymaster_fn middleware);

/** Custom HTTP transport — lets host use URLSession (iOS), OkHttp, etc. */
typedef int (*aa_http_fn)(void *ctx,
                           const char *url,
                           const char *body, size_t body_len,
                           char **response_out, size_t *response_len_out);

aa_status aa_context_set_http_transport(aa_context_t *ctx,
                                         aa_http_fn transport,
                                         void *transport_ctx);

aa_status aa_context_destroy(aa_context_t *ctx);

/* ---- Built-in middleware ---- */

/** ZeroDev gas price middleware. Calls zd_getUserOperationGasPrice. */
aa_status aa_gas_zerodev(aa_context_t *ctx, aa_gas_prices_t *out);

/** ZeroDev paymaster middleware. Calls pm_getPaymasterStubData / pm_getPaymasterData. */
aa_status aa_paymaster_zerodev(aa_context_t *ctx,
                                const char *userop_json,
                                size_t userop_json_len,
                                const char *entry_point,
                                uint64_t chain_id,
                                aa_pm_phase phase,
                                aa_paymaster_result_t *out);

/* ---- Signer (create before account) ---- */

/** Create a local signer from a 32-byte private key. */
aa_status aa_signer_local(const uint8_t private_key[32],
                           aa_signer_t **out);

/** Create a local signer with a randomly generated private key. */
aa_status aa_signer_generate(aa_signer_t **out);

/** Create a JSON-RPC signer (Privy, custodial wallets, etc.). */
aa_status aa_signer_rpc(const char *rpc_url,
                         const uint8_t address[20],
                         aa_signer_t **out);

/** Create a custom signer from a vtable of function pointers. */
typedef struct {
    int (*sign_hash)(void *ctx, const uint8_t hash[32], uint8_t sig_out[65]);
    int (*sign_message)(void *ctx, const uint8_t *msg, size_t msg_len, uint8_t sig_out[65]);
    int (*sign_typed_data_hash)(void *ctx, const uint8_t hash[32], uint8_t sig_out[65]);
    int (*get_address)(void *ctx, uint8_t addr_out[20]);
} aa_signer_vtable;

aa_status aa_signer_custom(const aa_signer_vtable *vtable,
                            void *ctx,
                            aa_signer_t **out);

/** Destroy a signer handle. */
void aa_signer_destroy(aa_signer_t *signer);

/* ---- Account (Kernel v3.x + ECDSA validator) ---- */

aa_status aa_account_create(aa_context_t *ctx,
                            aa_signer_t *signer,
                            aa_kernel_version version,
                            uint32_t index,
                            aa_account_t **out);

aa_status aa_account_get_address(aa_account_t *account,
                                 uint8_t addr_out[20]);

aa_status aa_account_destroy(aa_account_t *account);

/* ---- High-level: full pipeline ---- */

aa_status aa_send_userop(aa_account_t *account,
                         const aa_call_t *calls,
                         size_t calls_len,
                         uint8_t hash_out[32]);

/* ---- Low-level: step-by-step UserOp control ---- */

aa_status aa_userop_build(aa_account_t *account,
                          const aa_call_t *calls,
                          size_t calls_len,
                          aa_userop_t **out);

aa_status aa_userop_hash(aa_userop_t *op,
                         aa_account_t *account,
                         uint8_t hash_out[32]);

aa_status aa_userop_sign(aa_userop_t *op,
                         aa_account_t *account);

aa_status aa_userop_to_json(aa_userop_t *op,
                            char **json_out,
                            size_t *len_out);

aa_status aa_userop_apply_gas_json(aa_userop_t *op,
                                   const char *gas_json,
                                   size_t gas_json_len);

aa_status aa_userop_apply_paymaster_json(aa_userop_t *op,
                                         const char *pm_json,
                                         size_t pm_json_len);

aa_status aa_userop_destroy(aa_userop_t *op);

/* ---- Receipt (poll for UserOp inclusion) ---- */

/**
 * Wait for a UserOp to be included on-chain, returning the full
 * eth_getUserOperationReceipt JSON response.
 *
 * Polls every poll_interval_ms, up to timeout_ms.
 * Pass 0 for timeout_ms to use default (60 seconds).
 * Pass 0 for poll_interval_ms to use default (2 seconds).
 *
 * On success, *json_out is a heap-allocated JSON string that the caller
 * must free with aa_free(). *json_len_out is set to the string length.
 *
 * The JSON response follows the ERC-4337 eth_getUserOperationReceipt schema:
 *   { userOpHash, entryPoint, sender, nonce, paymaster,
 *     actualGasCost, actualGasUsed, success, logs, receipt }
 */
aa_status aa_wait_for_user_operation_receipt(
    aa_account_t *account,
    const uint8_t userop_hash[32],
    uint32_t timeout_ms,
    uint32_t poll_interval_ms,
    char **json_out,
    size_t *json_len_out);

/* ---- Memory management ---- */

void aa_free(void *ptr);

/* ---- Error details ---- */

const char *aa_get_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* AA_H */
