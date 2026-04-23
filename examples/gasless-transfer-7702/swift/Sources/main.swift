import Foundation
import ZeroDevAA

// ---------------------------------------------------------------------------
// Gasless Transfer via EIP-7702 Delegation (Sepolia)
//
// A fresh EOA is generated per run to demonstrate the delegation-install
// path: on the first UserOperation the SDK signs an authorization tuple
// `(chainId, Kernel implementation, EOA nonce)` and attaches it via the
// `eip7702Auth` field. After delegation is installed on-chain, subsequent
// UserOps skip the authorization.
//
// The account address IS the EOA — there is no CREATE2 deployment and no
// account-index parameter.
//
// Required environment variables:
//   ZERODEV_PROJECT_ID — your ZeroDev project ID (paymaster sponsors gas)
// ---------------------------------------------------------------------------

do {
    // 1. Read environment variables
    guard let projectID = ProcessInfo.processInfo.environment["ZERODEV_PROJECT_ID"],
          !projectID.isEmpty else {
        print("Error: ZERODEV_PROJECT_ID environment variable is not set.")
        print("Usage: ZERODEV_PROJECT_ID=<id> swift run GaslessTransfer7702")
        print("")
        print("A fresh EOA is generated per run to exercise the EIP-7702")
        print("delegation-install path. The paymaster sponsors gas.")
        exit(1)
    }

    print("=== Gasless Transfer via EIP-7702 Delegation (Sepolia) ===\n")

    // 2. Create a context with ZeroDev gas + paymaster middleware on Sepolia
    let chainID: UInt64 = 11155111 // Sepolia
    let ctx = try Context(
        projectID: projectID,
        chainID: chainID,
        gasMiddleware: .zeroDev,
        paymasterMiddleware: .zeroDev
    )
    print("Context created (chainId=\(chainID))")

    // 3. Generate a fresh EOA — highlights the delegation-install path.
    //    In production you'd use `Signer.local(privateKey:)` or
    //    `Signer.custom(_:)` / `Signer.async(_:)`.
    let signer = try Signer.generate()
    print("Fresh EOA generated (no on-chain history yet)")

    // 4. Create a 7702 Kernel v3.3 account — sender == EOA address.
    let account = try ctx.newAccount7702(signer: signer, version: .v3_3)
    let address = try account.getAddress()
    print("7702 account (EOA) address: \(address)\n")

    // 5. Build a call: send 0 ETH to self (gasless noop).
    let call = Call(target: address)

    print("Sending 0 ETH to self (gasless via paymaster, with EIP-7702 auth)...")

    // 6. Send UserOperation — the SDK signs + attaches the auth tuple.
    let useropHash = try account.sendUserOp(calls: [call])
    print("UserOp sent!")
    print("  UserOp hash: \(useropHash)\n")

    // 7. Wait for on-chain receipt.
    print("Waiting for on-chain confirmation (delegation installs on inclusion)...")
    let receipt = try account.waitForUserOperationReceipt(useropHash: useropHash)

    // 8. Print receipt details.
    print("")
    print("=== UserOperation Receipt ===")
    print("  Success:         \(receipt.success)")
    print("  UserOp hash:     \(receipt.userOpHash)")
    print("  Sender:          \(receipt.sender)")
    print("  Nonce:           \(receipt.nonce)")
    print("  Actual gas used: \(receipt.actualGasUsed)")
    print("  Actual gas cost: \(receipt.actualGasCost)")
    if let paymaster = receipt.paymaster, !paymaster.isEmpty {
        print("  Paymaster:       \(paymaster)")
    }
    if let txHash = receipt.receipt?["transactionHash"] as? String {
        print("  Tx hash:         \(txHash)")
    }
    print("=============================")

    if receipt.success {
        print("\nDone! The EOA is now delegated to the Kernel implementation.")
    } else {
        print("\n7702 UserOp execution reverted.")
        if let reason = receipt.reason {
            print("Reason: \(reason)")
        }
        exit(1)
    }

} catch {
    print("Error: \(error)")
    exit(1)
}
