# zerodev-omni-sdk

ERC-4337 v0.7 smart account SDK written in Zig, designed for multi-language consumption via C FFI.

One Zig core, usable from Go, Rust, Swift, Kotlin, C, and anything else with C interop.

## Quick Start (Go)

```go
package main

import "github.com/zerodevapp/zerodev-omni-sdk/bindings/go/aa"

func main() {
    ctx, _ := aa.NewContext(projectID, "", "", 11155111, aa.ZeroDev)
    defer ctx.Close()

    account, _ := ctx.NewAccount(privateKey, aa.KernelV3_3, 0)
    defer account.Close()

    hash, _ := account.SendUserOp([]aa.Call{{
        Target:   recipientAddr,
        Value:    [32]byte{},
        Calldata: []byte{},
    }})
}
```

## Quick Start (Rust)

```rust
use zerodev_aa::{Context, KernelVersion, Middleware, Call};

let ctx = Context::new(project_id, "", "", 11155111, Middleware::ZeroDev)?;
let account = ctx.new_account(&private_key, KernelVersion::V3_3, 0)?;

let addr = account.get_address()?;
let hash = account.send_user_op(&[Call {
    target: addr,
    value: [0u8; 32],
    calldata: vec![],
}])?;
// Context and Account are automatically cleaned up on drop.
```

## Quick Start (Swift)

```swift
import ZeroDevAA

let ctx = try Context(projectID: projectID, chainID: 11155111, middleware: .zeroDev)
let account = try ctx.newAccount(privateKey: privateKey, version: .v3_3)

let addr = try account.getAddress()
let hash = try account.sendUserOp(calls: [
    Call(target: addr)
])
// Context and Account are automatically cleaned up via deinit.
```

## Quick Start (Kotlin)

```kotlin
import dev.zerodev.aa.*

Context.create(projectId, chainId = 11155111).use { ctx ->
    ctx.newAccount(privateKey, KernelVersion.V3_3).use { account ->
        val addr = account.getAddress()
        val hash = account.sendUserOp(listOf(
            Call(target = addr)
        ))
    }
}
// .use {} blocks ensure deterministic cleanup.
```

## Quick Start (C)

```c
#include "aa.h"

aa_context_t *ctx;
aa_context_create(project_id, "", "", 11155111, &ctx);
aa_context_set_gas_middleware(ctx, aa_gas_zerodev);
aa_context_set_paymaster_middleware(ctx, aa_paymaster_zerodev);

aa_account_t *account;
aa_account_create(ctx, private_key, AA_KERNEL_V3_3, 0, &account);

aa_call_t call = { .target = recipient, .value_be = {0} };
uint8_t hash[32];
aa_send_userop(account, &call, 1, hash);
```

## Architecture

```
src/
├── core/           # AA primitives (kernel, userop, create2, bundler, paymaster, entrypoint)
├── transport/      # HTTP + JSON-RPC client
├── validators/     # Validator plugin system (ECDSA, extensible)
└── c_api.zig       # C FFI layer with middleware pattern

include/aa.h        # C header

bindings/
├── go/             # Go wrapper
├── rust/           # Rust wrapper (lifetime-safe, auto Drop)
├── swift/          # Swift wrapper (SPM, deinit cleanup)
└── kotlin/         # Kotlin wrapper (JNA, AutoCloseable)
```

## Middleware

Gas pricing and paymaster sponsorship are pluggable function-pointer callbacks. Built-in implementations are provided for ZeroDev:

- `aa_gas_zerodev` — calls `zd_getUserOperationGasPrice`
- `aa_paymaster_zerodev` — calls `pm_getPaymasterStubData` / `pm_getPaymasterData`

Custom middleware can be implemented in any host language by matching the function signature.

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
