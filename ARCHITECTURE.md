# Architecture

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Host Languages                           │
│                                                                 │
│   ┌────────┐  ┌────────┐  ┌─────────┐  ┌──────────┐           │
│   │   Go   │  │  Rust  │  │  Swift  │  │  Kotlin  │  ...      │
│   │  (cgo) │  │ (link) │  │  (SPM)  │  │  (JNA)   │           │
│   └───┬────┘  └───┬────┘  └────┬────┘  └────┬─────┘           │
│       │           │            │             │                  │
│       └───────────┴─────┬──────┴─────────────┘                  │
│                         │                                       │
│                    C FFI boundary                                │
│                         │                                       │
│              ┌──────────▼──────────┐                            │
│              │  include/aa.h       │                            │
│              │  (C API contract)   │                            │
│              └──────────┬──────────┘                            │
│                         │                                       │
│              ┌──────────▼──────────┐                            │
│              │  src/c_api.zig      │                            │
│              │  (FFI implementation)│                            │
│              └──────────┬──────────┘                            │
│                         │                                       │
│   ┌─────────────────────┼─────────────────────────┐            │
│   │                Zig Core                        │            │
│   │                                                │            │
│   │  ┌────────────┐ ┌──────────┐ ┌─────────────┐  │            │
│   │  │   core/    │ │transport/│ │ validators/ │  │            │
│   │  │  kernel    │ │  http    │ │   ecdsa     │  │            │
│   │  │  userop    │ │ json_rpc │ │  (plugin)   │  │            │
│   │  │  bundler   │ └──────────┘ └─────────────┘  │            │
│   │  │  paymaster │                                │            │
│   │  │  entrypoint│     ┌──────────────┐           │            │
│   │  │  create2   │     │    zigeth     │           │            │
│   │  └────────────┘     │  (primitives, │           │            │
│   │                     │   crypto,     │           │            │
│   │                     │   secp256k1)  │           │            │
│   │                     └──────────────┘           │            │
│   └────────────────────────────────────────────────┘            │
│                         │                                       │
│                    HTTP/JSON-RPC                                 │
│                         │                                       │
│          ┌──────────────▼───────────────┐                       │
│          │   ERC-4337 Infrastructure    │                       │
│          │  (Bundler, Paymaster, RPC)   │                       │
│          └──────────────────────────────┘                       │
└─────────────────────────────────────────────────────────────────┘
```

## Source Layout

```
src/
├── c_api.zig               # C FFI layer — all exported functions
├── root.zig                # Zig library root (re-exports modules)
├── core/
│   ├── root.zig            # Module index, KernelVersion enum, ZeroDev URLs
│   ├── kernel.zig          # ERC-7579 execute encoding (single + batch)
│   ├── userop.zig          # UserOp struct, ERC-4337 v0.7 hashing
│   ├── bundler.zig         # eth_estimateUserOperationGas
│   ├── paymaster.zig       # pm_getPaymasterStubData / pm_getPaymasterData
│   ├── entrypoint.zig      # EntryPoint v0.7 nonce queries (eth_call)
│   └── create2.zig         # CREATE2 counterfactual address derivation
├── transport/
│   ├── http.zig            # HTTP POST with gzip/chunked support
│   └── json_rpc.zig        # JSON-RPC client (request/response/error)
└── validators/
    ├── Validator.zig        # Validator vtable interface
    └── ecdsa.zig            # ECDSA signer (secp256k1 via zigeth)

include/
└── aa.h                    # C header — the FFI contract

bindings/
├── go/aa/                  # Go (cgo, static linking)
├── rust/                   # Rust (link via build.rs, auto Drop)
├── swift/                  # Swift (SPM, C module, deinit cleanup)
└── kotlin/                 # Kotlin (JNA, dynamic library, AutoCloseable)
```

## Handle Hierarchy

Three opaque handles with strict ownership:

```
aa_context_t                     Holds RPC URLs, chain ID, middleware fn ptrs
    │
    ├── aa_account_t             Holds private key, validator, kernel version
    │       │
    │       └── aa_userop_t      Holds a single in-flight UserOperation
    │
    └── (middleware fn ptrs)
            ├── aa_gas_price_fn       → gas pricing callback
            └── aa_paymaster_fn       → paymaster sponsorship callback
