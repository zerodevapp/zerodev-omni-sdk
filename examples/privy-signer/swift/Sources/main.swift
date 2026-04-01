// Privy Embedded Wallet — Custom Signer Example (Swift)
//
// This CLI example uses Privy's REST API directly for server-side signing.
// In a real iOS/macOS app, you'd use the Privy Swift SDK instead:
//
//   import PrivySDK  // https://github.com/privy-io/privy-ios
//
//   class PrivySigner: SignerProtocol {
//       let wallet: EmbeddedEthereumWallet
//
//       func signMessage(_ msg: [UInt8]) throws -> [UInt8] {
//           let data = EthereumRpcRequest(
//               method: "personal_sign",
//               params: [bytesToHex(msg), wallet.address]
//           )
//           let sig = try await wallet.provider.request(data)
//           return hexToBytes(sig)!
//       }
//       // ... signHash, signTypedDataHash, getAddress
//   }
//
//   let signer = try Signer.custom(PrivySigner(wallet: privy.user!.embeddedEthereumWallets.first!))
//   let account = try ctx.newAccount(signer: signer, version: .v3_3)

import Foundation
import ZeroDevAA

// MARK: - Hex helpers

private func bytesToHex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private func hexToBytes(_ hex: String) -> [UInt8]? {
    var s = hex
    if s.hasPrefix("0x") || s.hasPrefix("0X") {
        s = String(s.dropFirst(2))
    }
    guard s.count % 2 == 0 else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(s.count / 2)
    var idx = s.startIndex
    while idx < s.endIndex {
        let next = s.index(idx, offsetBy: 2)
        guard let byte = UInt8(s[idx..<next], radix: 16) else { return nil }
        bytes.append(byte)
        idx = next
    }
    return bytes
}

// MARK: - Privy custom signer

/// A custom signer that delegates signing to a Privy embedded wallet via the Privy REST API.
///
/// Privy's `raw_sign` endpoint signs arbitrary data using the embedded wallet's private key.
/// This allows the Privy wallet to act as the owner/signer for a ZeroDev Kernel smart account.
///
/// API reference: https://docs.privy.io/reference/rest-api/wallets/raw-sign
final class PrivySigner: SignerProtocol {
    private let appID: String
    private let appSecret: String
    private let walletID: String
    private let ownerAddress: [UInt8]
    private let session: URLSession

    init(appID: String, appSecret: String, walletID: String, ownerAddress: [UInt8]) {
        self.appID = appID
        self.appSecret = appSecret
        self.walletID = walletID
        self.ownerAddress = ownerAddress
        self.session = URLSession(configuration: .default)
    }

    // MARK: - SignerProtocol

    func signHash(_ hash: [UInt8]) throws -> [UInt8] {
        precondition(hash.count == 32, "Hash must be 32 bytes")
        return try privyRawSign(
            payload: [
                "encoding": "hex",
                "hash": "0x" + bytesToHex(hash),
            ]
        )
    }

    func signMessage(_ msg: [UInt8]) throws -> [UInt8] {
        return try privyRpc(
            method: "personal_sign",
            params: [
                "message": bytesToHex(msg),
                "encoding": "hex",
            ]
        )
    }

    func signTypedDataHash(_ hash: [UInt8]) throws -> [UInt8] {
        // Privy's raw_sign with a pre-computed typed data hash is equivalent to signHash.
        return try signHash(hash)
    }

    func getAddress() -> [UInt8] {
        return ownerAddress
    }

    // MARK: - Privy API

    private func privyRawSign(payload: [String: Any]) throws -> [UInt8] {
        return try privyRpc(method: "raw_sign", params: payload)
    }

    /// Call Privy wallet RPC synchronously using a semaphore.
    private func privyRpc(method: String, params: [String: Any]) throws -> [UInt8] {
        let url = URL(string: "https://api.privy.io/v1/wallets/\(walletID)/rpc")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let credentials = Data("\(appID):\(appSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue(appID, forHTTPHeaderField: "privy-app-id")

        let body: [String: Any] = [
            "method": method,
            "params": params,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var responseData: Data?
        var responseError: Error?
        let semaphore = DispatchSemaphore(value: 0)

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                responseError = error
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                responseError = SignerError.invalidResponse
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
                responseError = SignerError.httpError(statusCode: httpResponse.statusCode, body: body)
                return
            }
            responseData = data
        }
        task.resume()
        semaphore.wait()

        if let err = responseError {
            throw err
        }

        guard let data = responseData else {
            throw SignerError.invalidResponse
        }

        // Parse response: { "data": { "signature": "0x..." } }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let sigHex = dataObj["signature"] as? String else {
            let raw = String(data: data, encoding: .utf8) ?? "non-utf8"
            throw SignerError.unexpectedResponse(raw)
        }

