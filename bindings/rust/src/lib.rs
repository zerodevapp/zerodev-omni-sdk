mod ffi;
pub mod error;
pub mod types;

use std::ffi::CString;
use std::os::raw::{c_char, c_void};
use std::ptr;

pub use error::{AaError, Result};
pub use types::{
    Address, Authorization, Call, GasMiddleware, Hash, KernelVersion, PaymasterMiddleware,
    UserOperationReceipt,
};

/// Trait for implementing custom signers (Privy, HSM, MPC, etc.).
///
/// The four required methods cover ordinary ECDSA signing. The optional
/// [`SignerImpl::sign_authorization`] hook lets backends that natively support
/// EIP-7702 (hardware wallets, MPC networks) handle the authorization tuple
/// themselves; leaving it unimplemented is safe — the SDK falls back to
/// hashing `0x05 || rlp([chain_id, address, nonce])` and calling `sign_hash`.
pub trait SignerImpl: Send + 'static {
    fn sign_hash(&self, hash: &[u8; 32]) -> std::result::Result<[u8; 65], Box<dyn std::error::Error>>;
    fn sign_message(&self, msg: &[u8]) -> std::result::Result<[u8; 65], Box<dyn std::error::Error>>;
    fn sign_typed_data_hash(&self, hash: &[u8; 32]) -> std::result::Result<[u8; 65], Box<dyn std::error::Error>>;
    fn get_address(&self) -> [u8; 20];

    /// Sign an EIP-7702 authorization tuple.
    ///
    /// Default: returns an error signalling "not implemented" — combined with
    /// [`SignerImpl::provides_sign_authorization`] returning `false` (the
    /// default), the SDK will transparently fall back to hashing the tuple and
    /// invoking `sign_hash`.
    ///
    /// Override both this method and `provides_sign_authorization` to install
    /// a native implementation.
    fn sign_authorization(
        &self,
        _chain_id: u64,
        _address: [u8; 20],
        _nonce: u64,
    ) -> std::result::Result<Authorization, Box<dyn std::error::Error>> {
        Err("SignerImpl::sign_authorization not implemented — SDK will fall back to sign_hash".into())
    }

    /// Returns `true` when this implementation provides a native
    /// `sign_authorization`. The custom-signer bridge consults this to decide
    /// whether to populate the FFI vtable's `sign_authorization` slot; a
    /// `false` slot instructs the SDK to fall back.
    fn provides_sign_authorization(&self) -> bool {
        false
    }
}

unsafe extern "C" fn custom_sign_hash(ctx: *mut c_void, hash: *const [u8; 32], out: *mut [u8; 65]) -> i32 {
    let imp = &*(ctx as *const Box<dyn SignerImpl>);
    match imp.sign_hash(&*hash) {
        Ok(sig) => { *out = sig; 0 }
        Err(_) => 1,
    }
}

unsafe extern "C" fn custom_sign_message(ctx: *mut c_void, msg: *const u8, msg_len: usize, out: *mut [u8; 65]) -> i32 {
    let imp = &*(ctx as *const Box<dyn SignerImpl>);
    let slice = std::slice::from_raw_parts(msg, msg_len);
    match imp.sign_message(slice) {
        Ok(sig) => { *out = sig; 0 }
        Err(_) => 1,
    }
}

unsafe extern "C" fn custom_sign_typed_data_hash(ctx: *mut c_void, hash: *const [u8; 32], out: *mut [u8; 65]) -> i32 {
    let imp = &*(ctx as *const Box<dyn SignerImpl>);
    match imp.sign_typed_data_hash(&*hash) {
        Ok(sig) => { *out = sig; 0 }
        Err(_) => 1,
    }
}

unsafe extern "C" fn custom_get_address(ctx: *mut c_void, out: *mut [u8; 20]) -> i32 {
    let imp = &*(ctx as *const Box<dyn SignerImpl>);
    *out = imp.get_address();
    0
}

