use std::env;
use std::error::Error;

use zerodev_aa::{
    Address, Call, Context, GasMiddleware, KernelVersion, PaymasterMiddleware, Signer, SignerImpl,
};

// ---------------------------------------------------------------------------
// Hex helpers
// ---------------------------------------------------------------------------

fn hex_encode(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{:02x}", b));
    }
    s
}

fn hex_decode(s: &str) -> Result<Vec<u8>, Box<dyn Error>> {
    let s = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")).unwrap_or(s);
    if s.len() % 2 != 0 {
        return Err("odd-length hex string".into());
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).map_err(|e| e.into()))
        .collect()
}

fn hex_decode_20(s: &str) -> Result<[u8; 20], Box<dyn Error>> {
    let v = hex_decode(s)?;
    if v.len() != 20 {
        return Err(format!("expected 20 bytes, got {}", v.len()).into());
    }
    let mut arr = [0u8; 20];
    arr.copy_from_slice(&v);
    Ok(arr)
}

fn hex_decode_65(s: &str) -> Result<[u8; 65], Box<dyn Error>> {
    let v = hex_decode(s)?;
    if v.len() != 65 {
        return Err(format!("expected 65 bytes, got {}", v.len()).into());
    }
    let mut arr = [0u8; 65];
    arr.copy_from_slice(&v);
    Ok(arr)
}

// ---------------------------------------------------------------------------
// Privy signer
// ---------------------------------------------------------------------------

struct PrivySigner {
    app_id: String,
    app_secret: String,
    wallet_id: String,
    address: [u8; 20],
}

impl PrivySigner {
    /// Call the Privy raw_sign endpoint and return the 65-byte signature.
    fn raw_sign(&self, hash: &[u8; 32]) -> Result<[u8; 65], Box<dyn Error>> {
        let url = format!(
            "https://api.privy.io/v1/wallets/{}/rpc",
            self.wallet_id
        );

        let body = serde_json::json!({
            "method": "personal_sign",
            "params": {
                "message": hex_encode(hash),
                "encoding": "hex",
            }
        });

        let resp = ureq::post(&url)
            .set("privy-app-id", &self.app_id)
            .set(
                "Authorization",
                &format!(
                    "Basic {}",
                    base64_encode(&format!("{}:{}", self.app_id, self.app_secret))
                ),
            )
            .set("Content-Type", "application/json")
            .send_json(body)?;

        let json: serde_json::Value = resp.into_json()?;
        let sig_hex = json
            .pointer("/data/signature")
            .and_then(|v| v.as_str())
            .ok_or("missing data.signature in Privy response")?;

        hex_decode_65(sig_hex)
    }
}

impl SignerImpl for PrivySigner {
    fn sign_hash(&self, hash: &[u8; 32]) -> Result<[u8; 65], Box<dyn Error>> {
        self.raw_sign(hash)
    }

    fn sign_message(&self, msg: &[u8]) -> Result<[u8; 65], Box<dyn Error>> {
        // Privy's personal_sign handles EIP-191 prefixing internally,
        // but the C library already hashes the message before calling this.
        // We forward the raw bytes as a hash.
        if msg.len() == 32 {
            let mut hash = [0u8; 32];
            hash.copy_from_slice(msg);
            self.raw_sign(&hash)
        } else {
            // For arbitrary-length messages, hash first (keccak256 prefix
            // is applied by the library before calling sign_message).
            let mut hash = [0u8; 32];
            hash.copy_from_slice(&msg[..32.min(msg.len())]);
            self.raw_sign(&hash)
        }
    }

    fn sign_typed_data_hash(&self, hash: &[u8; 32]) -> Result<[u8; 65], Box<dyn Error>> {
        self.sign_hash(hash)
    }

    fn get_address(&self) -> [u8; 20] {
        self.address
    }
}

// ---------------------------------------------------------------------------
// Minimal base64 encoder (avoids pulling in another crate)
// ---------------------------------------------------------------------------

fn base64_encode(input: &str) -> String {
    const TABLE: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    let bytes = input.as_bytes();
    let mut out = String::with_capacity((bytes.len() + 2) / 3 * 4);
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = if chunk.len() > 1 { chunk[1] as u32 } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] as u32 } else { 0 };
        let triple = (b0 << 16) | (b1 << 8) | b2;

        out.push(TABLE[((triple >> 18) & 0x3F) as usize] as char);
        out.push(TABLE[((triple >> 12) & 0x3F) as usize] as char);
        if chunk.len() > 1 {
            out.push(TABLE[((triple >> 6) & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(TABLE[(triple & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

fn main() -> Result<(), Box<dyn Error>> {
    // 1. Read configuration from environment variables
    let project_id =
        env::var("ZERODEV_PROJECT_ID").expect("ZERODEV_PROJECT_ID must be set");
    let app_id = env::var("PRIVY_APP_ID").expect("PRIVY_APP_ID must be set");
    let app_secret =
        env::var("PRIVY_APP_SECRET").expect("PRIVY_APP_SECRET must be set");
    let wallet_id =
        env::var("PRIVY_WALLET_ID").expect("PRIVY_WALLET_ID must be set");
    let owner_address =
        env::var("OWNER_ADDRESS").expect("OWNER_ADDRESS must be set");

    println!("Privy Signer Example");
    println!("====================");
    println!("Project ID : {}", project_id);
    println!("Privy App  : {}", app_id);
    println!("Wallet     : {}", wallet_id);
    println!("Owner      : {}", owner_address);

    // 2. Create context on Sepolia (chain ID 11155111)
    let ctx = Context::new(
        &project_id,
        "", // default RPC
        "", // default bundler
        11155111,
        GasMiddleware::ZeroDev,
        PaymasterMiddleware::ZeroDev,
    )?;

    // 3. Build the Privy custom signer
    let privy_signer = PrivySigner {
        app_id,
        app_secret,
        wallet_id,
        address: hex_decode_20(&owner_address)?,
    };
    let signer = Signer::custom(privy_signer)?;

    // 4. Create a Kernel v3.1 smart account
    let account = ctx.new_account(&signer, KernelVersion::V3_1, 0)?;
    let smart_account_addr = account.get_address()?;
    println!("\nSmart account: {}", smart_account_addr);

    // 5. Send a zero-value call to self (no-op UserOp to verify signing works)
    println!("\nSending UserOp (zero-value self-call)...");
    let calls = vec![Call {
        target: smart_account_addr,
        value: [0u8; 32],
        calldata: vec![],
    }];

    let userop_hash = account.send_user_op(&calls)?;
    println!("UserOp hash: {}", userop_hash);

    // 6. Wait for the UserOp receipt
    println!("Waiting for receipt...");
    let receipt = account.wait_for_user_operation_receipt(&userop_hash, 0, 0)?;

    println!("\nReceipt");
    println!("-------");
    println!("Success     : {}", receipt.success);
    println!("Sender      : {}", receipt.sender);
    println!("UserOp Hash : {}", receipt.user_op_hash);
    println!("Gas cost    : {}", receipt.actual_gas_cost);
    println!("Gas used    : {}", receipt.actual_gas_used);
    if let Some(pm) = &receipt.paymaster {
        println!("Paymaster   : {}", pm);
    }
    if let Some(reason) = &receipt.reason {
        println!("Reason      : {}", reason);
    }

    Ok(())
}