        guard let sigBytes = hexToBytes(sigHex) else {
            throw SignerError.invalidSignature(sigHex)
        }

        // Privy returns a 65-byte signature (r, s, v).
        guard sigBytes.count == 65 else {
            throw SignerError.invalidSignature("expected 65 bytes, got \(sigBytes.count)")
        }

        return sigBytes
    }
}

// MARK: - Errors

enum SignerError: Error, CustomStringConvertible {
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case unexpectedResponse(String)
    case invalidSignature(String)
    case missingEnvVar(String)

    var description: String {
        switch self {
        case .invalidResponse:
            return "Privy API returned an invalid response"
        case .httpError(let code, let body):
            return "Privy API HTTP \(code): \(body)"
        case .unexpectedResponse(let raw):
            return "Unexpected Privy API response: \(raw)"
        case .invalidSignature(let detail):
            return "Invalid signature from Privy: \(detail)"
        case .missingEnvVar(let name):
            return "Missing required environment variable: \(name)"
        }
    }
}

// MARK: - Environment helper

func requireEnv(_ name: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        throw SignerError.missingEnvVar(name)
    }
    return value
}

// MARK: - Main

func main() throws {
    // Step 1: Read configuration from environment
    let projectID = try requireEnv("ZERODEV_PROJECT_ID")
    let privyAppID = try requireEnv("PRIVY_APP_ID")
    let privyAppSecret = try requireEnv("PRIVY_APP_SECRET")
    let privyWalletID = try requireEnv("PRIVY_WALLET_ID")
    let ownerAddressHex = try requireEnv("OWNER_ADDRESS")

    guard let ownerAddressBytes = hexToBytes(ownerAddressHex), ownerAddressBytes.count == 20 else {
        print("Error: OWNER_ADDRESS must be a valid 20-byte hex address (with or without 0x prefix)")
        return
    }

    let chainID: UInt64 = 11155111 // Sepolia

    print("Privy Custom Signer Example")
    print("===========================")
    print("Project ID:    \(projectID)")
    print("Privy App ID:  \(privyAppID)")
    print("Wallet ID:     \(privyWalletID)")
    print("Owner Address: 0x\(bytesToHex(ownerAddressBytes))")
    print("Chain ID:      \(chainID)")
    print()

    // Step 2: Create the Privy custom signer
    let privySigner = PrivySigner(
        appID: privyAppID,
        appSecret: privyAppSecret,
        walletID: privyWalletID,
        ownerAddress: ownerAddressBytes
    )
    let signer = try Signer.custom(privySigner)
    print("Privy signer created")

    // Step 3: Create context with ZeroDev gas + paymaster middleware
    let ctx = try Context(
        projectID: projectID,
        chainID: chainID,
        gasMiddleware: .zeroDev,
        paymasterMiddleware: .zeroDev
    )
    print("Context created")

    // Step 4: Create Kernel v3.3 smart account
    let account = try ctx.newAccount(signer: signer, version: .v3_3)
    let smartAccountAddr = try account.getAddress()
    print("Smart account address: \(smartAccountAddr)")

    // Step 5: Send a UserOp (0 ETH transfer to self — a no-op to verify the pipeline)
    print("\nSending UserOp (0 ETH to self)...")
    let userOpHash = try account.sendUserOp(calls: [
        Call(target: smartAccountAddr),
    ])
    print("UserOp hash: \(userOpHash)")

    // Step 6: Wait for the UserOp to be included on-chain
    print("Waiting for receipt...")
    let receipt = try account.waitForUserOperationReceipt(useropHash: userOpHash)
    print()
    print("Receipt:")
    print("  success:       \(receipt.success)")
    print("  sender:        \(receipt.sender)")
    print("  userOpHash:    \(receipt.userOpHash)")
    print("  actualGasUsed: \(receipt.actualGasUsed)")

    if receipt.success {
        print("\nUserOp executed successfully!")
    } else {
        print("\nUserOp execution reverted. Reason: \(receipt.reason ?? "unknown")")
    }
}

do {
    try main()
} catch {
    print("Error: \(error)")
    exit(1)
}
