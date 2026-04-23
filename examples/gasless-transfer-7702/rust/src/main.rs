use std::env;
use std::process;

use zerodev_aa::{
    Call, Context, GasMiddleware, Hash, KernelVersion, PaymasterMiddleware, Signer,
};

/// Gasless transfer example that uses EIP-7702 delegation.
///
/// A fresh EOA is generated per run to demonstrate the delegation-install
/// path: on the first UserOperation the SDK signs an authorization tuple
/// `(chain_id, Kernel implementation, EOA nonce)` and attaches it via the
/// `eip7702Auth` field. After delegation is installed on-chain, subsequent
/// UserOps skip the authorization.
///
/// The account address IS the EOA — there is no CREATE2 deployment and no
/// account-index parameter.
fn main() {
    // ── 1. Read environment variables ──────────────────────────────────
    let project_id = env::var("ZERODEV_PROJECT_ID").unwrap_or_else(|_| {
        eprintln!("Usage: ZERODEV_PROJECT_ID=<id> cargo run");
        eprintln!("  ZERODEV_PROJECT_ID  — your ZeroDev project ID");
        eprintln!();
        eprintln!("A fresh EOA is generated per run to exercise the EIP-7702");
        eprintln!("delegation-install path. The paymaster sponsors gas.");
        process::exit(1);
    });

    println!("=== Gasless Transfer via EIP-7702 Delegation (Sepolia) ===\n");

    // ── 2. Create context with ZeroDev gas + paymaster on Sepolia ──────
    let chain_id: u64 = 11155111; // Sepolia

    let ctx = Context::new(
        &project_id,
        "", // default RPC URL from ZeroDev
        "", // default bundler URL from ZeroDev
        chain_id,
        GasMiddleware::ZeroDev,
        PaymasterMiddleware::ZeroDev,
    )
    .unwrap_or_else(|e| {
        eprintln!("Failed to create context: {}", e);
        process::exit(1);
    });

    println!("Context created (chain_id={})", chain_id);

    // ── 3. Generate a fresh EOA — highlights the delegation-install path.
    //     In production you'd use Signer::local(&pk) or Signer::custom(impl).
    let signer = Signer::generate().unwrap_or_else(|e| {
        eprintln!("Failed to generate signer: {}", e);
        process::exit(1);
    });

    println!("Fresh EOA generated (no on-chain history yet)");

    // ── 4. Create a 7702 Kernel v3.3 account — sender == EOA address. ──
    let account = ctx
        .new_account_7702(&signer, KernelVersion::V3_3)
        .unwrap_or_else(|e| {
            eprintln!("Failed to create 7702 account: {}", e);
            process::exit(1);
        });

    let address = account.get_address().unwrap_or_else(|e| {
        eprintln!("Failed to get address: {}", e);
        process::exit(1);
    });

    println!("7702 account (EOA) address: {}\n", address);

    // ── 5. Build a call: send 0 ETH to self ────────────────────────────
    let calls = vec![Call {
        target: address,
        value: [0u8; 32], // 0 ETH
        calldata: vec![], // empty calldata
    }];

    println!("Sending 0 ETH to self (gasless via paymaster, with EIP-7702 auth)...");

    // ── 6. Send UserOperation — the SDK signs + attaches the auth tuple.
    let userop_hash: Hash = account.send_user_op(&calls).unwrap_or_else(|e| {
        eprintln!("Failed to send UserOp: {}", e);
        process::exit(1);
    });

    println!("UserOp sent!");
    println!("  UserOp hash: {}\n", userop_hash);

    // ── 7. Wait for receipt ────────────────────────────────────────────
    println!("Waiting for on-chain confirmation (delegation installs on inclusion)...");

    let receipt = account
        .wait_for_user_operation_receipt(&userop_hash, 60000, 2000)
        .unwrap_or_else(|e| {
            eprintln!("Failed to get receipt: {}", e);
            process::exit(1);
        });

    // ── 8. Print receipt details ───────────────────────────────────────
    println!("\n=== UserOperation Receipt ===");
    println!("  Success:         {}", receipt.success);
    println!("  UserOp hash:     {}", receipt.user_op_hash);
    println!("  Sender:          {}", receipt.sender);
    println!("  Nonce:           {}", receipt.nonce);
    println!("  Actual gas used: {}", receipt.actual_gas_used);
    println!("  Actual gas cost: {}", receipt.actual_gas_cost);

    if let Some(ref paymaster) = receipt.paymaster {
        println!("  Paymaster:       {}", paymaster);
    }

    if let Some(ref reason) = receipt.reason {
        println!("  Revert reason:   {}", reason);
    }

    println!("\nDone! The EOA is now delegated to the Kernel implementation.");

    // ── 9. Cleanup happens automatically via Drop ──────────────────────
}
