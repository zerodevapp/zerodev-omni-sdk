package dev.zerodev.aa

import org.junit.jupiter.api.Assumptions
import org.junit.jupiter.api.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class LiveTest {
    @Test
    fun test7702SponsoredUserOp() {
        val projectId = System.getenv("ZERODEV_PROJECT_ID") ?: ""
        Assumptions.assumeTrue(projectId.isNotEmpty()) { "ZERODEV_PROJECT_ID not set, skipping" }

        val chainId = 11155111L // Sepolia

        Context.create(projectId, chainId = chainId).use { ctx ->
            // Fresh EOA: 7702 delegates the EOA's code, so the account IS the EOA.
            Signer.generate().use { signer ->
                ctx.newAccount7702(signer, KernelVersion.V3_3).use { account ->
                    val addr = account.getAddress()
                    println("7702 Account address (= EOA): $addr")

                    val calls = listOf(
                        Call(target = addr, value = ByteArray(32), calldata = ByteArray(0)),
                    )

                    val hash = account.sendUserOp(calls)
                    println("7702 UserOp hash: $hash")
                    assertFalse(hash.isZero, "UserOp hash must not be all zeros")

                    val receipt = account.waitForUserOperationReceipt(hash)
                    println("7702 Receipt: success=${receipt.success} sender=${receipt.sender} userOpHash=${receipt.userOpHash} actualGasUsed=${receipt.actualGasUsed}")
                    assertTrue(receipt.success, "7702 UserOp execution reverted")
                    assertTrue(receipt.userOpHash.isNotEmpty(), "userOpHash must be present")
                    assertTrue(receipt.sender.isNotEmpty(), "sender must be present")
                    println("7702 SponsoredUserOp SUCCESS!")
                }
            }
        }
    }

    @Test
    fun sendUserOpSepolia() {
        val projectId = System.getenv("ZERODEV_PROJECT_ID") ?: ""
        Assumptions.assumeTrue(projectId.isNotEmpty()) { "ZERODEV_PROJECT_ID not set, skipping" }

        val pkHex = System.getenv("E2E_PRIVATE_KEY") ?: ""
        Assumptions.assumeTrue(pkHex.isNotEmpty()) { "E2E_PRIVATE_KEY not set, skipping" }

        val stripped = pkHex.removePrefix("0x").removePrefix("0X")
        val privateKey = ByteArray(32) { stripped.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

        val chainId = 11155111L // Sepolia

        Context.create(projectId, chainId = chainId).use { ctx ->
            Signer.local(privateKey).use { signer ->
            ctx.newAccount(signer, KernelVersion.V3_3).use { account ->
                val addr = account.getAddress()
                println("Account address: $addr")

                val calls = listOf(
                    Call(target = addr, value = ByteArray(32), calldata = ByteArray(0)),
                )

                val hash = account.sendUserOp(calls)
                println("UserOp hash: $hash")

                assertFalse(hash.isZero, "UserOp hash must not be all zeros")
                println("SendUserOp SUCCESS!")

                val receipt = account.waitForUserOperationReceipt(hash)
                println("Receipt: success=${receipt.success} sender=${receipt.sender} userOpHash=${receipt.userOpHash} actualGasUsed=${receipt.actualGasUsed}")
                assert(receipt.success) { "UserOp execution reverted" }
                assert(receipt.userOpHash.isNotEmpty()) { "userOpHash must be present" }
                assert(receipt.sender.isNotEmpty()) { "sender must be present" }
                println("WaitForUserOperationReceipt SUCCESS!")
            }
            }
        }
    }
}
