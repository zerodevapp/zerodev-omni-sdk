# ZeroDev Omni SDK

ERC-4337 smart account SDK written in Zig, designed for multi-language consumption via C FFI.

One Zig core → Go, Rust, Swift, Kotlin, Python, C.

## Languages

- [Swift (iOS + macOS)](#swift-ios--macos)
- [Kotlin (Android + JVM)](#kotlin-android--jvm)
- [Go](#go)
- [Rust](#rust)
- [Python](#python)
- [C](#c)

## Swift (iOS + macOS)

### Install
```swift
.package(url: "https://github.com/zerodevapp/zerodev-omni-sdk.git", from: "0.0.1-alpha")
```

### Usage
```swift
import ZeroDevAA

let ctx = try Context(projectID: projectID, chainID: 11155111, gasMiddleware: .zeroDev)
let signer = try Signer.local(privateKey: pk)
let account = try ctx.newAccount(signer: signer, version: .v3_3)

let hash = try await account.sendUserOp(calls: [Call(target: addr)])
let receipt = try await account.waitForUserOperationReceipt(useropHash: hash)
```

### Custom Signers
```swift
// Privy / WalletConnect (async wallet providers)
let signer = try Signer.async(myAsyncSignerImpl)  // AsyncSignerProtocol
```

> **Full example:** [omni-sdk-swift-example](https://github.com/zerodevapp/omni-sdk-swift-example) — SwiftUI app with Privy embedded wallet + gasless transactions

---

## Kotlin (Android + JVM)

### Install
```kotlin
// Android
implementation("app.zerodev:zerodev-aa:0.0.1-alpha.5")

// Desktop JVM
implementation("app.zerodev:zerodev-aa-jvm:0.0.1-alpha.5")
```

### Usage
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

### Custom Signers
```kotlin
val signer = Signer.custom(object : SignerImpl {
    override fun signHash(hash: ByteArray) = // ...
    override fun signMessage(msg: ByteArray) = // ...
    override fun signTypedDataHash(hash: ByteArray) = // ...
    override fun getAddress() = // ...
})
```

> **Full example:** [omni-sdk-android-example](https://github.com/zerodevapp/omni-sdk-android-example) — Jetpack Compose app with Privy embedded wallet + gasless transactions

---

## Go

### Install
```bash
go get github.com/zerodevapp/zerodev-omni-sdk/bindings/go
```

### Usage
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

### Custom Signers
```go
signer, _ := aa.CustomSigner(aa.SignerFuncs{
    SignHash:           func(hash [32]byte) ([65]byte, error) { /* ... */ },
    SignMessage:        func(msg []byte) ([65]byte, error) { /* ... */ },
    SignTypedDataHash:  func(hash [32]byte) ([65]byte, error) { /* ... */ },
    GetAddress:         func() [20]byte { /* ... */ },
})
```

---

## Rust

### Install
```toml
[dependencies]
zerodev-aa = "0.0.1-alpha.1"
```

### Usage
```rust
use zerodev_aa::{Context, Signer, KernelVersion, GasMiddleware, PaymasterMiddleware, Call};

let ctx = Context::new(project_id, "", "", 11155111, GasMiddleware::ZeroDev, PaymasterMiddleware::ZeroDev)?;
let signer = Signer::local(&private_key)?;
let account = ctx.new_account(&signer, KernelVersion::V3_3, 0)?;

let hash = account.send_user_op(&[Call { target: addr, value: [0u8; 32], calldata: vec![] }])?;
let receipt = account.wait_for_user_operation_receipt(&hash, 0, 0)?;
```

### Custom Signers
```rust
let signer = Signer::custom(MySignerImpl)?;  // implements SignerImpl trait
```

---

## Python

### Install
```bash
pip install zerodev-aa
```

### Usage
```python
from zerodev_aa import Context, Signer, Call, KernelVersion

with Context(project_id, chain_id=11155111) as ctx:
    with Signer.local(private_key) as signer:
        with ctx.new_account(signer, KernelVersion.V3_3) as account:
            hash = account.send_user_op([Call(target=account.get_address().bytes)])
            receipt = account.wait_for_receipt(hash)
```

### Custom Signers
```python
class MySigner:
    def sign_hash(self, hash: bytes) -> bytes: ...
    def sign_message(self, msg: bytes) -> bytes: ...
    def sign_typed_data_hash(self, hash: bytes) -> bytes: ...
    def get_address(self) -> bytes: ...

signer = Signer.custom(MySigner())
```

---

## C

### Install
Build from source (see [Building from source](#building-from-source)).

### Usage
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

---

## Signer Types

All languages support the same signer types:

| Constructor | Use case |
|---|---|
| `Signer.local(privateKey)` | Local private key |
| `Signer.generate()` | Random key (zero-config demos) |
| `Signer.rpc(url, address)` | JSON-RPC endpoint (eth_sign) |
| `Signer.custom(impl)` | Custom signing (Privy, HSM, MPC) |
| `Signer.async(impl)` | Async signing — Swift only (iOS wallet providers) |

## Building from source

For C — or if you want to build any binding locally:

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

### Local dependency overrides

<details>
<summary>Go</summary>

```bash
go mod edit -require github.com/zerodevapp/zerodev-omni-sdk/bindings/go@v0.0.0
go mod edit -replace github.com/zerodevapp/zerodev-omni-sdk/bindings/go=/path/to/zerodev-omni-sdk/bindings/go
```
</details>

<details>
<summary>Rust</summary>

```toml
[dependencies]
zerodev-aa = { path = "/path/to/zerodev-omni-sdk/bindings/rust" }
```
</details>

<details>
<summary>Swift</summary>

```bash
make build-xcframework
```
```swift
.package(path: "/path/to/zerodev-omni-sdk/bindings/swift")
```
</details>

<details>
<summary>Kotlin</summary>

```kotlin
// settings.gradle.kts
includeBuild("/path/to/zerodev-omni-sdk/bindings/kotlin") {
    dependencySubstitution {
        substitute(module("app.zerodev:zerodev-aa")).using(project(":"))
    }
}
```
</details>

<details>
<summary>Python</summary>

```bash
PYTHONPATH=/path/to/zerodev-omni-sdk/bindings/python
ZERODEV_SDK_ROOT=/path/to/zerodev-omni-sdk
```
</details>

### Examples

```bash
export ZERODEV_PROJECT_ID=your-project-id
cd examples/gasless-transfer/go && make run
```

See [`examples/README.md`](examples/README.md) for all examples.

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
├── kotlin/         # Kotlin/Android (JNI, AutoCloseable)
└── python/         # Python (ctypes)
```

## Package Registry Links

| Language | Package | Platform |
|----------|---------|----------|
| Swift | [SPM](https://github.com/zerodevapp/zerodev-omni-sdk) | iOS + macOS |
| Kotlin | [Maven Central](https://central.sonatype.com/artifact/app.zerodev/zerodev-aa) | Android + JVM |
| Go | [Go module](https://pkg.go.dev/github.com/zerodevapp/zerodev-omni-sdk/bindings/go/aa) | All |
| Rust | [crates.io](https://crates.io/crates/zerodev-aa) | All |
| Python | [PyPI](https://pypi.org/project/zerodev-aa/) | macOS + Linux |
| C | `include/aa.h` | All |
