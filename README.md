# zerodev-omni-sdk

ERC-4337 v0.7 smart account SDK written in Zig, designed for multi-language consumption via C FFI.

One Zig core, usable from Go, Rust, Swift, Kotlin, C, and anything else with C interop.

## Quick Start (Go)

```go
package main

import "github.com/zerodevapp/zerodev-omni-sdk/bindings/go/aa"

func main() {
    ctx, _ := aa.NewContext(projectID, "", "", 11155111, aa.GasZeroDev, aa.PaymasterZeroDev)
    defer ctx.Close()

    signer, _ := aa.LocalSigner(privateKey)       // or aa.RpcSigner(url, addr)
    defer signer.Close()

    account, _ := ctx.NewAccount(signer, aa.KernelV3_3, 0)
    defer account.Close()

    hash, _ := account.SendUserOp([]aa.Call{{Target: recipientAddr}})
    receipt, _ := account.WaitForUserOperationReceipt(hash, 0, 0)
    fmt.Println("success:", receipt.Success)
}
```

## Quick Start (Rust)

```rust
use zerodev_aa::{Context, Signer, KernelVersion, GasMiddleware, PaymasterMiddleware, Call};

let ctx = Context::new(project_id, "", "", 11155111, GasMiddleware::ZeroDev, PaymasterMiddleware::ZeroDev)?;
let signer = Signer::local(&private_key)?;         // or Signer::rpc(url, &addr)?
let account = ctx.new_account(&signer, KernelVersion::V3_3, 0)?;

let hash = account.send_user_op(&[Call { target: addr, value: [0u8; 32], calldata: vec![] }])?;
let receipt = account.wait_for_user_operation_receipt(&hash, 0, 0)?;
// Signer, Account, Context are automatically cleaned up on drop.
```

## Quick Start (Swift)

```swift
import ZeroDevAA

let ctx = try Context(projectID: projectID, chainID: 11155111, gasMiddleware: .zeroDev)
let signer = try Signer.local(privateKey: pk)       // or Signer.rpc(url: url, address: addr)
let account = try ctx.newAccount(signer: signer, version: .v3_3)

let hash = try account.sendUserOp(calls: [Call(target: addr)])
let receipt = try account.waitForUserOperationReceipt(useropHash: hash)
// Signer, Account, Context are automatically cleaned up via deinit.
```

## Quick Start (Kotlin)

```kotlin
import dev.zerodev.aa.*

Context.create(projectId, chainId = 11155111).use { ctx ->
    Signer.local(privateKey).use { signer ->          // or Signer.rpc(url, addr)
        ctx.newAccount(signer, KernelVersion.V3_3).use { account ->
            val hash = account.sendUserOp(listOf(Call(target = addr)))
            val receipt = account.waitForUserOperationReceipt(hash)
            println("success: ${receipt.success}")
        }
    }
}
```

## Quick Start (Python)

```python
from zerodev_aa import Context, Signer, Call, KernelVersion

with Context(project_id, chain_id=11155111) as ctx:
    with Signer.local(private_key) as signer:           # or Signer.generate(), Signer.rpc(url, addr)
        with ctx.new_account(signer, KernelVersion.V3_3) as account:
            hash = account.send_user_op([Call(target=account.get_address().bytes)])
            receipt = account.wait_for_receipt(hash)
            print(f"success: {receipt['success']}")
```

## Quick Start (C)

```c
#include "aa.h"

aa_context_t *ctx;
aa_context_create(project_id, "", "", 11155111, &ctx);
aa_context_set_gas_middleware(ctx, aa_gas_zerodev);
aa_context_set_paymaster_middleware(ctx, aa_paymaster_zerodev);

aa_signer_t *signer;
aa_signer_local(private_key, &signer);              // or aa_signer_rpc(url, addr, &signer)

aa_account_t *account;
aa_account_create(ctx, signer, AA_KERNEL_V3_3, 0, &account);

aa_call_t call = { .target = recipient, .value_be = {0} };
uint8_t hash[32];
aa_send_userop(account, &call, 1, hash);

aa_account_destroy(account);
aa_signer_destroy(signer);
aa_context_destroy(ctx);
```

## Getting Started

### Prerequisites

