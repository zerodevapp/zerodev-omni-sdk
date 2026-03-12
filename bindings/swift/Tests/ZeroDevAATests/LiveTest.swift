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
    let ctx = try Context(projectID: projectID, chainID: chainID, middleware: .zeroDev)
    print("Context created")

    // Step 2: Create account (Kernel v3.3, index 0)
    let account = try ctx.newAccount(privateKey: privateKey, version: .v3_3)

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
}

try main()
