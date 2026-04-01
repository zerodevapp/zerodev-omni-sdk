use std::env;
use std::process;

use zerodev_aa::{
    Address, Call, Context, GasMiddleware, Hash, KernelVersion, PaymasterMiddleware, Signer,
};

/// Decode a hex string (with optional 0x prefix) into a 32-byte array.
fn decode_private_key(hex_str: &str) -> Result<[u8; 32], String> {
    let hex_str = hex_str
        .strip_prefix("0x")
        .or_else(|| hex_str.strip_prefix("0X"))
        .unwrap_or(hex_str);

    if hex_str.len() != 64 {
        return Err(format!(
            "private key must be 64 hex characters, got {}",
            hex_str.len()
        ));
    }

    let mut bytes = [0u8; 32];
    for i in 0..32 {
        bytes[i] = u8::from_str_radix(&hex_str[i * 2..i * 2 + 2], 16)
            .map_err(|e| format!("invalid hex at position {}: {}", i * 2, e))?;
    }
    Ok(bytes)
}

fn main() {
    // ── 1. Read environment variables ──────────────────────────────────
    let project_id = env::var("ZERODEV_PROJECT_ID").unwrap_or_else(|_| {
        eprintln!("Usage: ZERODEV_PROJECT_ID=<id> PRIVATE_KEY=<hex> cargo run");
        eprintln!("  ZERODEV_PROJECT_ID  — your ZeroDev project ID");
        eprintln!("  PRIVATE_KEY         — 32-byte hex private key (with or without 0x prefix)");
        process::exit(1);
    });

    let private_key_hex = env::var("PRIVATE_KEY").unwrap_or_else(|_| {
        eprintln!("Error: PRIVATE_KEY environment variable is not set.");
        eprintln!("Usage: ZERODEV_PROJECT_ID=<id> PRIVATE_KEY=<hex> cargo run");
        process::exit(1);
    });

    let private_key = decode_private_key(&private_key_hex).unwrap_or_else(|e| {
        eprintln!("Error: invalid PRIVATE_KEY: {}", e);
        process::exit(1);
    });

    println!("=== Gasless Transfer Example (Sepolia) ===\n");

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

    // ── 3. Create signer from private key ──────────────────────────────
    let signer = Signer::local(&private_key).unwrap_or_else(|e| {
        eprintln!("Failed to create signer: {}", e);
        process::exit(1);
    });

    println!("Signer created");

    // ── 4. Create Kernel v3.3 account ──────────────────────────────────
    let account = ctx
        .new_account(&signer, KernelVersion::V3_3, 0)
        .unwrap_or_else(|e| {
            eprintln!("Failed to create account: {}", e);
            process::exit(1);
        });

    // ── 5. Print account address ───────────────────────────────────────
    let address = account.get_address().unwrap_or_else(|e| {
        eprintln!("Failed to get address: {}", e);
        process::exit(1);
    });

    println!("Smart account address: {}\n", address);

    // ── 6. Build a call: send 0 ETH to self ────────────────────────────
    let calls = vec![Call {
        target: address,
        value: [0u8; 32], // 0 ETH
        calldata: vec![],  // empty calldata
    }];

    println!("Sending 0 ETH to self (gasless via paymaster)...");

    // ── 7. Send UserOperation ──────────────────────────────────────────
    let userop_hash: Hash = account.send_user_op(&calls).unwrap_or_else(|e| {
        eprintln!("Failed to send UserOp: {}", e);
        process::exit(1);
    });

    println!("UserOp sent!");
    println!("  UserOp hash: {}\n", userop_hash);

    // ── 8. Wait for receipt ────────────────────────────────────────────
    println!("Waiting for on-chain confirmation...");

    let receipt = account
        .wait_for_user_operation_receipt(&userop_hash, 60000, 2000)
        .unwrap_or_else(|e| {
            eprintln!("Failed to get receipt: {}", e);
            process::exit(1);
        });

    // ── 9. Print receipt details ───────────────────────────────────────
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

    println!("\nDone!");

    // ── 10. Cleanup happens automatically via Drop ─────────────────────
}