unsafe extern "C" fn custom_sign_authorization(
    ctx: *mut c_void,
    chain_id: u64,
    address: *const [u8; 20],
    nonce: u64,
    out: *mut ffi::aa_authorization_t,
) -> i32 {
    let imp = &*(ctx as *const Box<dyn SignerImpl>);
    match imp.sign_authorization(chain_id, *address, nonce) {
        Ok(auth) => {
            (*out).chain_id = auth.chain_id;
            (*out).address = auth.address;
            (*out).nonce = auth.nonce;
            (*out).y_parity = auth.y_parity;
            (*out).r = auth.r;
            (*out).s = auth.s;
            0
        }
        Err(_) => 1,
    }
}

/// Default vtable — `sign_authorization` is `None` so the SDK falls back to
/// hashing the EIP-7702 auth tuple and calling `sign_hash`.
static CUSTOM_VTABLE: ffi::aa_signer_vtable = ffi::aa_signer_vtable {
    sign_hash: custom_sign_hash,
    sign_message: custom_sign_message,
    sign_typed_data_hash: custom_sign_typed_data_hash,
    get_address: custom_get_address,
    sign_authorization: None,
};

/// Vtable for custom signers that provide a native `sign_authorization`.
/// The SDK invokes the callback directly instead of falling back.
static CUSTOM_VTABLE_WITH_AUTH: ffi::aa_signer_vtable = ffi::aa_signer_vtable {
    sign_hash: custom_sign_hash,
    sign_message: custom_sign_message,
    sign_typed_data_hash: custom_sign_typed_data_hash,
    get_address: custom_get_address,
    sign_authorization: Some(custom_sign_authorization),
};

/// A signer handle (local private key or JSON-RPC endpoint).
///
/// Owns the underlying C handle; automatically destroyed on drop.
pub struct Signer {
    ptr: *mut ffi::aa_signer_t,
    custom_impl: Option<*mut c_void>,
}

unsafe impl Send for Signer {}

impl Signer {
    /// Create a signer from a 32-byte private key.
    pub fn local(private_key: &[u8; 32]) -> Result<Self> {
        let mut s: *mut ffi::aa_signer_t = ptr::null_mut();
        unsafe {
            error::check(ffi::aa_signer_local(private_key.as_ptr(), &mut s))?;
        }
        Ok(Self { ptr: s, custom_impl: None })
    }

    /// Create a signer with a randomly generated private key.
    pub fn generate() -> Result<Self> {
        let mut s: *mut ffi::aa_signer_t = ptr::null_mut();
        unsafe {
            error::check(ffi::aa_signer_generate(&mut s))?;
        }
        Ok(Self { ptr: s, custom_impl: None })
    }

    /// Create a signer backed by a JSON-RPC endpoint.
    pub fn rpc(rpc_url: &str, address: &[u8; 20]) -> Result<Self> {
        let c_url = CString::new(rpc_url).map_err(|_| AaError::InvalidUrl)?;
        let mut s: *mut ffi::aa_signer_t = ptr::null_mut();
        unsafe {
            error::check(ffi::aa_signer_rpc(c_url.as_ptr(), address.as_ptr(), &mut s))?;
        }
        Ok(Self { ptr: s, custom_impl: None })
    }

    /// Create a signer from a custom [`SignerImpl`] implementation.
    ///
    /// If the implementation overrides
    /// [`SignerImpl::provides_sign_authorization`] to return `true`, the FFI
    /// vtable is wired up with a native `sign_authorization` hook; otherwise
    /// the slot is left `NULL` and the SDK falls back to hashing the auth
    /// tuple and invoking `sign_hash`.
    pub fn custom<T: SignerImpl>(impl_: T) -> Result<Self> {
        let has_auth = impl_.provides_sign_authorization();
        let boxed: Box<Box<dyn SignerImpl>> = Box::new(Box::new(impl_));
        let raw = Box::into_raw(boxed) as *mut c_void;

        let vtable: *const ffi::aa_signer_vtable = if has_auth {
            &CUSTOM_VTABLE_WITH_AUTH
        } else {
            &CUSTOM_VTABLE
        };

        let mut s: *mut ffi::aa_signer_t = ptr::null_mut();
        unsafe {
            let status = ffi::aa_signer_custom(vtable, raw, &mut s);
            if status != ffi::AA_OK {
                let _ = Box::from_raw(raw as *mut Box<dyn SignerImpl>);
                return Err(error::from_status(status));
            }
        }
        Ok(Self { ptr: s, custom_impl: Some(raw) })
    }

