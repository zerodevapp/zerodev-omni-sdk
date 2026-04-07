# ZeroDev Omni SDK

ERC-4337 smart account SDK written in Zig, designed for multi-language consumption via C FFI.

One Zig core → Go, Rust, Swift, Kotlin, Python, C.

## Install

**Swift (SPM) — no Zig required:**
```swift
.package(url: "https://github.com/zerodevapp/zerodev-omni-sdk.git", from: "0.0.1-alpha")
```

**Go, Rust, Kotlin, Python** — requires building from source. See [Getting Started](#getting-started-from-source).

## Quick Start

### Swift (iOS + macOS)

```swift
import ZeroDevAA

let ctx = try Context(projectID: projectID, chainID: 11155111, gasMiddleware: .zeroDev)
let signer = try Signer.local(privateKey: pk)
let account = try ctx.newAccount(signer: signer, version: .v3_3)

let hash = try await account.sendUserOp(calls: [Call(target: addr)])
let receipt = try await account.waitForUserOperationReceipt(useropHash: hash)
```

For Privy / WalletConnect (async wallet providers):
```swift
let signer = try Signer.async(myAsyncSignerImpl)  // AsyncSignerProtocol
```

> **Full example:** [omni-sdk-swift-example](https://github.com/zerodevapp/omni-sdk-swift-example) — SwiftUI app with Privy embedded wallet + gasless transactions

### Go

```go
ctx, _ := aa.NewContext(projectID, "", "", 11155111, aa.GasZeroDev, aa.PaymasterZeroDev)
defer ctx.Close()

signer, _ := aa.LocalSigner(privateKey)
defer signer.Close()

account, _ := ctx.NewAccount(signer, aa.KernelV3_3, 0)
defer account.Close()

hash, _ := account.SendUserOp([]aa.Call{{Target: recipientAddr}})
receipt, _ := account.WaitForUserOperationReceipt(hash, 0, 0)
```

### Rust

```rust
use zerodev_aa::{Context, Signer, KernelVersion, GasMiddleware, PaymasterMiddleware, Call};

let ctx = Context::new(project_id, "", "", 11155111, GasMiddleware::ZeroDev, PaymasterMiddleware::ZeroDev)?;
let signer = Signer::local(&private_key)?;
let account = ctx.new_account(&signer, KernelVersion::V3_3, 0)?;

let hash = account.send_user_op(&[Call { target: addr, value: [0u8; 32], calldata: vec![] }])?;
let receipt = account.wait_for_user_operation_receipt(&hash, 0, 0)?;
```

### Kotlin

```kotlin
Context.create(projectId, chainId = 11155111).use { ctx ->
    Signer.local(privateKey).use { signer ->
        ctx.newAccount(signer, KernelVersion.V3_3).use { account ->
            val hash = account.sendUserOp(listOf(Call(target = addr)))
            val receipt = account.waitForUserOperationReceipt(hash)
        }
    }
}
```

### Python

```python
from zerodev_aa import Context, Signer, Call, KernelVersion

with Context(project_id, chain_id=11155111) as ctx:
    with Signer.local(private_key) as signer:
        with ctx.new_account(signer, KernelVersion.V3_3) as account:
            hash = account.send_user_op([Call(target=account.get_address().bytes)])
            receipt = account.wait_for_receipt(hash)
```

### C

```c
#include "aa.h"

aa_context_t *ctx;
aa_context_create(project_id, "", "", 11155111, &ctx);
aa_context_set_gas_middleware(ctx, aa_gas_zerodev);
aa_context_set_paymaster_middleware(ctx, aa_paymaster_zerodev);

aa_signer_t *signer;
aa_signer_local(private_key, &signer);

aa_account_t *account;
aa_account_create(ctx, signer, AA_KERNEL_V3_3, 0, &account);

aa_call_t call = { .target = recipient, .value_be = {0} };
uint8_t hash[32];
aa_send_userop(account, &call, 1, hash);

aa_account_destroy(account);
aa_signer_destroy(signer);
aa_context_destroy(ctx);
```

## Signer Types

| Constructor | Use case |
|---|---|
| `Signer.local(privateKey)` | Local private key |
| `Signer.generate()` | Random key (zero-config demos) |
| `Signer.rpc(url, address)` | JSON-RPC endpoint (eth_sign) |
| `Signer.custom(impl)` | Custom signing (Privy, HSM, MPC) |
| `Signer.async(impl)` | Async signing — Swift only (iOS wallet providers) |

## Getting Started (from source)

For Go, Rust, Kotlin, Python — or if you want to build the Swift binding locally:

### Prerequisites

- [Zig 0.15+](https://ziglang.org/download/)
- macOS: `brew install secp256k1`
- A [ZeroDev](https://zerodev.app) project ID

### Build

```bash
git clone https://github.com/zerodevapp/zerodev-omni-sdk.git
cd zerodev-omni-sdk
make build
```

### Use as local dependency

**Go:**
```bash
go mod edit -require github.com/zerodevapp/zerodev-omni-sdk/bindings/go@v0.0.0
go mod edit -replace github.com/zerodevapp/zerodev-omni-sdk/bindings/go=/path/to/zerodev-omni-sdk/bindings/go
```

**Rust:**
```toml
[dependencies]
zerodev-aa = { path = "/path/to/zerodev-omni-sdk/bindings/rust" }
```

**Swift (local):**
```bash
make build-xcframework
```
```swift
.package(path: "/path/to/zerodev-omni-sdk/bindings/swift")
```

**Kotlin:**
```kotlin
// settings.gradle.kts
includeBuild("/path/to/zerodev-omni-sdk/bindings/kotlin") {
    dependencySubstitution {
        substitute(module("dev.zerodev:zerodev-aa")).using(project(":"))
    }
}
```

**Python:**
```bash
PYTHONPATH=/path/to/zerodev-omni-sdk/bindings/python
ZERODEV_SDK_ROOT=/path/to/zerodev-omni-sdk
```

### Examples

```bash
# Gasless transfer (Sepolia):
export ZERODEV_PROJECT_ID=your-project-id
cd examples/gasless-transfer/go && make run

# Privy signer:
export PRIVY_APP_ID=your-privy-app-id
export PRIVY_APP_SECRET=your-privy-app-secret
cd examples/privy-signer/go && make run
```

See [`examples/README.md`](examples/README.md) for all examples (Go, Rust, Swift, Kotlin, Python).

## Architecture

```
src/
├── core/           # AA primitives (kernel, userop, create2, bundler, paymaster, entrypoint)
├── transport/      # HTTP + JSON-RPC client (pluggable — host can inject URLSession/OkHttp)
├── signers/        # Signer interface (local, JSON-RPC, custom vtable)
├── validators/     # Validator plugins (ECDSA)
└── c_api.zig       # C FFI layer

bindings/
├── go/             # Go (cgo)
├── rust/           # Rust (auto Drop)
├── swift/          # Swift (SPM, xcframework, async/await)
├── kotlin/         # Kotlin (JNA, AutoCloseable)
└── python/         # Python (ctypes)
```

## Bindings

| Language | Package | iOS | Async | Custom Signer |
|----------|---------|-----|-------|---------------|
| Swift | [SPM](https://github.com/zerodevapp/zerodev-omni-sdk) | Yes | Yes (`async/await`) | `SignerProtocol` / `AsyncSignerProtocol` |
| Go | `bindings/go` | — | — | `SignerFuncs` |
| Rust | `bindings/rust` | — | — | `SignerImpl` trait |
| Kotlin | `bindings/kotlin` | Android TBD | — | `SignerImpl` interface |
| Python | `bindings/python` | — | — | `SignerImpl` protocol |
| C | `include/aa.h` | — | — | `aa_signer_vtable` |
