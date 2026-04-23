"""Signer — wraps an opaque signer handle."""

import ctypes
from typing import Protocol, runtime_checkable

from ._ffi import (
    _lib, _Signer, AaSignerVTable, AaAuthorizationT,
    SIGN_HASH_FN, SIGN_MESSAGE_FN, SIGN_TYPED_DATA_HASH_FN, GET_ADDRESS_FN,
    SIGN_AUTHORIZATION_FN,
)
from .error import check
from .types import Authorization


@runtime_checkable
class SignerImpl(Protocol):
    """Interface for custom signer implementations (Privy, HSM, MPC, etc.).

    The required methods are listed below. An optional ``sign_authorization``
    method may also be provided to produce an EIP-7702 authorization tuple
    natively. If omitted, the SDK falls back to signing
    ``keccak256(0x05 || rlp([chainId, address, nonce]))`` with ``sign_hash``.
    """

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

    # Optional — duck-typed. Implementations that CAN natively sign EIP-7702
    # authorizations should add:
    #
    #     def sign_authorization(self, chain_id: int, address: bytes,
    #                            nonce: int) -> Authorization | bytes:
    #         ...
    #
    # Return either a fully-populated ``Authorization`` (chain_id / address /
    # nonce echoed back, y_parity + r + s set) or a 65-byte compact signature
    # (r || s || v) that the binding will unpack for you.


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
        """Create a signer from a custom SignerImpl implementation.

        If ``impl`` defines a callable ``sign_authorization(chain_id, address,
        nonce)`` attribute, it is wired into the C vtable so EIP-7702 auth
        tuples are signed natively. Otherwise the SDK computes
        ``keccak256(0x05 || rlp([chainId, address, nonce]))`` and signs it via
        ``sign_hash``.
        """

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

        # Optional EIP-7702 authorization hook — duck-typed. Only populate the
        # vtable slot if the impl actually provides one; a NULL pointer tells
        # the SDK to use the default hash-and-sign fallback.
        user_sign_auth = getattr(impl, "sign_authorization", None)
        if callable(user_sign_auth):
            def _sign_authorization(ctx, chain_id, addr_ptr, nonce, out_ptr):
                try:
                    addr = bytes(addr_ptr[:20])
                    result = user_sign_auth(chain_id, addr, nonce)
                    # Accept either an Authorization or a raw 65-byte compact sig.
                    if isinstance(result, Authorization):
                        auth = result
                    elif isinstance(result, (bytes, bytearray)) and len(result) == 65:
                        r = bytes(result[0:32])
                        s = bytes(result[32:64])
                        v = result[64]
                        y_parity = v if v in (0, 1) else (v - 27) & 1
                        auth = Authorization(
                            chain_id=chain_id, address=addr, nonce=nonce,
                            y_parity=y_parity, r=r, s=s,
                        )
                    else:
                        return 1
                    if len(auth.address) != 20 or len(auth.r) != 32 or len(auth.s) != 32:
                        return 1
                    out = out_ptr.contents
                    out.chain_id = auth.chain_id
                    out.nonce = auth.nonce
                    out.y_parity = auth.y_parity
                    for i in range(20):
                        out.address[i] = auth.address[i]
                    for i in range(32):
                        out.r[i] = auth.r[i]
                        out.s[i] = auth.s[i]
                    return 0
                except Exception:
                    return 1
            cb_sign_auth = SIGN_AUTHORIZATION_FN(_sign_authorization)
        else:
            cb_sign_auth = ctypes.cast(None, SIGN_AUTHORIZATION_FN)

        vtable = AaSignerVTable(
            cb_sign_hash, cb_sign_message, cb_sign_typed, cb_get_addr, cb_sign_auth,
        )

        ptr = ctypes.POINTER(_Signer)()
        check(_lib.aa_signer_custom(ctypes.byref(vtable), None, ctypes.byref(ptr)))

        # Store all references on the Signer to prevent GC
        return Signer(ptr, _prevent_gc=(
            vtable, cb_sign_hash, cb_sign_message, cb_sign_typed, cb_get_addr,
            cb_sign_auth, impl,
        ))

    def sign_authorization(
        self, chain_id: int, address: bytes, nonce: int,
    ) -> Authorization:
        """Sign an EIP-7702 authorization tuple ``(chain_id, address, nonce)``.

        ``address`` is the delegation target (20 bytes). Works on any signer —
        custom signers may implement this natively via their ``SignerImpl``
        protocol; otherwise the SDK hashes + signs under the hood.
        """
        if len(address) != 20:
            raise ValueError(f"address must be 20 bytes, got {len(address)}")
        addr = (ctypes.c_uint8 * 20)(*address)
        out = AaAuthorizationT()
        check(_lib.aa_signer_sign_authorization(
            self._ptr, ctypes.c_uint64(chain_id), addr,
            ctypes.c_uint64(nonce), ctypes.byref(out),
        ))
        return Authorization(
            chain_id=out.chain_id,
            address=bytes(out.address),
            nonce=out.nonce,
            y_parity=out.y_parity,
            r=bytes(out.r),
            s=bytes(out.s),
        )

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
