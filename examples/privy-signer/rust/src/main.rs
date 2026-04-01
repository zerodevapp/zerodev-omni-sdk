/// Privy Embedded Wallet — Custom Signer Example (Rust)
///
/// Creates a Privy server wallet using the official SDK and signs
/// UserOperations with it. Uses sign_secp256k1 for raw signing
/// with EIP-191 wrapping done locally.
///
/// Required env vars:
///   ZERODEV_PROJECT_ID
///   PRIVY_APP_ID
///   PRIVY_APP_SECRET
use std::error::Error;
use std::sync::Arc;

use privy_rs::{AuthorizationContext, PrivyClient};
use privy_rs::generated::types::{CreateWalletBody, WalletChainType, WalletRpcResponse};
use sha3::{Digest, Keccak256};
use zerodev_aa::{
    Call, Context, GasMiddleware, KernelVersion, PaymasterMiddleware, Signer, SignerImpl,
};

struct PrivySigner {
    client: Arc<PrivyClient>,
    wallet_id: String,
    address: [u8; 20],
    rt: tokio::runtime::Runtime,
}

impl PrivySigner {
    /// Raw ECDSA sign via Privy's secp256k1_sign endpoint.
    fn raw_sign(&self, hash: &[u8; 32]) -> Result<[u8; 65], Box<dyn Error>> {
        let ctx = AuthorizationContext::new();
        let hash_hex = format!("0x{}", hex::encode(hash));
        let resp = self.rt.block_on(
            self.client.wallets().ethereum().sign_secp256k1(
                &self.wallet_id, &hash_hex, &ctx, None,
            ),
        )?;
        match resp.into_inner() {
            WalletRpcResponse::EthereumSecp256k1SignRpcResponse(r) => parse_sig(&r.data.signature),
            _ => Err("unexpected response type".into()),
        }
    }
}

impl SignerImpl for PrivySigner {
    fn sign_hash(&self, hash: &[u8; 32]) -> Result<[u8; 65], Box<dyn Error>> {
        self.raw_sign(hash)
    }

    fn sign_message(&self, msg: &[u8]) -> Result<[u8; 65], Box<dyn Error>> {
        // EIP-191: keccak256("\x19Ethereum Signed Message:\n" + len(msg) + msg)
        let prefix = format!("\x19Ethereum Signed Message:\n{}", msg.len());
        let mut hasher = Keccak256::new();
        hasher.update(prefix.as_bytes());
        hasher.update(msg);
        let digest: [u8; 32] = hasher.finalize().into();
        self.raw_sign(&digest)
    }

    fn sign_typed_data_hash(&self, hash: &[u8; 32]) -> Result<[u8; 65], Box<dyn Error>> {
        self.raw_sign(hash)
    }

    fn get_address(&self) -> [u8; 20] {
        self.address
    }
}

fn main() -> Result<(), Box<dyn Error>> {
    println!("ZeroDev Omni SDK — Privy Signer Example (Rust)");
    println!("===============================================");

    let project_id = env("ZERODEV_PROJECT_ID");
    let app_id = env("PRIVY_APP_ID");
    let app_secret = env("PRIVY_APP_SECRET");

    // Create Privy wallet
    let rt = tokio::runtime::Runtime::new()?;
    let client = Arc::new(PrivyClient::new(app_id, app_secret)?);
    let wallet = rt.block_on(client.wallets().create(
        None,
        &CreateWalletBody {
            chain_type: WalletChainType::Ethereum,
            additional_signers: None,
            owner: None,
            owner_id: None,
            policy_ids: vec![],
        },
    ))?;
    println!("Privy wallet: {} ({})", wallet.id, wallet.address);

    let address = parse_addr(&wallet.address)?;

    // Create custom signer
    let signer = Signer::custom(PrivySigner {
        client, wallet_id: wallet.id.clone(), address, rt,
    })?;

    // Create ZeroDev context + account
    let ctx = Context::new(
        &project_id, "", "", 11155111,
        GasMiddleware::ZeroDev, PaymasterMiddleware::ZeroDev,
    )?;
    let account = ctx.new_account(&signer, KernelVersion::V3_3, 0)?;
    let addr = account.get_address()?;
    println!("Smart account: {addr}");

    // Send sponsored UserOp
    println!("Sending sponsored UserOp...");
    let hash = account.send_user_op(&[Call {
        target: addr, value: [0u8; 32], calldata: vec![],
    }])?;
    println!("UserOp hash: {hash}");

    let receipt = account.wait_for_user_operation_receipt(&hash, 0, 0)?;
    println!("Success: {} | Gas: {} | Paymaster: {}",
        receipt.success, receipt.actual_gas_used, receipt.paymaster.unwrap_or_default());

    Ok(())
}

fn parse_sig(hex_str: &str) -> Result<[u8; 65], Box<dyn Error>> {
    let bytes = hex::decode(hex_str.strip_prefix("0x").unwrap_or(hex_str))?;
    let mut sig = [0u8; 65];
    if bytes.len() != 65 { return Err(format!("sig len {}", bytes.len()).into()); }
    sig.copy_from_slice(&bytes);
    Ok(sig)
}

fn parse_addr(hex_str: &str) -> Result<[u8; 20], Box<dyn Error>> {
    let bytes = hex::decode(hex_str.strip_prefix("0x").unwrap_or(hex_str))?;
    let mut addr = [0u8; 20];
    if bytes.len() != 20 { return Err(format!("addr len {}", bytes.len()).into()); }
    addr.copy_from_slice(&bytes);
    Ok(addr)
}

fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| { eprintln!("Missing {name}"); std::process::exit(1); })
}
