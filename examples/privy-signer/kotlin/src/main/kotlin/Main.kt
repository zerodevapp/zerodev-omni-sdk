// Privy Embedded Wallet -- Custom Signer Example (Kotlin)
//
// Demonstrates using a Privy embedded wallet as the signer for a ZeroDev
// Kernel smart account via the custom signer interface.  All signing is
// delegated to Privy's REST API; no private key touches this process.
//
// Required environment variables:
//   ZERODEV_PROJECT_ID  - Your ZeroDev project ID
//   PRIVY_APP_ID        - Your Privy application ID
//   PRIVY_APP_SECRET    - Your Privy application secret
//   PRIVY_WALLET_ID     - The Privy wallet ID to sign with
//   OWNER_ADDRESS       - The EOA address of the Privy wallet (0x-prefixed)
//
// Run:
//   cd examples/privy-signer/kotlin
//   JAVA_HOME=/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home ./gradlew run

import dev.zerodev.aa.*
import io.ktor.client.*
import io.ktor.client.engine.cio.*
import io.ktor.client.plugins.contentnegotiation.*
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.http.*
import io.ktor.serialization.kotlinx.json.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

// ---------------------------------------------------------------------------
// Hex helpers
// ---------------------------------------------------------------------------

private fun ByteArray.toHex(): String =
    joinToString("") { "%02x".format(it) }

private fun ByteArray.toHex0x(): String =
    "0x" + toHex()

private fun hexToBytes(hex: String): ByteArray {
    val stripped = hex.removePrefix("0x").removePrefix("0X")
    require(stripped.length % 2 == 0) { "Odd-length hex string" }
    return ByteArray(stripped.length / 2) {
        stripped.substring(it * 2, it * 2 + 2).toInt(16).toByte()
    }
}

// ---------------------------------------------------------------------------
// Privy API response model
// ---------------------------------------------------------------------------

private val lenientJson = Json { ignoreUnknownKeys = true }

@Serializable
private data class PrivySignatureData(val signature: String)

@Serializable
private data class PrivySignResponse(val data: PrivySignatureData)

// ---------------------------------------------------------------------------
// Privy signer
// ---------------------------------------------------------------------------

class PrivySigner(
    private val appId: String,
    private val appSecret: String,
    private val walletId: String,
    private val ownerAddress: ByteArray,
) : SignerImpl {

    private val client = HttpClient(CIO) {
        install(ContentNegotiation) {
            json(lenientJson)
        }
    }

    /** POST to Privy wallet RPC. */
    private fun privyRpc(method: String, params: Map<String, String>): ByteArray = runBlocking {
        val url = "https://api.privy.io/v1/wallets/$walletId/rpc"

        val paramsObj = buildJsonObject {
            params.forEach { (k, v) -> put(k, v) }
        }
        val bodyJson = buildJsonObject {
            put("method", method)
            put("params", paramsObj)
        }

        val response = client.post(url) {
            contentType(ContentType.Application.Json)
            header("privy-app-id", appId)
            basicAuth(appId, appSecret)
            setBody(bodyJson.toString())
        }

        check(response.status == HttpStatusCode.OK) {
            "Privy API error (HTTP ${response.status}): ${response.bodyAsText()}"
        }

        val parsed = lenientJson.decodeFromString<PrivySignResponse>(response.bodyAsText())
        val sigBytes = hexToBytes(parsed.data.signature)
        check(sigBytes.size == 65) {
            "Unexpected signature length ${sigBytes.size} (expected 65)"
        }
        sigBytes
    }

    override fun signHash(hash: ByteArray): ByteArray {
        require(hash.size == 32) { "hash must be 32 bytes" }
        return privyRpc("raw_sign", mapOf("hash" to hash.toHex0x()))
    }

    override fun signMessage(msg: ByteArray): ByteArray {
        return privyRpc("personal_sign", mapOf("message" to msg.toHex(), "encoding" to "hex"))
    }

    override fun signTypedDataHash(hash: ByteArray): ByteArray {
        // EIP-712 typed data hash is signed identically to a raw hash.
        return signHash(hash)
    }

    override fun getAddress(): ByteArray {
        return ownerAddress.copyOf()
    }

    fun close() {
        client.close()
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

fun main() {
    println("ZeroDev Omni SDK -- Privy Custom Signer Example (Kotlin)")
    println("========================================================")

    // 1. Read required environment variables
    val projectId = requireEnv("ZERODEV_PROJECT_ID")
    val privyAppId = requireEnv("PRIVY_APP_ID")
    val privyAppSecret = requireEnv("PRIVY_APP_SECRET")
    val privyWalletId = requireEnv("PRIVY_WALLET_ID")
    val ownerAddressHex = requireEnv("OWNER_ADDRESS")

    val ownerAddress = Address.fromHex(ownerAddressHex)
    println("Owner address: $ownerAddress")

    // 2. Create a Privy custom signer
    val privySigner = PrivySigner(
        appId = privyAppId,
        appSecret = privyAppSecret,
        walletId = privyWalletId,
        ownerAddress = ownerAddress.bytes,
    )

    try {
        val signer = Signer.custom(privySigner)
        println("Privy custom signer created")

        signer.use {
            // 3. Create context on Sepolia with ZeroDev gas + paymaster
            Context.create(projectId, chainId = 11155111L).use { ctx ->
                println("Context created (Sepolia, ZeroDev gas + paymaster)")

                // 4. Create Kernel v3.3 smart account
                ctx.newAccount(signer, KernelVersion.V3_3).use { account ->
                    val smartAddr = account.getAddress()
                    println("Smart account address: $smartAddr")

                    // 5. Send a zero-value UserOp to self (gasless noop)
                    val calls = listOf(
                        Call(target = smartAddr, value = ByteArray(32), calldata = ByteArray(0)),
                    )

                    println("Sending UserOp (0 ETH to self)...")
                    val useropHash = account.sendUserOp(calls)
                    println("UserOp hash: $useropHash")

                    // 6. Wait for on-chain receipt
                    println("Waiting for receipt...")
                    val receipt = account.waitForUserOperationReceipt(useropHash)

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
                    if (!receipt.reason.isNullOrEmpty()) {
                        println("  Revert reason:   ${receipt.reason}")
                    }
                    println("======================")

                    if (receipt.success) {
                        println("\nDone! Privy-signed UserOp confirmed on-chain.")
                    } else {
                        System.err.println("\nUserOp execution reverted.")
                        System.exit(1)
                    }
                }
            }
        }
    } finally {
        privySigner.close()
    }
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

private fun requireEnv(name: String): String {
    val value = System.getenv(name)
    if (value.isNullOrEmpty()) {
        System.err.println("Error: required environment variable $name is not set.")
        System.err.println()
        System.err.println("Usage:")
        System.err.println("  export ZERODEV_PROJECT_ID=<your-zerodev-project-id>")
        System.err.println("  export PRIVY_APP_ID=<your-privy-app-id>")
        System.err.println("  export PRIVY_APP_SECRET=<your-privy-app-secret>")
        System.err.println("  export PRIVY_WALLET_ID=<your-privy-wallet-id>")
        System.err.println("  export OWNER_ADDRESS=0x<privy-wallet-eoa-address>")
        System.err.println("  ./gradlew run")
        System.exit(1)
    }
    return value
}
