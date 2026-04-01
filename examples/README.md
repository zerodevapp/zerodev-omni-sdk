# Examples

Real-world examples showing how to use the ZeroDev Omni SDK.

## Prerequisites

1. Build the SDK: `make build` (from repo root)
2. Set environment variables (or create a `.env` file in repo root)

## Gasless Transfer

Send a sponsored UserOp on Sepolia — the paymaster pays gas so the user doesn't.

**Required env vars:**
```
ZERODEV_PROJECT_ID=your-project-id
PRIVATE_KEY=your-hex-private-key
```

```bash
# Go
cd examples/gasless-transfer/go && go run .

# Rust
cd examples/gasless-transfer/rust && cargo run

# Swift
cd examples/gasless-transfer/swift && SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk swift run

# Kotlin
cd examples/gasless-transfer/kotlin && JAVA_HOME=/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home ./gradlew run
```

## Privy Signer

Use a Privy embedded wallet as a custom signer — the signing key lives in Privy's infrastructure.

**Required env vars:**
```
ZERODEV_PROJECT_ID=your-project-id
PRIVY_APP_ID=your-privy-app-id
PRIVY_APP_SECRET=your-privy-app-secret
PRIVY_WALLET_ID=your-privy-wallet-id
OWNER_ADDRESS=0x-prefixed-wallet-address
```

```bash
# Go
cd examples/privy-signer/go && go run .

# Rust
cd examples/privy-signer/rust && cargo run

# Swift
cd examples/privy-signer/swift && SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk swift run

# Kotlin
cd examples/privy-signer/kotlin && JAVA_HOME=/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home ./gradlew run
```

## How It Works

Both examples use the same SDK flow:

```
Signer (local key or Privy)
    |
    v
Context (RPC + middleware)
    |
    v
Account (Kernel v3.3 smart account)
    |
    v
SendUserOp (nonce -> gas -> paymaster -> sign -> send)
    |
    v
WaitForReceipt (poll bundler)
```

The only difference is how the `Signer` is created:
- **Gasless Transfer**: `Signer.local(privateKey)` — signs locally
- **Privy Signer**: `Signer.custom(privyAdapter)` — signs via Privy REST API
