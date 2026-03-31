use zerodev_aa::{Address, Call, Context, Signer, GasMiddleware, Hash, KernelVersion, PaymasterMiddleware, UserOperationReceipt};

/// E2E test: sends a zero-value UserOp to self on Sepolia via ZeroDev.
///
/// Requires environment variables:
///   ZERODEV_PROJECT_ID — ZeroDev project ID
///   E2E_PRIVATE_KEY    — 32-byte hex private key (with or without 0x prefix)
///
/// Run via: make test-rust-live
#[test]
fn send_userop_sepolia() {
    let project_id = match std::env::var("ZERODEV_PROJECT_ID") {
        Ok(v) if !v.is_empty() => v,
        _ => {
            eprintln!("ZERODEV_PROJECT_ID not set, skipping live test");
            return;
        }
    };

    let pk_hex = match std::env::var("E2E_PRIVATE_KEY") {
        Ok(v) if !v.is_empty() => v,
        _ => {
            eprintln!("E2E_PRIVATE_KEY not set, skipping live test");
            return;
        }
    };

    let pk_hex = pk_hex
        .strip_prefix("0x")
        .or_else(|| pk_hex.strip_prefix("0X"))
        .unwrap_or(&pk_hex);

    let pk_bytes = hex::decode(pk_hex).expect("invalid E2E_PRIVATE_KEY hex");
    assert_eq!(pk_bytes.len(), 32, "E2E_PRIVATE_KEY must be 32 bytes");

    let mut private_key = [0u8; 32];
    private_key.copy_from_slice(&pk_bytes);

    let chain_id: u64 = 11155111; // Sepolia

    // Step 1: Create context with ZeroDev middleware
    let ctx = Context::new(&project_id, "", "", chain_id, GasMiddleware::ZeroDev, PaymasterMiddleware::ZeroDev)
        .expect("Context::new failed");
    eprintln!("Context created");

    // Step 2: Create signer + account (Kernel v3.3, index 0)
    let signer = Signer::local(&private_key).expect("Signer::local failed");
    let account = ctx
        .new_account(&signer, KernelVersion::V3_3, 0)
        .expect("new_account failed");

    // Step 3: Get address
    let addr: Address = account.get_address().expect("get_address failed");
    eprintln!("Account address: {addr}");

    // Step 4: Build a call (send 0 ETH to self)
    let calls = vec![Call {
        target: addr,
        value: [0u8; 32],
        calldata: vec![],
    }];

    // Step 5: Send UserOp via the high-level orchestrator
    let hash: Hash = account.send_user_op(&calls).expect("send_user_op failed");
    eprintln!("UserOp hash: {hash}");

    assert!(!hash.is_zero(), "UserOp hash must not be all zeros");
    eprintln!("SendUserOp SUCCESS!");

    // Step 6: Wait for user operation receipt
    let receipt: UserOperationReceipt = account
        .wait_for_user_operation_receipt(&hash, 0, 0)
        .expect("wait_for_user_operation_receipt failed");
    eprintln!(
        "Receipt: success={} sender={} userOpHash={} actualGasUsed={}",
        receipt.success, receipt.sender, receipt.user_op_hash, receipt.actual_gas_used,
    );
    assert!(receipt.success, "UserOp execution reverted");
    assert!(!receipt.user_op_hash.is_empty(), "userOpHash must be present");
    assert!(!receipt.sender.is_empty(), "sender must be present");
    eprintln!("WaitForUserOperationReceipt SUCCESS!");
}