```

Each binding mirrors this with strong references to prevent use-after-free:
- **Go**: `defer ctx.Close()` / `defer account.Close()`
- **Rust**: `Drop` impls, Account borrows Context lifetime
- **Swift**: `deinit` + strong reference chain (Account → Context)
- **Kotlin**: `AutoCloseable` + `.use {}` blocks, Account holds Context ref

## UserOp Lifecycle

### High-Level (`aa_send_userop`)

One call does everything:

```
aa_send_userop(account, calls, n, hash_out)
        │
        ▼
  ┌─ Build UserOp ──────────────┐
  │  kernel.encodeExecute()     │   Encode calls as ERC-7579 execute calldata
  │  create2.getKernelAddress() │   Derive sender address
  │  entrypoint.getNonce()      │   Fetch nonce from EntryPoint
  └─────────────┬───────────────┘
                ▼
  ┌─ Gas Pricing ───────────────┐
  │  gas_middleware(ctx, &out)   │   e.g. zd_getUserOperationGasPrice
  └─────────────┬───────────────┘
                ▼
  ┌─ Paymaster (stub phase) ────┐
  │  pm_middleware(ctx, json,    │   pm_getPaymasterStubData
  │    entrypoint, chain,       │   → sets paymaster + stub gas limits
  │    AA_PM_STUB, &out)        │   (skipped if no paymaster set)
  └─────────────┬───────────────┘
                ▼
  ┌─ Gas Estimation ────────────┐
  │  eth_estimateUserOperationGas│  Bundler estimates gas limits
  └─────────────┬───────────────┘
                ▼
  ┌─ Paymaster (final phase) ───┐
  │  pm_middleware(ctx, json,    │   pm_getPaymasterData
  │    entrypoint, chain,       │   → sets final paymaster signature
  │    AA_PM_FINAL, &out)       │   (skipped if no paymaster set)
  └─────────────┬───────────────┘
                ▼
  ┌─ Sign ──────────────────────┐
  │  validator.sign(userOpHash) │   ECDSA secp256k1 signature
  └─────────────┬───────────────┘
                ▼
  ┌─ Send ──────────────────────┐
  │  eth_sendUserOperation      │   Submit to bundler
  │  → hash_out                 │   Returns UserOp hash
  └─────────────────────────────┘
```

### Low-Level (step-by-step)

For custom pipelines, each step is a separate C call:

```
aa_userop_build()                Build UserOp from calls
    │
aa_userop_to_json()              Serialize for off-chain processing
    │
aa_userop_apply_gas_json()       Apply gas estimates
aa_userop_apply_paymaster_json() Apply paymaster data
    │
aa_userop_hash()                 Compute ERC-4337 hash
aa_userop_sign()                 ECDSA sign
    │
(send via custom transport)
```

### Receipt Polling

```
aa_wait_for_user_operation_receipt(account, hash, timeout, interval, &json, &len)
        │
        ▼
  ┌─ Poll Loop ─────────────────┐
  │  while elapsed < timeout:   │
  │    eth_getUserOperationReceipt(hash)
  │    if result != null:       │
  │      return JSON string     │   Full ERC-4337 receipt as JSON
  │    sleep(interval)          │   (caller frees via aa_free)
  └─────────────────────────────┘
```

## Middleware System

Gas pricing and paymaster sponsorship are **independently pluggable** function pointers set on the context:

```c
// Function pointer types (set independently)
typedef aa_status (*aa_gas_price_fn)(aa_context_t *ctx, aa_gas_prices_t *out);
typedef aa_status (*aa_paymaster_fn)(aa_context_t *ctx, const char *userop_json,
                                     size_t len, const char *entry_point,
                                     uint64_t chain_id, aa_pm_phase phase,
                                     aa_paymaster_result_t *out);

// Built-in ZeroDev implementations
aa_gas_zerodev      → zd_getUserOperationGasPrice
aa_paymaster_zerodev → pm_getPaymasterStubData / pm_getPaymasterData
```

- **Gas middleware** is required — `aa_send_userop` returns `AA_NO_GAS_MIDDLEWARE` if not set.
- **Paymaster middleware** is optional — if not set, UserOps are sent unsponsored (user pays gas). The pipeline skips the paymaster stub/final steps.

Each binding exposes separate `GasMiddleware` and `PaymasterMiddleware` enums:

| Language | Sponsored | Unsponsored |
|----------|-----------|-------------|
| Go | `aa.GasZeroDev, aa.PaymasterZeroDev` | `aa.GasZeroDev, aa.PaymasterNone` |
| Rust | `GasMiddleware::ZeroDev, PaymasterMiddleware::ZeroDev` | `GasMiddleware::ZeroDev, PaymasterMiddleware::None` |
| Swift | `gasMiddleware: .zeroDev, paymasterMiddleware: .zeroDev` | `gasMiddleware: .zeroDev, paymasterMiddleware: .none` |
| Kotlin | `GasMiddleware.ZERODEV, PaymasterMiddleware.ZERODEV` | `GasMiddleware.ZERODEV, PaymasterMiddleware.NONE` |

## Binding Strategy

| Language | Linking     | Library Type | Cleanup Pattern        |
|----------|-------------|--------------|------------------------|
| Go       | cgo         | Static (`.a`)  | `defer .Close()`      |
| Rust     | build.rs    | Static (`.a`)  | `impl Drop`           |
| Swift    | SPM + C module | Static (`.a`) | `deinit`            |
| Kotlin   | JNA         | Dynamic (`.dylib`) | `AutoCloseable` + `.use {}` |

All bindings:
- Wrap opaque C pointers in language-idiomatic types
- Map `aa_status` codes to native error/exception types
- Marshal `aa_call_t` arrays for the call list
- Parse receipt JSON into typed structs matching [viem's `UserOperationReceipt`](https://viem.sh/account-abstraction/types#useroperationreceipt)

## Key Dependencies

- **zigeth** — Ethereum primitives (Address, Hash), crypto (keccak256, secp256k1), wallet signing
- **libsecp256k1** — ECDSA signing (linked via zigeth, installed via `brew install secp256k1` on macOS)
- **Zig std.http** — HTTP client with gzip decompression for JSON-RPC transport
