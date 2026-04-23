import Foundation
import ZeroDevAA

func main() throws {
    guard let projectID = ProcessInfo.processInfo.environment["ZERODEV_PROJECT_ID"],
          !projectID.isEmpty else {
        print("ZERODEV_PROJECT_ID not set, skipping live test")
        return
    }

    guard let pkHex = ProcessInfo.processInfo.environment["E2E_PRIVATE_KEY"],
          !pkHex.isEmpty else {
        print("E2E_PRIVATE_KEY not set, skipping live test")
        return
    }

    let privateKey = try hexDecode(pkHex)
    precondition(privateKey.count == 32, "E2E_PRIVATE_KEY must be 32 bytes")

    let chainID: UInt64 = 11155111 // Sepolia

    // Step 1: Create context with ZeroDev middleware
    let ctx = try Context(projectID: projectID, chainID: chainID, gasMiddleware: .zeroDev, paymasterMiddleware: .zeroDev)
    print("Context created")

    // Step 2: Create signer + account (Kernel v3.3, index 0)
    let signer = try Signer.local(privateKey: privateKey)
    let account = try ctx.newAccount(signer: signer, version: .v3_3)

    // Step 3: Get address
    let addr = try account.getAddress()
    print("Account address: \(addr)")

    // Step 4: Send UserOp (0 ETH to self)
    let hash = try account.sendUserOp(calls: [
        Call(target: addr)
    ])
    print("UserOp hash: \(hash)")

    precondition(!hash.isZero, "UserOp hash must not be all zeros")
    print("SendUserOp SUCCESS!")

    // Step 5: Wait for user operation receipt
    let receipt = try account.waitForUserOperationReceipt(useropHash: hash)
    print("Receipt: success=\(receipt.success) sender=\(receipt.sender) actualGasUsed=\(receipt.actualGasUsed)")
    precondition(receipt.success, "UserOp execution reverted")
    precondition(receipt.json.contains("\"userOpHash\""), "Receipt must contain userOpHash")
    print("WaitForUserOperationReceipt SUCCESS!")

    // ── EIP-7702 delegation path (fresh EOA, gasless) ─────────────────────
    print("\n=== EIP-7702 delegation ===")
    let freshSigner = try Signer.generate()
    let account7702 = try ctx.newAccount7702(signer: freshSigner, version: .v3_3)
    let addr7702 = try account7702.getAddress()
    print("[7702] Fresh EOA account: \(addr7702)")

    let hash7702 = try account7702.sendUserOp(calls: [Call(target: addr7702)])
    print("[7702] UserOp hash: \(hash7702)")
    precondition(!hash7702.isZero, "7702 UserOp hash must not be all zeros")

    let receipt7702 = try account7702.waitForUserOperationReceipt(useropHash: hash7702)
    print("[7702] Receipt: success=\(receipt7702.success) sender=\(receipt7702.sender) userOpHash=\(receipt7702.userOpHash)")
    precondition(receipt7702.success, "7702 UserOp execution reverted")
    print("[7702] Delegation SUCCESS!")
}

try main()
