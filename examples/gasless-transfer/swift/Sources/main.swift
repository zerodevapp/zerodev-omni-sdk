import Foundation
import ZeroDevAA

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

/// Decode a hex string (with optional 0x prefix) into raw bytes.
func hexStringToBytes(_ hex: String) -> [UInt8]? {
    var s = hex
    if s.hasPrefix("0x") || s.hasPrefix("0X") {
        s = String(s.dropFirst(2))
    }
    guard s.count % 2 == 0 else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(s.count / 2)
    var index = s.startIndex
    while index < s.endIndex {
        let nextIndex = s.index(index, offsetBy: 2)
        guard let byte = UInt8(s[index..<nextIndex], radix: 16) else {
            return nil
        }
        bytes.append(byte)
        index = nextIndex
    }
    return bytes
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

do {
    // 1. Read environment variables
    guard let projectID = ProcessInfo.processInfo.environment["ZERODEV_PROJECT_ID"],
          !projectID.isEmpty else {
        print("Error: ZERODEV_PROJECT_ID environment variable is not set.")
        print("Usage: ZERODEV_PROJECT_ID=<id> PRIVATE_KEY=<hex> swift run GaslessTransfer")
        exit(1)
    }

    guard let pkHex = ProcessInfo.processInfo.environment["PRIVATE_KEY"],
          !pkHex.isEmpty else {
        print("Error: PRIVATE_KEY environment variable is not set.")
        print("Usage: ZERODEV_PROJECT_ID=<id> PRIVATE_KEY=<hex> swift run GaslessTransfer")
        exit(1)
    }

    guard let privateKey = hexStringToBytes(pkHex), privateKey.count == 32 else {
        print("Error: PRIVATE_KEY must be a 32-byte (64 hex character) value.")
        exit(1)
    }

    let chainID: UInt64 = 11155111  // Sepolia

    // 2. Create a context with ZeroDev gas + paymaster middleware on Sepolia
    print("Creating context (chain: Sepolia \(chainID))...")
    let ctx = try Context(
        projectID: projectID,
        chainID: chainID,
        gasMiddleware: .zeroDev,
        paymasterMiddleware: .zeroDev
    )
    print("Context created.")

    // 3. Create a local signer from the private key
    let signer = try Signer.local(privateKey: privateKey)
    print("Signer created.")

    // 4. Create a Kernel v3.3 smart account
    let account = try ctx.newAccount(signer: signer, version: .v3_3)
    print("Account created.")

    // 5. Print the smart account address
    let address = try account.getAddress()
    print("Smart account address: \(address)")

    // 6. Build a call: send 0 ETH to self (gasless noop)
    let call = Call(target: address)
    print("Sending gasless UserOp (0 ETH to self)...")

    // 7. Send the UserOp through the bundler
    let useropHash = try account.sendUserOp(calls: [call])
    print("UserOp submitted!")
    print("  UserOp hash: \(useropHash)")

    // 8. Wait for the UserOp to be included on-chain
    print("Waiting for on-chain receipt...")
    let receipt = try account.waitForUserOperationReceipt(useropHash: useropHash)

    // 9. Print receipt details
    print("")
    print("=== UserOp Receipt ===")
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
    print("======================")

    if receipt.success {
        print("\nGasless transfer completed successfully!")
    } else {
        print("\nUserOp execution reverted.")
        if let reason = receipt.reason {
            print("Reason: \(reason)")
        }
        exit(1)
    }

} catch {
    print("Error: \(error)")
    exit(1)
}