    /// Sign an EIP-7702 authorization tuple `(chain_id, address, nonce)`.
    ///
    /// Works on any signer. For custom signers that did not provide a native
    /// `sign_authorization` hook, the SDK computes
    /// `keccak256(0x05 || rlp([chain_id, address, nonce]))` and signs the
    /// hash via `sign_hash` automatically.
    pub fn sign_authorization(
        &self,
        chain_id: u64,
        address: [u8; 20],
        nonce: u64,
    ) -> Result<Authorization> {
        let mut out = ffi::aa_authorization_t {
            chain_id: 0,
            address: [0u8; 20],
            nonce: 0,
            y_parity: 0,
            r: [0u8; 32],
            s: [0u8; 32],
        };
        unsafe {
            error::check(ffi::aa_signer_sign_authorization(
                self.ptr,
                chain_id,
                address.as_ptr(),
                nonce,
                &mut out,
            ))?;
        }
        Ok(Authorization {
            chain_id: out.chain_id,
            address: out.address,
            nonce: out.nonce,
            y_parity: out.y_parity,
            r: out.r,
            s: out.s,
        })
    }
}

impl Drop for Signer {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            unsafe {
                ffi::aa_signer_destroy(self.ptr);
            }
        }
        if let Some(raw) = self.custom_impl.take() {
            unsafe {
                let _ = Box::from_raw(raw as *mut Box<dyn SignerImpl>);
            }
        }
    }
}

/// SDK context holding RPC URLs, chain config, and middleware.
///
/// Owns the underlying C handle; automatically destroyed on drop.
pub struct Context {
    ptr: *mut ffi::aa_context_t,
}

// Context is safe to send across threads (the C library uses thread-local error state).
// Not Sync because aa_get_last_error() is thread-local.
unsafe impl Send for Context {}

impl Context {
    /// Create a new context. Pass empty strings for `rpc_url` / `bundler_url`
    /// to use the default ZeroDev URLs derived from `project_id`.
    pub fn new(
        project_id: &str,
        rpc_url: &str,
        bundler_url: &str,
        chain_id: u64,
        gas: GasMiddleware,
        paymaster: PaymasterMiddleware,
    ) -> Result<Self> {
        let c_project_id = CString::new(project_id).map_err(|_| AaError::InvalidUrl)?;
        let c_rpc_url = CString::new(rpc_url).map_err(|_| AaError::InvalidUrl)?;
        let c_bundler_url = CString::new(bundler_url).map_err(|_| AaError::InvalidUrl)?;

        let mut ctx: *mut ffi::aa_context_t = ptr::null_mut();
        unsafe {
            error::check(ffi::aa_context_create(
                c_project_id.as_ptr(),
                c_rpc_url.as_ptr(),
                c_bundler_url.as_ptr(),
                chain_id,
                &mut ctx,
            ))?;
        }

        // Set gas middleware
        match gas {
            GasMiddleware::ZeroDev => unsafe {
                error::check(ffi::aa_context_set_gas_middleware(
                    ctx,
                    Some(ffi::aa_gas_zerodev),
                ))?;
            },
        }

        // Set paymaster middleware (optional)
        match paymaster {
            PaymasterMiddleware::ZeroDev => unsafe {
                error::check(ffi::aa_context_set_paymaster_middleware(
                    ctx,
                    Some(ffi::aa_paymaster_zerodev),
                ))?;
            },
            PaymasterMiddleware::None => {}
        }

        Ok(Self { ptr: ctx })
    }

