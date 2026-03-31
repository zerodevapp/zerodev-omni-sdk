#![allow(non_camel_case_types)]

use std::os::raw::{c_char, c_void};

pub(crate) type aa_status = i32;

pub(crate) const AA_OK: aa_status = 0;

#[repr(C)]
pub(crate) struct aa_context_t {
    _opaque: [u8; 0],
}

#[repr(C)]
pub(crate) struct aa_account_t {
    _opaque: [u8; 0],
}

#[repr(C)]
pub(crate) struct aa_signer_t {
    _opaque: [u8; 0],
}

#[repr(C)]
pub(crate) struct aa_userop_t {
    _opaque: [u8; 0],
}

#[repr(C)]
pub(crate) struct aa_call_t {
    pub target: [u8; 20],
    pub value_be: [u8; 32],
    pub calldata: *const u8,
    pub calldata_len: usize,
}

#[repr(C)]
pub(crate) struct aa_gas_prices_t {
    pub max_fee_per_gas: u64,
    pub max_priority_fee_per_gas: u64,
}

#[repr(C)]
pub(crate) struct aa_paymaster_result_t {
    pub paymaster: [u8; 20],
    pub paymaster_verification_gas_limit: u64,
    pub paymaster_post_op_gas_limit: u64,
    pub paymaster_data: *mut u8,
    pub paymaster_data_len: usize,
}

pub(crate) type aa_gas_price_fn = Option<
    unsafe extern "C" fn(ctx: *mut aa_context_t, out: *mut aa_gas_prices_t) -> aa_status,
>;

pub(crate) type aa_paymaster_fn = Option<
    unsafe extern "C" fn(
        ctx: *mut aa_context_t,
        userop_json: *const c_char,
        userop_json_len: usize,
        entry_point: *const c_char,
        chain_id: u64,
        phase: i32,
        out: *mut aa_paymaster_result_t,
    ) -> aa_status,
>;

#[repr(C)]
pub(crate) struct aa_signer_vtable {
    pub sign_hash: unsafe extern "C" fn(*mut c_void, *const [u8; 32], *mut [u8; 65]) -> i32,
    pub sign_message: unsafe extern "C" fn(*mut c_void, *const u8, usize, *mut [u8; 65]) -> i32,
    pub sign_typed_data_hash: unsafe extern "C" fn(*mut c_void, *const [u8; 32], *mut [u8; 65]) -> i32,
    pub get_address: unsafe extern "C" fn(*mut c_void, *mut [u8; 20]) -> i32,
}

extern "C" {
    pub(crate) fn aa_context_create(
        project_id: *const c_char,
        rpc_url: *const c_char,
        bundler_url: *const c_char,
        chain_id: u64,
        out: *mut *mut aa_context_t,
    ) -> aa_status;

    pub(crate) fn aa_context_set_gas_middleware(
        ctx: *mut aa_context_t,
        middleware: aa_gas_price_fn,
    ) -> aa_status;

    pub(crate) fn aa_context_set_paymaster_middleware(
        ctx: *mut aa_context_t,
        middleware: aa_paymaster_fn,
    ) -> aa_status;

    pub(crate) fn aa_context_destroy(ctx: *mut aa_context_t) -> aa_status;

    // Built-in middleware
    pub(crate) fn aa_gas_zerodev(
        ctx: *mut aa_context_t,
        out: *mut aa_gas_prices_t,
    ) -> aa_status;

    pub(crate) fn aa_paymaster_zerodev(
        ctx: *mut aa_context_t,
        userop_json: *const c_char,
        userop_json_len: usize,
        entry_point: *const c_char,
        chain_id: u64,
        phase: i32,
        out: *mut aa_paymaster_result_t,
    ) -> aa_status;

    // Signer
    pub(crate) fn aa_signer_local(
        private_key: *const u8,
        out: *mut *mut aa_signer_t,
    ) -> aa_status;

    pub(crate) fn aa_signer_rpc(
        rpc_url: *const c_char,
        address: *const u8,
        out: *mut *mut aa_signer_t,
    ) -> aa_status;

    pub(crate) fn aa_signer_custom(
        vtable: *const aa_signer_vtable,
        ctx: *mut c_void,
        out: *mut *mut aa_signer_t,
    ) -> aa_status;

    pub(crate) fn aa_signer_destroy(signer: *mut aa_signer_t);

    // Account
    pub(crate) fn aa_account_create(
        ctx: *mut aa_context_t,
        signer: *mut aa_signer_t,
        version: i32,
        index: u32,
        out: *mut *mut aa_account_t,
    ) -> aa_status;

    pub(crate) fn aa_account_get_address(
        account: *mut aa_account_t,
        addr_out: *mut u8,
    ) -> aa_status;

    pub(crate) fn aa_account_destroy(account: *mut aa_account_t) -> aa_status;

    // High-level
    pub(crate) fn aa_send_userop(
        account: *mut aa_account_t,
        calls: *const aa_call_t,
        calls_len: usize,
        hash_out: *mut u8,
    ) -> aa_status;

    // Low-level UserOp
    pub(crate) fn aa_userop_build(
        account: *mut aa_account_t,
        calls: *const aa_call_t,
        calls_len: usize,
        out: *mut *mut aa_userop_t,
    ) -> aa_status;

    pub(crate) fn aa_userop_hash(
        op: *mut aa_userop_t,
        account: *mut aa_account_t,
        hash_out: *mut u8,
    ) -> aa_status;

    pub(crate) fn aa_userop_sign(
        op: *mut aa_userop_t,
        account: *mut aa_account_t,
    ) -> aa_status;

    pub(crate) fn aa_userop_to_json(
        op: *mut aa_userop_t,
        json_out: *mut *mut c_char,
        len_out: *mut usize,
    ) -> aa_status;

    pub(crate) fn aa_userop_apply_gas_json(
        op: *mut aa_userop_t,
        gas_json: *const c_char,
        gas_json_len: usize,
    ) -> aa_status;

    pub(crate) fn aa_userop_apply_paymaster_json(
        op: *mut aa_userop_t,
        pm_json: *const c_char,
        pm_json_len: usize,
    ) -> aa_status;

    pub(crate) fn aa_userop_destroy(op: *mut aa_userop_t) -> aa_status;

    // Receipt
    pub(crate) fn aa_wait_for_user_operation_receipt(
        account: *mut aa_account_t,
        userop_hash: *const u8,
        timeout_ms: u32,
        poll_interval_ms: u32,
        json_out: *mut *mut c_char,
        json_len_out: *mut usize,
    ) -> aa_status;

    // Memory
    pub(crate) fn aa_free(ptr: *mut c_void);

    // Error
    pub(crate) fn aa_get_last_error() -> *const c_char;
}
