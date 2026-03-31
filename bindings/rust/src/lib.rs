mod ffi;
pub mod error;
pub mod types;

use std::ffi::CString;
use std::os::raw::{c_char, c_void};
use std::ptr;

pub use error::{AaError, Result};
pub use types::{Address, Call, GasMiddleware, Hash, KernelVersion, PaymasterMiddleware, UserOperationReceipt};

/// Trait for implementing custom signers (Privy, HSM, MPC, etc.).
pub trait SignerImpl: Send + 'static {
    fn sign_hash(&self, hash: &[u8; 32]) -> std::result::Result<[u8; 65], Box<dyn std::error::Error>>;
    fn sign_message(&self, msg: &[u8]) -> std::result::Result<[u8; 65], Box<dyn std::error::Error>>;
    fn sign_typed_data_hash(&self, hash: &[u8; 32]) -> std::result::Result<[u8; 65], Box<dyn std::error::Error>>;
    fn get_address(&self) -> [u8; 20];
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

static CUSTOM_VTABLE: ffi::aa_signer_vtable = ffi::aa_signer_vtable {
    sign_hash: custom_sign_hash,
    sign_message: custom_sign_message,
    sign_typed_data_hash: custom_sign_typed_data_hash,
    get_address: custom_get_address,
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
    pub fn custom<T: SignerImpl>(impl_: T) -> Result<Self> {
        let boxed: Box<Box<dyn SignerImpl>> = Box::new(Box::new(impl_));
        let raw = Box::into_raw(boxed) as *mut c_void;

        let mut s: *mut ffi::aa_signer_t = ptr::null_mut();
        unsafe {
            let status = ffi::aa_signer_custom(&CUSTOM_VTABLE, raw, &mut s);
            if status != ffi::AA_OK {
                let _ = Box::from_raw(raw as *mut Box<dyn SignerImpl>);
                return Err(error::from_status(status));
            }
        }
        Ok(Self { ptr: s, custom_impl: Some(raw) })
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
    pub fn new_account(
        &self,
        signer: &Signer,
        version: KernelVersion,
        index: u32,
    ) -> Result<Account<'_>> {
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
/// Borrows the parent [`Context`] via lifetime — the compiler prevents
/// use-after-free of the context while any account is alive.
pub struct Account<'ctx> {
    ptr: *mut ffi::aa_account_t,
    _ctx: &'ctx Context,
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
