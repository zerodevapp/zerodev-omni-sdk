import dev.zerodev.aa.*

// ---------------------------------------------------------------------------
// Gasless Transfer Example (Sepolia)
//
// Sends a paymaster-sponsored UserOp that transfers 0 ETH to the smart
// account's own address.  The transaction costs the user zero gas because
// ZeroDev's paymaster covers the fee.
//
// Required environment variables:
//   ZERODEV_PROJECT_ID  — your ZeroDev project ID
//   PRIVATE_KEY         — 32-byte hex-encoded secp256k1 private key
//                         (with or without 0x prefix)
// ---------------------------------------------------------------------------

/** Decode a hex string (with optional 0x prefix) into a [ByteArray]. */
fun hexToBytes(hex: String): ByteArray {
    val stripped = hex.removePrefix("0x").removePrefix("0X")
    require(stripped.length % 2 == 0) { "Hex string must have an even number of characters" }
    return ByteArray(stripped.length / 2) {
        stripped.substring(it * 2, it * 2 + 2).toInt(16).toByte()
    }
}

fun main() {
    // 1. Read environment variables
    val projectId = System.getenv("ZERODEV_PROJECT_ID")
    if (projectId.isNullOrEmpty()) {
        System.err.println("Error: ZERODEV_PROJECT_ID environment variable is not set.")
        System.err.println("Usage: ZERODEV_PROJECT_ID=<id> PRIVATE_KEY=<hex> ./gradlew run")
        System.exit(1)
    }

    val pkHex = System.getenv("PRIVATE_KEY")
    if (pkHex.isNullOrEmpty()) {
        System.err.println("Error: PRIVATE_KEY environment variable is not set.")
        System.err.println("Usage: ZERODEV_PROJECT_ID=<id> PRIVATE_KEY=<hex> ./gradlew run")
        System.exit(1)
    }

    val privateKey = hexToBytes(pkHex)
    require(privateKey.size == 32) {
        "PRIVATE_KEY must be a 32-byte (64 hex character) value, got ${privateKey.size} bytes."
    }

    val chainId = 11155111L // Sepolia

    // 2. Create a context with ZeroDev gas + paymaster middleware on Sepolia
    println("Creating context (chain: Sepolia $chainId)...")
    Context.create(
        projectId = projectId,
        chainId = chainId,
        gasMiddleware = GasMiddleware.ZERODEV,
        paymasterMiddleware = PaymasterMiddleware.ZERODEV,
    ).use { ctx ->
        println("Context created.")

        // 3. Create a local signer from the private key
        Signer.local(privateKey).use { signer ->
            println("Signer created.")

            // 4. Create a Kernel v3.3 smart account
            ctx.newAccount(signer, KernelVersion.V3_3).use { account ->
                println("Account created.")

                // 5. Print the smart account address
                val address = account.getAddress()
                println("Smart account address: $address")

                // 6. Build a call: send 0 ETH to self (gasless noop)
                val calls = listOf(
                    Call(target = address, value = ByteArray(32), calldata = ByteArray(0)),
                )
                println("Sending gasless UserOp (0 ETH to self)...")

                // 7. Send the UserOp through the bundler
                val useropHash = account.sendUserOp(calls)
                println("UserOp submitted!")
                println("  UserOp hash: $useropHash")

                // 8. Wait for the UserOp to be included on-chain
                println("Waiting for on-chain receipt...")
                val receipt = account.waitForUserOperationReceipt(useropHash)

                // 9. Print receipt details
                println()
                println("=== UserOp Receipt ===")
                println("  Success:         ${receipt.success}")
                println("  UserOp hash:     ${receipt.userOpHash}")
                println("  Sender:          ${receipt.sender}")
                println("  Nonce:           ${receipt.nonce}")
                println("  Actual gas used: ${receipt.actualGasUsed}")
                println("  Actual gas cost: ${receipt.actualGasCost}")
                if (!receipt.paymaster.isNullOrEmpty()) {
                    println("  Paymaster:       ${receipt.paymaster}")
                }
                println("======================")

                if (receipt.success) {
                    println("\nGasless transfer completed successfully!")
                } else {
                    System.err.println("\nUserOp execution reverted.")
                    if (!receipt.reason.isNullOrEmpty()) {
                        System.err.println("Reason: ${receipt.reason}")
                    }
                    System.exit(1)
                }
            }
        }
    }
}