    /// Create a new Kernel account bound to this context.
    ///
    /// Both `self` (the Context) and `signer` must outlive the returned
    /// [`Account`] — enforced at compile time via the shared `'a` lifetime.
    pub fn new_account<'a>(
        &'a self,
        signer: &'a Signer,
        version: KernelVersion,
        index: u32,
    ) -> Result<Account<'a>> {
        let mut acc: *mut ffi::aa_account_t = ptr::null_mut();
        unsafe {
            error::check(ffi::aa_account_create(
                self.ptr,
                signer.ptr,
                version.to_c(),
                index,
                &mut acc,
            ))?;
        }
        Ok(Account {
            ptr: acc,
            _ctx: self,
            _signer: signer,
        })
    }

    /// Create a Kernel smart account using EIP-7702 delegation.
    ///
    /// The account's address is the signer's EOA address — there is no
    /// CREATE2, no init code, and no index. On the first UserOperation the
    /// SDK signs an authorization tuple `(chain_id, Kernel implementation for
    /// version, EOA nonce)` and attaches it via the `eip7702Auth` field;
    /// subsequent UserOps skip the authorization once delegation is installed
    /// on-chain.
    ///
    /// Today only [`KernelVersion::V3_3`] supports EIP-7702.
    pub fn new_account_7702<'a>(
        &'a self,
        signer: &'a Signer,
        version: KernelVersion,
    ) -> Result<Account<'a>> {
        let mut acc: *mut ffi::aa_account_t = ptr::null_mut();
        unsafe {
            error::check(ffi::aa_context_new_account_7702(
                self.ptr,
                signer.ptr,
                version.to_c(),
                &mut acc,
            ))?;
        }
        Ok(Account {
            ptr: acc,
            _ctx: self,
            _signer: signer,
        })
    }
}

impl Drop for Context {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            unsafe {
                ffi::aa_context_destroy(self.ptr);
            }
        }
    }
}

/// Kernel smart account with ECDSA validator.
///
/// Borrows both the parent [`Context`] and the [`Signer`] via a shared lifetime
/// — the compiler prevents use-after-free of either while any account is alive.
///
/// Audit F-09: prior versions only borrowed [`Context`], so dropping the
/// [`Signer`] while an [`Account`] was alive left the SDK's cached signer
/// pointer dangling. The next signing call read freed memory as the private
/// key. With the `'a` lifetime tying both `_ctx` and `_signer`, the compiler
/// now rejects that pattern at compile time:
///
/// ```compile_fail
/// use zerodev_aa::{Context, GasMiddleware, KernelVersion, PaymasterMiddleware, Signer};
/// # fn demo(ctx: &Context) -> Result<(), Box<dyn std::error::Error>> {
/// let signer = Signer::local(&[0x11u8; 32])?;
/// let account = ctx.new_account(&signer, KernelVersion::V3_3, 0)?;
/// drop(signer); // F-09 tripwire: must NOT compile while `account` is alive.
/// let _ = account.get_address()?;
/// # Ok(())
/// # }
/// ```
pub struct Account<'a> {
    ptr: *mut ffi::aa_account_t,
    _ctx: &'a Context,
    _signer: &'a Signer,
}

unsafe impl Send for Account<'_> {}

impl Account<'_> {
    /// Get the counterfactual smart account address.
    pub fn get_address(&self) -> Result<Address> {
        let mut addr = [0u8; 20];
        unsafe {
            error::check(ffi::aa_account_get_address(self.ptr, addr.as_mut_ptr()))?;
        }
        Ok(Address(addr))
    }

    /// Send a UserOperation through the full pipeline (build, sponsor, sign, send).
    pub fn send_user_op(&self, calls: &[Call]) -> Result<Hash> {
        if calls.is_empty() {
            return Err(AaError::NoCalls);
        }

        let c_calls: Vec<ffi::aa_call_t> = calls
            .iter()
            .map(|c| ffi::aa_call_t {
                target: c.target.0,
                value_be: c.value,
                calldata: if c.calldata.is_empty() {
                    ptr::null()
                } else {
                    c.calldata.as_ptr()
                },
                calldata_len: c.calldata.len(),
            })
            .collect();

        let mut hash = [0u8; 32];
        unsafe {
            error::check(ffi::aa_send_userop(
                self.ptr,
                c_calls.as_ptr(),
                c_calls.len(),
                hash.as_mut_ptr(),
            ))?;
        }
        Ok(Hash(hash))
    }

    /// Wait for a UserOp to be included on-chain, returning the full receipt.
    /// Pass 0 for `timeout_ms` to use default (60s), 0 for `poll_interval_ms` to use default (2s).
    pub fn wait_for_user_operation_receipt(
        &self,
        userop_hash: &Hash,
        timeout_ms: u32,
        poll_interval_ms: u32,
    ) -> Result<UserOperationReceipt> {
        let mut json_ptr: *mut c_char = ptr::null_mut();
        let mut json_len: usize = 0;
        unsafe {
            error::check(ffi::aa_wait_for_user_operation_receipt(
                self.ptr,
                userop_hash.0.as_ptr(),
                timeout_ms,
                poll_interval_ms,
                &mut json_ptr,
                &mut json_len,
            ))?;

            let s = std::str::from_utf8_unchecked(std::slice::from_raw_parts(
                json_ptr as *const u8,
                json_len,
            ))
            .to_owned();
            ffi::aa_free(json_ptr as *mut _);
            Ok(UserOperationReceipt::from_json(s))
        }
    }

    /// Build a UserOperation from calls (low-level API).
    pub fn build_user_op(&self, calls: &[Call]) -> Result<UserOp<'_>> {
        if calls.is_empty() {
            return Err(AaError::NoCalls);
        }

        let c_calls: Vec<ffi::aa_call_t> = calls
            .iter()
            .map(|c| ffi::aa_call_t {
                target: c.target.0,
                value_be: c.value,
                calldata: if c.calldata.is_empty() {
                    ptr::null()
                } else {
                    c.calldata.as_ptr()
                },
                calldata_len: c.calldata.len(),
            })
            .collect();

        let mut op: *mut ffi::aa_userop_t = ptr::null_mut();
        unsafe {
            error::check(ffi::aa_userop_build(
                self.ptr,
                c_calls.as_ptr(),
                c_calls.len(),
                &mut op,
            ))?;
        }
        Ok(UserOp {
            ptr: op,
            _account: self,
        })
    }
}

