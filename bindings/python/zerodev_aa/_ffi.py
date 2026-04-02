"""Low-level ctypes declarations for the ZeroDev AA C library."""

import ctypes
import ctypes.util
import os
import platform
import sys
from pathlib import Path


def _find_lib() -> str:
    """Find libzerodev_aa dynamic library."""
    ext = ".dylib" if platform.system() == "Darwin" else ".so"
    name = f"libzerodev_aa{ext}"

    # 1. ZERODEV_SDK_ROOT env var
    sdk_root = os.environ.get("ZERODEV_SDK_ROOT")
    if sdk_root:
        p = Path(sdk_root) / "zig-out" / "lib" / name
        if p.exists():
            return str(p)

    # 2. Relative to this package (../../zig-out/lib from bindings/python/)
    pkg_dir = Path(__file__).resolve().parent
    for up in [pkg_dir.parent.parent / "zig-out" / "lib" / name,
               pkg_dir.parent.parent.parent / "zig-out" / "lib" / name]:
        if up.exists():
            return str(up)

    # 3. System library path
    found = ctypes.util.find_library("zerodev_aa")
    if found:
        return found

    raise OSError(
        f"Cannot find {name}. Set ZERODEV_SDK_ROOT or run 'make build' from the SDK root."
    )


_lib = ctypes.CDLL(_find_lib())

# ---------- Opaque types ----------

class _Context(ctypes.Structure):
    pass

class _Signer(ctypes.Structure):
    pass

class _Account(ctypes.Structure):
    pass

class _UserOp(ctypes.Structure):
    pass

# ---------- Data structures ----------

class AaCallT(ctypes.Structure):
    _fields_ = [
        ("target", ctypes.c_uint8 * 20),
        ("value_be", ctypes.c_uint8 * 32),
        ("calldata", ctypes.POINTER(ctypes.c_uint8)),
        ("calldata_len", ctypes.c_size_t),
    ]

class AaGasPricesT(ctypes.Structure):
    _fields_ = [
        ("max_fee_per_gas", ctypes.c_uint64),
        ("max_priority_fee_per_gas", ctypes.c_uint64),
    ]

class AaPaymasterResultT(ctypes.Structure):
    _fields_ = [
        ("paymaster", ctypes.c_uint8 * 20),
        ("paymaster_verification_gas_limit", ctypes.c_uint64),
        ("paymaster_post_op_gas_limit", ctypes.c_uint64),
        ("paymaster_data", ctypes.POINTER(ctypes.c_uint8)),
        ("paymaster_data_len", ctypes.c_size_t),
    ]

# Callback types for custom signer vtable
SIGN_HASH_FN = ctypes.CFUNCTYPE(
    ctypes.c_int, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint8), ctypes.POINTER(ctypes.c_uint8)
)
SIGN_MESSAGE_FN = ctypes.CFUNCTYPE(
    ctypes.c_int, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t, ctypes.POINTER(ctypes.c_uint8)
)
SIGN_TYPED_DATA_HASH_FN = ctypes.CFUNCTYPE(
    ctypes.c_int, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint8), ctypes.POINTER(ctypes.c_uint8)
)
GET_ADDRESS_FN = ctypes.CFUNCTYPE(
    ctypes.c_int, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint8)
)

class AaSignerVTable(ctypes.Structure):
    _fields_ = [
        ("sign_hash", SIGN_HASH_FN),
        ("sign_message", SIGN_MESSAGE_FN),
        ("sign_typed_data_hash", SIGN_TYPED_DATA_HASH_FN),
        ("get_address", GET_ADDRESS_FN),
    ]

# Gas/paymaster middleware function pointer types
GAS_PRICE_FN = ctypes.CFUNCTYPE(
    ctypes.c_int, ctypes.POINTER(_Context), ctypes.POINTER(AaGasPricesT)
)
PAYMASTER_FN = ctypes.CFUNCTYPE(
    ctypes.c_int, ctypes.POINTER(_Context), ctypes.c_char_p, ctypes.c_size_t,
    ctypes.c_char_p, ctypes.c_uint64, ctypes.c_int, ctypes.POINTER(AaPaymasterResultT)
)

# ---------- Function declarations ----------

# Context
_lib.aa_context_create.argtypes = [
    ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint64,
    ctypes.POINTER(ctypes.POINTER(_Context))
]
_lib.aa_context_create.restype = ctypes.c_int

_lib.aa_context_set_gas_middleware.argtypes = [ctypes.POINTER(_Context), ctypes.c_void_p]
_lib.aa_context_set_gas_middleware.restype = ctypes.c_int

_lib.aa_context_set_paymaster_middleware.argtypes = [ctypes.POINTER(_Context), ctypes.c_void_p]
_lib.aa_context_set_paymaster_middleware.restype = ctypes.c_int

_lib.aa_context_destroy.argtypes = [ctypes.POINTER(_Context)]
_lib.aa_context_destroy.restype = ctypes.c_int

