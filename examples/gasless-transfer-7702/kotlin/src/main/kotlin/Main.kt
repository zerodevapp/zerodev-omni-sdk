import dev.zerodev.aa.*

// ---------------------------------------------------------------------------
// EIP-7702 Gasless Transfer Example (Sepolia)
//
// Demonstrates the 7702 flow: a fresh EOA is generated, then we call
// `newAccount7702` so the account address IS the EOA (no CREATE2, no init
// code). The first UserOp signs an authorization tuple delegating the EOA
// to the Kernel v3.3 implementation; subsequent ops skip re-authorization.
//
// The paymaster covers gas, so the freshly generated EOA needs zero balance.
//
// Required environment variables:
//   ZERODEV_PROJECT_ID  — your ZeroDev project ID
// ---------------------------------------------------------------------------

fun main() {
    // 1. Read environment variables
    val projectId = System.getenv("ZERODEV_PROJECT_ID")
    if (projectId.isNullOrEmpty()) {
        System.err.println("Error: ZERODEV_PROJECT_ID environment variable is not set.")
        System.err.println("Usage: ZERODEV_PROJECT_ID=<id> ./gradlew run")
        System.exit(1)
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

        // 3. Generate a fresh EOA. For EIP-7702 the smart account address
        //    IS the EOA address — no CREATE2 derivation, so this EOA does
        //    not need any pre-funding.
        Signer.generate().use { signer ->
            println("Signer generated (fresh EOA).")

            // 4. Create a Kernel v3.3 7702 account. Today only V3_3 is
            //    supported for 7702.
            ctx.newAccount7702(signer, KernelVersion.V3_3).use { account ->
                println("7702 account created.")

                // 5. Account address == EOA address (assert it for clarity).
                val address = account.getAddress()
                println("Smart account address (= EOA): $address")

                // 6. Build a call: send 0 ETH to self (gasless noop). On the
                //    first UserOp the SDK attaches an eip7702Auth tuple so
                //    the EOA is delegated to Kernel v3.3.
                val calls = listOf(
                    Call(target = address, value = ByteArray(32), calldata = ByteArray(0)),
                )
                println("Sending 7702 gasless UserOp (0 ETH to self)...")

                // 7. Send the UserOp through the bundler
                val useropHash = account.sendUserOp(calls)
                println("UserOp submitted!")
                println("  UserOp hash: $useropHash")

                // 8. Wait for the UserOp to be included on-chain
                println("Waiting for on-chain receipt...")
                val receipt = account.waitForUserOperationReceipt(useropHash)

                // 9. Print receipt details
                println()
                println("=== 7702 UserOp Receipt ===")
                println("  Success:         ${receipt.success}")
                println("  UserOp hash:     ${receipt.userOpHash}")
                println("  Sender:          ${receipt.sender}")
                println("  Nonce:           ${receipt.nonce}")
                println("  Actual gas used: ${receipt.actualGasUsed}")
                println("  Actual gas cost: ${receipt.actualGasCost}")
                if (!receipt.paymaster.isNullOrEmpty()) {
                    println("  Paymaster:       ${receipt.paymaster}")
                }
                println("===========================")

                if (receipt.success) {
                    println("\nEIP-7702 gasless transfer completed successfully!")
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