impl Drop for Account<'_> {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            unsafe {
                ffi::aa_account_destroy(self.ptr);
            }
        }
    }
}

/// A UserOperation handle (low-level API).
///
/// Borrows the parent [`Account`] — dropped automatically.
pub struct UserOp<'a> {
    ptr: *mut ffi::aa_userop_t,
    _account: &'a Account<'a>,
}

impl<'a> UserOp<'a> {
    /// Compute the UserOp hash.
    pub fn hash(&self, account: &Account<'_>) -> Result<Hash> {
        let mut hash = [0u8; 32];
        unsafe {
            error::check(ffi::aa_userop_hash(
                self.ptr,
                account.ptr,
                hash.as_mut_ptr(),
            ))?;
        }
        Ok(Hash(hash))
    }

    /// Sign the UserOp with the account's ECDSA key.
    pub fn sign(&self, account: &Account<'_>) -> Result<()> {
        unsafe { error::check(ffi::aa_userop_sign(self.ptr, account.ptr)) }
    }

    /// Serialize the UserOp to JSON.
    pub fn to_json(&self) -> Result<String> {
        let mut json_ptr: *mut c_char = ptr::null_mut();
        let mut json_len: usize = 0;
        unsafe {
            error::check(ffi::aa_userop_to_json(
                self.ptr,
                &mut json_ptr,
                &mut json_len,
            ))?;

            let s = std::str::from_utf8_unchecked(std::slice::from_raw_parts(
                json_ptr as *const u8,
                json_len,
            ))
            .to_owned();
            ffi::aa_free(json_ptr as *mut _);
            Ok(s)
        }
    }

    /// Apply gas estimates from a JSON response.
    pub fn apply_gas_json(&self, gas_json: &str) -> Result<()> {
        let c_json = CString::new(gas_json).map_err(|_| AaError::InvalidHex)?;
        unsafe {
            error::check(ffi::aa_userop_apply_gas_json(
                self.ptr,
                c_json.as_ptr(),
                gas_json.len(),
            ))
        }
    }

    /// Apply paymaster data from a JSON response.
    pub fn apply_paymaster_json(&self, pm_json: &str) -> Result<()> {
        let c_json = CString::new(pm_json).map_err(|_| AaError::InvalidHex)?;
        unsafe {
            error::check(ffi::aa_userop_apply_paymaster_json(
                self.ptr,
                c_json.as_ptr(),
                pm_json.len(),
            ))
        }
    }
}

impl Drop for UserOp<'_> {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            unsafe {
                ffi::aa_userop_destroy(self.ptr);
            }
        }
    }
}
