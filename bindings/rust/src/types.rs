/// 20-byte Ethereum address.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct Address(pub [u8; 20]);

impl Address {
    /// Parse from a hex string (with or without 0x prefix).
    pub fn from_hex(s: &str) -> Result<Self, hex::FromHexError> {
        let s = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")).unwrap_or(s);
        let mut bytes = [0u8; 20];
        hex::decode_to_slice(s, &mut bytes)?;
        Ok(Self(bytes))
    }

    /// Return as a 0x-prefixed lowercase hex string.
    pub fn to_hex(&self) -> String {
        format!("0x{}", hex::encode(self.0))
    }
}

impl std::fmt::Debug for Address {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Address({})", self.to_hex())
    }
}

impl std::fmt::Display for Address {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.to_hex())
    }
}

/// 32-byte hash (e.g. UserOp hash, tx hash).
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct Hash(pub [u8; 32]);

impl Hash {
    /// Return as a 0x-prefixed lowercase hex string.
    pub fn to_hex(&self) -> String {
        format!("0x{}", hex::encode(self.0))
    }

    /// Returns true if all bytes are zero.
    pub fn is_zero(&self) -> bool {
        self.0.iter().all(|&b| b == 0)
    }
}

impl std::fmt::Debug for Hash {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Hash({})", self.to_hex())
    }
}

impl std::fmt::Display for Hash {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.to_hex())
    }
}

/// Kernel smart account version.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KernelVersion {
    V3_1,
    V3_2,
    V3_3,
}

impl KernelVersion {
    pub(crate) fn to_c(self) -> i32 {
        match self {
            Self::V3_1 => 0,
            Self::V3_2 => 1,
            Self::V3_3 => 2,
        }
    }
}

/// Middleware provider for gas pricing and paymaster sponsorship.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Middleware {
    /// ZeroDev: zd_getUserOperationGasPrice + pm_getPaymasterStubData/pm_getPaymasterData.
    ZeroDev,
}

/// A single call within a UserOperation.
pub struct Call {
    /// Target contract address.
    pub target: Address,
    /// Value in wei (big-endian u256).
    pub value: [u8; 32],
    /// Calldata bytes.
    pub calldata: Vec<u8>,
}
