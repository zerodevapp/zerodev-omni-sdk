"""Account — Kernel smart account operations."""

import ctypes
import json as _json

from ._ffi import _lib, _Context, _Signer, _Account, _UserOp, AaCallT
from .error import check
from .types import Call, Address, Hash


class Account:
    """Kernel smart account."""

    def __init__(self, ptr: ctypes.POINTER(_Account)):
        self._ptr = ptr

    @staticmethod
    def _create(ctx_ptr, signer_ptr, version: int, index: int) -> "Account":
        ptr = ctypes.POINTER(_Account)()
        check(_lib.aa_account_create(ctx_ptr, signer_ptr, version, index, ctypes.byref(ptr)))
        return Account(ptr)

    def get_address(self) -> Address:
        """Get the counterfactual smart account address."""
        buf = (ctypes.c_uint8 * 20)()
        check(_lib.aa_account_get_address(self._ptr, buf))
        return Address(bytes(buf))

    def get_address_hex(self) -> str:
        """Get address as 0x-prefixed hex string."""
        return self.get_address().hex()

    def send_user_op(self, calls: list[Call]) -> Hash:
        """Send a UserOperation through the full pipeline (build, sponsor, sign, send)."""
        if not calls:
            raise ValueError("calls list cannot be empty")
        c_calls = _marshal_calls(calls)
        hash_buf = (ctypes.c_uint8 * 32)()
        check(_lib.aa_send_userop(self._ptr, c_calls, len(calls), hash_buf))
        return Hash(bytes(hash_buf))

    def wait_for_receipt(self, userop_hash: Hash, timeout_ms: int = 0, poll_ms: int = 0) -> dict:
        """Wait for UserOp to be included on-chain. Returns parsed receipt dict."""
        json_ptr = ctypes.c_char_p()
        json_len = ctypes.c_size_t()
        h = (ctypes.c_uint8 * 32)(*userop_hash.bytes)
        check(_lib.aa_wait_for_user_operation_receipt(
            self._ptr, h, timeout_ms, poll_ms,
            ctypes.byref(json_ptr), ctypes.byref(json_len),
        ))
        raw = json_ptr.value[:json_len.value]
        _lib.aa_free(json_ptr)
        return _json.loads(raw)

    def build_user_op(self, calls: list[Call]) -> "UserOp":
        """Build a UserOperation from calls (low-level API)."""
        if not calls:
            raise ValueError("calls list cannot be empty")
        c_calls = _marshal_calls(calls)
        ptr = ctypes.POINTER(_UserOp)()
        check(_lib.aa_userop_build(self._ptr, c_calls, len(calls), ctypes.byref(ptr)))
        return UserOp(ptr, self)

    def close(self) -> None:
        if self._ptr:
            _lib.aa_account_destroy(self._ptr)
            self._ptr = None

    def __enter__(self) -> "Account":
        return self

    def __exit__(self, *args) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()


class UserOp:
    """A UserOperation handle (low-level API)."""

    def __init__(self, ptr: ctypes.POINTER(_UserOp), account: Account):
        self._ptr = ptr
        self._account = account

    def hash(self) -> Hash:
        buf = (ctypes.c_uint8 * 32)()
        check(_lib.aa_userop_hash(self._ptr, self._account._ptr, buf))
        return Hash(bytes(buf))

    def sign(self) -> None:
        check(_lib.aa_userop_sign(self._ptr, self._account._ptr))

    def to_json(self) -> str:
        json_ptr = ctypes.c_char_p()
        json_len = ctypes.c_size_t()
        check(_lib.aa_userop_to_json(self._ptr, ctypes.byref(json_ptr), ctypes.byref(json_len)))
        result = json_ptr.value[:json_len.value].decode()
        _lib.aa_free(json_ptr)
        return result

    def apply_gas_json(self, gas_json: str) -> None:
        b = gas_json.encode()
        check(_lib.aa_userop_apply_gas_json(self._ptr, b, len(b)))

    def apply_paymaster_json(self, pm_json: str) -> None:
        b = pm_json.encode()
        check(_lib.aa_userop_apply_paymaster_json(self._ptr, b, len(b)))

    def close(self) -> None:
        if self._ptr:
            _lib.aa_userop_destroy(self._ptr)
            self._ptr = None

    def __enter__(self) -> "UserOp":
        return self

    def __exit__(self, *args) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()


def _marshal_calls(calls: list[Call]) -> ctypes.Array:
    """Convert Python Call list to C aa_call_t array."""
    arr = (AaCallT * len(calls))()
    for i, call in enumerate(calls):
        if len(call.target) != 20:
            raise ValueError(f"call target must be 20 bytes, got {len(call.target)}")
        if len(call.value) != 32:
            raise ValueError(f"call value must be 32 bytes, got {len(call.value)}")
        for j in range(20):
            arr[i].target[j] = call.target[j]
        for j in range(32):
            arr[i].value_be[j] = call.value[j]
        if call.calldata:
            cd = (ctypes.c_uint8 * len(call.calldata))(*call.calldata)
            arr[i].calldata = ctypes.cast(cd, ctypes.POINTER(ctypes.c_uint8))
            arr[i].calldata_len = len(call.calldata)
        else:
            arr[i].calldata = None
            arr[i].calldata_len = 0
    return arr
