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
    AA_SIGN_MESSAGE_FAILED = 25,
} aa_status;

/* ---- Kernel version enum ---- */

typedef enum {
    AA_KERNEL_V3_3 = 0,
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
 *
 * Allocator contract (audit F-02): `paymaster_data` MUST be allocated via
 * `aa_alloc` (or libc `malloc`) when the SDK is responsible for freeing.
 * If your runtime uses a different allocator (Go runtime, Rust global,
 * etc.), register a matching free callback via
 * `aa_context_set_paymaster_free_fn`. The built-in `aa_paymaster_zerodev`
 * uses libc allocation, so consumers using only it need no extra wiring.
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

/**
 * Optional companion to aa_paymaster_fn. If registered, the SDK calls this
 * to release `paymaster_data` instead of libc `free`. See aa_paymaster_fn
 * doc comment for the allocator contract.
 */
typedef void (*aa_paymaster_free_fn)(aa_context_t *ctx,
                                     uint8_t *paymaster_data,
                                     size_t paymaster_data_len);

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

/** Audit F-02: register a free function paired with the paymaster
 * middleware. Pass NULL to clear (the SDK then frees `paymaster_data` via
 * libc free — only safe when the middleware allocated via aa_alloc or
 * libc malloc, as the built-in aa_paymaster_zerodev does). */
aa_status aa_context_set_paymaster_free_fn(aa_context_t *ctx,
                                            aa_paymaster_free_fn free_fn);

/** Custom HTTP transport — lets host use URLSession (iOS), OkHttp, etc.
 *
 * Allocator contract (audit F-02): the response buffer placed in
 * *response_out MUST be allocated via `aa_alloc` (or libc `malloc`) for the
 * SDK to free it directly. Hosts using a different allocator MUST register
 * a matching free callback via `aa_context_set_http_free_fn`. Mixing — a
 * Go/Rust/Python-runtime pointer with no free fn registered — is undefined
 * behavior; on macOS the process aborts immediately. */
typedef int (*aa_http_fn)(void *ctx,
                           const char *url,
                           const char *body, size_t body_len,
                           char **response_out, size_t *response_len_out);

/** Optional companion to aa_http_fn. If registered, the SDK calls this to
 * release the response buffer instead of libc `free`. */
typedef void (*aa_http_free_fn)(void *ctx,
                                 uint8_t *response,
                                 size_t response_len);

aa_status aa_context_set_http_transport(aa_context_t *ctx,
                                         aa_http_fn transport,
                                         void *transport_ctx);

aa_status aa_context_set_http_free_fn(aa_context_t *ctx,
                                       aa_http_free_fn free_fn);

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

/* ---- EIP-7702 authorization ---- */

typedef struct {
    uint64_t chain_id;
    uint8_t address[20];
    uint64_t nonce;
    uint8_t y_parity;
    uint8_t r[32];
    uint8_t s[32];
} aa_authorization_t;

/** Create a custom signer from a vtable of function pointers.
 *
 * sign_authorization is OPTIONAL (may be NULL). When NULL, the SDK falls back
 * to computing keccak256(0x05 || rlp([chainId, address, nonce])) and calling
 * sign_hash.
 *
 * NOTE: This field was appended to the struct. Consumers MUST recompile against
 * this header before linking — the ABI is NOT compatible with code that was
 * built against the older 4-field vtable (the SDK reads past the old layout).
 * C99 zero-initialization (`aa_signer_vtable v = {.sign_hash = ...};`) covers
 * this field automatically at compile time, making the change source-compatible. */
typedef struct {
    int (*sign_hash)(void *ctx, const uint8_t hash[32], uint8_t sig_out[65]);
    int (*sign_message)(void *ctx, const uint8_t *msg, size_t msg_len, uint8_t sig_out[65]);
    int (*sign_typed_data_hash)(void *ctx, const uint8_t hash[32], uint8_t sig_out[65]);
    int (*get_address)(void *ctx, uint8_t addr_out[20]);
    int (*sign_authorization)(void *ctx, uint64_t chain_id, const uint8_t address[20],
                              uint64_t nonce, aa_authorization_t *out);
} aa_signer_vtable;

aa_status aa_signer_custom(const aa_signer_vtable *vtable,
                            void *ctx,
                            aa_signer_t **out);

/** Sign an EIP-7702 authorization tuple (chainId, delegation-target, EOA nonce).
 *
 * Works on any signer. Custom signers may implement this natively via their
 * vtable; otherwise the SDK computes keccak256(0x05 || rlp([chainId, address,
 * nonce])) and signs the hash with sign_hash. */
aa_status aa_signer_sign_authorization(aa_signer_t *signer,
                                        uint64_t chain_id,
                                        const uint8_t address[20],
                                        uint64_t nonce,
                                        aa_authorization_t *out);

/** Destroy a signer handle. */
void aa_signer_destroy(aa_signer_t *signer);

/* ---- Account (Kernel v3.x + ECDSA validator) ---- */

/** Create a Kernel smart account.
 *
 * `address` may be NULL, in which case the sender address is derived
 * counterfactually via CREATE2 from `(owner, index, version)` — the standard
 * flow. When non-NULL, it pins the account's sender to that address.
 *
 * This is the migration path for accounts whose original CREATE2 inputs
 * (older kernel version, factory salt) this SDK cannot reproduce — post-
 * upgrade the on-chain address is fixed but `(signer, version, index)` in
 * the new SDK derives a different one. The caller passes the correct
 * address; the SDK has nothing to cross-check against.
 *
 * Pinning affects the sender only. Factory init_code is still emitted on
 * the first UserOp exactly as it would be for a counterfactually-derived
 * account (governed by the EntryPoint nonce). Callers pinning an
 * already-deployed account whose EntryPoint nonce is still 0 (rare —
 * funded but never used) should drop the factory bytes via the low-level
 * UserOp API. */
aa_status aa_account_create(aa_context_t *ctx,
                            aa_signer_t *signer,
                            aa_kernel_version version,
                            uint32_t index,
                            const uint8_t address[20],
                            aa_account_t **out);

/** Create an EIP-7702 account. The account's address is the signer's EOA
 * address; there is no CREATE2, no init code, and no index parameter. On the
 * first UserOperation the SDK signs an authorization tuple (chainId, Kernel
 * implementation for `version`, EOA nonce) and attaches it via the
 * `eip7702Auth` field. Today only KERNEL_V3_3 supports EIP-7702. */
aa_status aa_context_new_account_7702(aa_context_t *ctx,
                                       aa_signer_t *signer,
                                       aa_kernel_version version,
                                       aa_account_t **out);

aa_status aa_account_get_address(aa_account_t *account,
                                 uint8_t addr_out[20]);

/* Sign a personal message on behalf of the smart account. Writes the 86-byte
 * ERC-1271 signature the account's own isValidSignature accepts: one validator
 * type byte, the 20-byte root validator address, and the owner's 65-byte
 * signature over the Kernel-domain wrap of the message's EIP-191 hash. */
#define AA_ERC1271_SIG_LEN 86
aa_status aa_account_sign_message(aa_account_t *account,
                                  const uint8_t *msg,
                                  size_t msg_len,
                                  uint8_t sig_out[AA_ERC1271_SIG_LEN]);

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

/** Allocate `size` bytes via libc `malloc`. Returns NULL on failure or
 * when `size` is 0. The matching free is `aa_free`.
 *
 * Audit F-02: prefer this over the host's native allocator when handing
 * buffers back to the SDK across FFI (HTTP responses, paymaster_data).
 * It guarantees the SDK can safely call libc `free` on the pointer on
 * every platform, since `aa_alloc` IS libc malloc. */
void *aa_alloc(size_t size);

void aa_free(void *ptr);

/* ---- Error details ---- */

const char *aa_get_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* AA_H */
