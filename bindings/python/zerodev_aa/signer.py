"""Signer — wraps an opaque signer handle."""

import ctypes
from typing import Protocol, runtime_checkable

from ._ffi import (
    _lib, _Signer, AaSignerVTable,
    SIGN_HASH_FN, SIGN_MESSAGE_FN, SIGN_TYPED_DATA_HASH_FN, GET_ADDRESS_FN,
)
from .error import check


@runtime_checkable
class SignerImpl(Protocol):
    """Interface for custom signer implementations (Privy, HSM, MPC, etc.)."""

    def sign_hash(self, hash: bytes) -> bytes:
        """Sign a 32-byte hash. Return 65-byte signature."""
        ...

    def sign_message(self, msg: bytes) -> bytes:
        """Sign a message with EIP-191 wrapping. Return 65-byte signature."""
        ...

    def sign_typed_data_hash(self, hash: bytes) -> bytes:
        """Sign an EIP-712 typed data hash. Return 65-byte signature."""
        ...

    def get_address(self) -> bytes:
        """Return the 20-byte signer address."""
        ...


class Signer:
    """Opaque signer handle. Create via local(), generate(), rpc(), or custom()."""

    def __init__(self, ptr: ctypes.POINTER(_Signer), _prevent_gc=None):
        self._ptr = ptr
        self._prevent_gc = _prevent_gc  # prevent GC of callbacks

    @staticmethod
    def local(private_key: bytes) -> "Signer":
        """Create a signer from a 32-byte private key."""
        if len(private_key) != 32:
            raise ValueError(f"private_key must be 32 bytes, got {len(private_key)}")
        pk = (ctypes.c_uint8 * 32)(*private_key)
        ptr = ctypes.POINTER(_Signer)()
        check(_lib.aa_signer_local(pk, ctypes.byref(ptr)))
        return Signer(ptr)

    @staticmethod
    def generate() -> "Signer":
        """Create a signer with a randomly generated private key."""
        ptr = ctypes.POINTER(_Signer)()
        check(_lib.aa_signer_generate(ctypes.byref(ptr)))
        return Signer(ptr)

    @staticmethod
    def rpc(url: str, address: bytes) -> "Signer":
        """Create a JSON-RPC signer (Privy, custodial wallets, etc.)."""
        if len(address) != 20:
            raise ValueError(f"address must be 20 bytes, got {len(address)}")
        addr = (ctypes.c_uint8 * 20)(*address)
        ptr = ctypes.POINTER(_Signer)()
        check(_lib.aa_signer_rpc(url.encode(), addr, ctypes.byref(ptr)))
        return Signer(ptr)

    @staticmethod
    def custom(impl: SignerImpl) -> "Signer":
        """Create a signer from a custom SignerImpl implementation."""

        def _sign_hash(ctx, hash_ptr, out_ptr):
            try:
                h = bytes(hash_ptr[:32])
                sig = impl.sign_hash(h)
                if len(sig) != 65:
                    return 1
                for i in range(65):
                    out_ptr[i] = sig[i]
                return 0
            except Exception:
                return 1

        def _sign_message(ctx, msg_ptr, msg_len, out_ptr):
            try:
                msg = bytes(msg_ptr[:msg_len])
                sig = impl.sign_message(msg)
                if len(sig) != 65:
                    return 1
                for i in range(65):
                    out_ptr[i] = sig[i]
                return 0
            except Exception:
                return 1

        def _sign_typed_data_hash(ctx, hash_ptr, out_ptr):
            try:
                h = bytes(hash_ptr[:32])
                sig = impl.sign_typed_data_hash(h)
                if len(sig) != 65:
                    return 1
                for i in range(65):
                    out_ptr[i] = sig[i]
                return 0
            except Exception:
                return 1

        def _get_address(ctx, out_ptr):
            try:
                addr = impl.get_address()
                if len(addr) != 20:
                    return 1
                for i in range(20):
                    out_ptr[i] = addr[i]
                return 0
            except Exception:
                return 1

        # Create ctypes callbacks — MUST keep references to prevent GC
        cb_sign_hash = SIGN_HASH_FN(_sign_hash)
        cb_sign_message = SIGN_MESSAGE_FN(_sign_message)
        cb_sign_typed = SIGN_TYPED_DATA_HASH_FN(_sign_typed_data_hash)
        cb_get_addr = GET_ADDRESS_FN(_get_address)

        vtable = AaSignerVTable(cb_sign_hash, cb_sign_message, cb_sign_typed, cb_get_addr)

        ptr = ctypes.POINTER(_Signer)()
        check(_lib.aa_signer_custom(ctypes.byref(vtable), None, ctypes.byref(ptr)))

        # Store all references on the Signer to prevent GC
        return Signer(ptr, _prevent_gc=(vtable, cb_sign_hash, cb_sign_message, cb_sign_typed, cb_get_addr, impl))

    def close(self) -> None:
        if self._ptr:
            _lib.aa_signer_destroy(self._ptr)
            self._ptr = None
            self._prevent_gc = None

    def __enter__(self) -> "Signer":
        return self

    def __exit__(self, *args) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()
