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
        Target: recipientAddr,
        Value:  [32]byte{},
    }})
}
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
└── go/             # Go wrapper
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
| Rust | Planned |
| Swift | Planned |
| Kotlin | Planned |