# Built-in middleware
_lib.aa_gas_zerodev.argtypes = [ctypes.POINTER(_Context), ctypes.POINTER(AaGasPricesT)]
_lib.aa_gas_zerodev.restype = ctypes.c_int

_lib.aa_paymaster_zerodev.argtypes = [
    ctypes.POINTER(_Context), ctypes.c_char_p, ctypes.c_size_t,
    ctypes.c_char_p, ctypes.c_uint64, ctypes.c_int, ctypes.POINTER(AaPaymasterResultT)
]
_lib.aa_paymaster_zerodev.restype = ctypes.c_int

# Signer
_lib.aa_signer_local.argtypes = [ctypes.POINTER(ctypes.c_uint8), ctypes.POINTER(ctypes.POINTER(_Signer))]
_lib.aa_signer_local.restype = ctypes.c_int

_lib.aa_signer_generate.argtypes = [ctypes.POINTER(ctypes.POINTER(_Signer))]
_lib.aa_signer_generate.restype = ctypes.c_int

_lib.aa_signer_rpc.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint8), ctypes.POINTER(ctypes.POINTER(_Signer))]
_lib.aa_signer_rpc.restype = ctypes.c_int

_lib.aa_signer_custom.argtypes = [ctypes.POINTER(AaSignerVTable), ctypes.c_void_p, ctypes.POINTER(ctypes.POINTER(_Signer))]
_lib.aa_signer_custom.restype = ctypes.c_int

_lib.aa_signer_destroy.argtypes = [ctypes.POINTER(_Signer)]
_lib.aa_signer_destroy.restype = None

# Account
_lib.aa_account_create.argtypes = [
    ctypes.POINTER(_Context), ctypes.POINTER(_Signer), ctypes.c_int, ctypes.c_uint32,
    ctypes.POINTER(ctypes.POINTER(_Account))
]
_lib.aa_account_create.restype = ctypes.c_int

_lib.aa_account_get_address.argtypes = [ctypes.POINTER(_Account), ctypes.POINTER(ctypes.c_uint8)]
_lib.aa_account_get_address.restype = ctypes.c_int

_lib.aa_account_destroy.argtypes = [ctypes.POINTER(_Account)]
_lib.aa_account_destroy.restype = ctypes.c_int

# High-level
_lib.aa_send_userop.argtypes = [
    ctypes.POINTER(_Account), ctypes.POINTER(AaCallT), ctypes.c_size_t, ctypes.POINTER(ctypes.c_uint8)
]
_lib.aa_send_userop.restype = ctypes.c_int

# Low-level UserOp
_lib.aa_userop_build.argtypes = [
    ctypes.POINTER(_Account), ctypes.POINTER(AaCallT), ctypes.c_size_t,
    ctypes.POINTER(ctypes.POINTER(_UserOp))
]
_lib.aa_userop_build.restype = ctypes.c_int

_lib.aa_userop_hash.argtypes = [ctypes.POINTER(_UserOp), ctypes.POINTER(_Account), ctypes.POINTER(ctypes.c_uint8)]
_lib.aa_userop_hash.restype = ctypes.c_int

_lib.aa_userop_sign.argtypes = [ctypes.POINTER(_UserOp), ctypes.POINTER(_Account)]
_lib.aa_userop_sign.restype = ctypes.c_int

_lib.aa_userop_to_json.argtypes = [ctypes.POINTER(_UserOp), ctypes.POINTER(ctypes.c_char_p), ctypes.POINTER(ctypes.c_size_t)]
_lib.aa_userop_to_json.restype = ctypes.c_int

_lib.aa_userop_apply_gas_json.argtypes = [ctypes.POINTER(_UserOp), ctypes.c_char_p, ctypes.c_size_t]
_lib.aa_userop_apply_gas_json.restype = ctypes.c_int

_lib.aa_userop_apply_paymaster_json.argtypes = [ctypes.POINTER(_UserOp), ctypes.c_char_p, ctypes.c_size_t]
_lib.aa_userop_apply_paymaster_json.restype = ctypes.c_int

_lib.aa_userop_destroy.argtypes = [ctypes.POINTER(_UserOp)]
_lib.aa_userop_destroy.restype = ctypes.c_int

# Receipt
_lib.aa_wait_for_user_operation_receipt.argtypes = [
    ctypes.POINTER(_Account), ctypes.POINTER(ctypes.c_uint8),
    ctypes.c_uint32, ctypes.c_uint32,
    ctypes.POINTER(ctypes.c_char_p), ctypes.POINTER(ctypes.c_size_t)
]
_lib.aa_wait_for_user_operation_receipt.restype = ctypes.c_int

# Memory / Error
_lib.aa_free.argtypes = [ctypes.c_void_p]
_lib.aa_free.restype = None

_lib.aa_get_last_error.argtypes = []
_lib.aa_get_last_error.restype = ctypes.c_char_p
