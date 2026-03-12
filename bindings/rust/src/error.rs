use std::ffi::CStr;
use thiserror::Error;

use crate::ffi;

pub type Result<T> = core::result::Result<T, AaError>;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
#[non_exhaustive]
pub enum AaError {
    #[error("null output pointer (code 1)")]
    NullOutPtr,
    #[error("invalid URL (code 2)")]
    InvalidUrl,
    #[error("out of memory (code 3)")]
    OutOfMemory,
    #[error("invalid private key (code 4)")]
    InvalidPrivateKey,
    #[error("invalid kernel version (code 5)")]
    InvalidKernelVersion,
    #[error("null context (code 6)")]
    NullContext,
    #[error("null account (code 7)")]
    NullAccount,
    #[error("null userop (code 8)")]
    NullUserOp,
    #[error("get address failed: {0}")]
    GetAddressFailed(String),
    #[error("build userop failed: {0}")]
    BuildUserOpFailed(String),
    #[error("hash userop failed: {0}")]
    HashUserOpFailed(String),
    #[error("sign userop failed: {0}")]
    SignUserOpFailed(String),
    #[error("send userop failed: {0}")]
    SendUserOpFailed(String),
    #[error("estimate gas failed: {0}")]
    EstimateGasFailed(String),
    #[error("paymaster failed: {0}")]
    PaymasterFailed(String),
    #[error("no calls provided (code 16)")]
    NoCalls,
    #[error("invalid hex (code 17)")]
    InvalidHex,
    #[error("apply JSON failed: {0}")]
    ApplyJsonFailed(String),
    #[error("serialize failed: {0}")]
    SerializeFailed(String),
    #[error("no gas middleware set (code 20)")]
    NoGasMiddleware,
    #[error("no paymaster middleware set (code 21)")]
    NoPaymasterMiddleware,
    #[error("receipt polling timed out: {0}")]
    ReceiptTimeout(String),
    #[error("receipt polling failed: {0}")]
    ReceiptFailed(String),
    #[error("unknown error (code {0}): {1}")]
    Unknown(i32, String),
}

/// Read the thread-local error message from the C library.
fn last_error_message() -> String {
    unsafe {
        let ptr = ffi::aa_get_last_error();
        if ptr.is_null() {
            return String::new();
        }
        CStr::from_ptr(ptr).to_string_lossy().into_owned()
    }
}

/// Convert a non-OK aa_status code into an AaError, pulling the detail string
/// from aa_get_last_error() for codes that typically carry one.
pub(crate) fn from_status(code: ffi::aa_status) -> AaError {
    let msg = last_error_message();
    match code {
        1 => AaError::NullOutPtr,
        2 => AaError::InvalidUrl,
        3 => AaError::OutOfMemory,
        4 => AaError::InvalidPrivateKey,
        5 => AaError::InvalidKernelVersion,
        6 => AaError::NullContext,
        7 => AaError::NullAccount,
        8 => AaError::NullUserOp,
        9 => AaError::GetAddressFailed(msg),
        10 => AaError::BuildUserOpFailed(msg),
        11 => AaError::HashUserOpFailed(msg),
        12 => AaError::SignUserOpFailed(msg),
        13 => AaError::SendUserOpFailed(msg),
        14 => AaError::EstimateGasFailed(msg),
        15 => AaError::PaymasterFailed(msg),
        16 => AaError::NoCalls,
        17 => AaError::InvalidHex,
        18 => AaError::ApplyJsonFailed(msg),
        19 => AaError::SerializeFailed(msg),
        20 => AaError::NoGasMiddleware,
        21 => AaError::NoPaymasterMiddleware,
        22 => AaError::ReceiptTimeout(msg),
        23 => AaError::ReceiptFailed(msg),
        other => AaError::Unknown(other, msg),
    }
}

/// Check an aa_status code, returning Ok(()) or an appropriate error.
pub(crate) fn check(code: ffi::aa_status) -> Result<()> {
    if code == ffi::AA_OK {
        Ok(())
    } else {
        Err(from_status(code))
    }
}