- [Zig 0.15+](https://ziglang.org/download/)
- macOS: `brew install secp256k1`
- A [ZeroDev](https://zerodev.app) project ID

### 1. Clone and build

```bash
git clone https://github.com/zerodevapp/zerodev-omni-sdk.git
cd zerodev-omni-sdk
make build
```

### 2. Use in your project

**Go:**
```bash
# In your project directory:
go mod edit -require github.com/zerodevapp/zerodev-omni-sdk/bindings/go@v0.0.0
go mod edit -replace github.com/zerodevapp/zerodev-omni-sdk/bindings/go=/path/to/zerodev-omni-sdk/bindings/go
```

**Rust:**
```toml
# Cargo.toml
[dependencies]
zerodev-aa = { path = "/path/to/zerodev-omni-sdk/bindings/rust" }
```

**Swift:**
```swift
// Package.swift
.package(path: "/path/to/zerodev-omni-sdk/bindings/swift")
// Build with: ZERODEV_SDK_ROOT=/path/to/zerodev-omni-sdk swift build
```

**Kotlin:**
```kotlin
// settings.gradle.kts
includeBuild("/path/to/zerodev-omni-sdk/bindings/kotlin") {
    dependencySubstitution {
        substitute(module("dev.zerodev:zerodev-aa")).using(project(":"))
    }
}
// Run with: -Djna.library.path=/path/to/zerodev-omni-sdk/zig-out/lib
```

**Python:**
```bash
PYTHONPATH=/path/to/zerodev-omni-sdk/bindings/python
ZERODEV_SDK_ROOT=/path/to/zerodev-omni-sdk
pip install -e /path/to/zerodev-omni-sdk/bindings/python  # or just set PYTHONPATH
```

### 3. Run an example

```bash
# Gasless transfer (generates a random key, sends sponsored UserOp on Sepolia):
export ZERODEV_PROJECT_ID=your-project-id
cd examples/gasless-transfer/go && make run

# Privy signer (creates Privy wallet, signs via Privy SDK):
export PRIVY_APP_ID=your-privy-app-id
export PRIVY_APP_SECRET=your-privy-app-secret
cd examples/privy-signer/go && make run
```

See [`examples/README.md`](examples/README.md) for all 8 examples (2 use cases × 4 languages).

### Signer types

| Constructor | Use case |
|---|---|
| `Signer.local(privateKey)` | Local private key (dev/testing) |
| `Signer.generate()` | Random key (zero-config demos) |
| `Signer.rpc(url, address)` | JSON-RPC endpoint (eth_sign compatible) |
| `Signer.custom(impl)` | Any custom signing logic (Privy, HSM, MPC) |

## Architecture

```
src/
├── core/           # AA primitives (kernel, userop, create2, bundler, paymaster, entrypoint)
├── transport/      # HTTP + JSON-RPC client
├── signers/        # Signer interface (local private key, JSON-RPC for Privy/custodial)
├── validators/     # Validator plugin system (ECDSA, extensible)
└── c_api.zig       # C FFI layer with middleware pattern

include/aa.h        # C header

bindings/
├── go/             # Go wrapper (cgo)
├── rust/           # Rust wrapper (lifetime-safe, auto Drop)
├── swift/          # Swift wrapper (SPM, deinit cleanup)
├── kotlin/         # Kotlin wrapper (JNA, AutoCloseable)
└── python/         # Python wrapper (ctypes, context managers)
```

## Middleware

Gas pricing and paymaster sponsorship are **independently pluggable** function-pointer callbacks. Built-in implementations are provided for ZeroDev:

- **Gas** (`aa_gas_price_fn`): `aa_gas_zerodev` — calls `zd_getUserOperationGasPrice`
- **Paymaster** (`aa_paymaster_fn`): `aa_paymaster_zerodev` — calls `pm_getPaymasterStubData` / `pm_getPaymasterData`

Gas middleware is required. Paymaster middleware is optional — if not set, UserOps are sent unsponsored (user pays gas). Custom middleware can be implemented in any host language by matching the function signature.

## Build

Requires [Zig 0.15+](https://ziglang.org/download/) and `brew install secp256k1` on macOS.

```bash
make build          # Build static + dynamic libs (ReleaseFast)
make test           # Run unit tests
make test-e2e       # Local E2E (Anvil + Alto bundler)
make test-live      # Live Sepolia (Zig)
make test-go-live   # Live Sepolia (Go)
make build-rust     # Build Rust binding
make test-rust-live # Live Sepolia (Rust)
make build-swift    # Build Swift binding
make test-swift-live  # Live Sepolia (Swift)
make build-kotlin   # Build Kotlin binding
make test-kotlin-live # Live Sepolia (Kotlin)
```

Live tests require a `.env` file:

```
ZERODEV_PROJECT_ID=your-project-id
E2E_PRIVATE_KEY=your-hex-private-key
```

## Bindings Status

| Language | Status |
|----------|--------|
| Go | Done |
| Rust | Done |
| Swift | Done |
| Kotlin | Done |
| Python | Done |
