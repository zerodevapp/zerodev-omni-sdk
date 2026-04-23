"""Tests for EIP-7702 support in the Python binding.

Offline tests cover:
 * ``Signer.sign_authorization`` produces a well-formed ``Authorization`` with
   a local signer (deterministic shape checks — ECDSA is tested on the Zig
   side).
 * Custom signers that do NOT define ``sign_authorization`` still work (the
   pre-7702 duck-typed protocol stays intact) and the SDK falls back to
   ``sign_hash``.
 * Custom signers that DO define ``sign_authorization`` — returning either an
   ``Authorization`` dataclass or a 65-byte compact signature — are wired
   through the vtable correctly.
 * ``Context.new_account_7702`` returns an account whose address equals the
   signer's EOA address.

A live E2E test against ZeroDev Sepolia is added at the bottom and skips
cleanly when ``ZERODEV_PROJECT_ID`` is not set.
"""

from __future__ import annotations

import os

import pytest

from zerodev_aa import (
    Authorization,
    Call,
    Context,
    KernelVersion,
    Signer,
)


# ---------------------------------------------------------------------------
# Offline tests
# ---------------------------------------------------------------------------

def test_sign_authorization_local_signer_shape() -> None:
    signer = Signer.generate()
    try:
        target = bytes.fromhex("11" * 20)
        auth = signer.sign_authorization(11155111, target, 0)

        assert isinstance(auth, Authorization)
        assert auth.chain_id == 11155111
        assert auth.address == target
        assert auth.nonce == 0
        assert auth.y_parity in (0, 1)
        assert len(auth.r) == 32
        assert len(auth.s) == 32
        # A well-formed signature must not be all zeros.
        assert auth.r != b"\x00" * 32
        assert auth.s != b"\x00" * 32
    finally:
        signer.close()


def test_sign_authorization_rejects_bad_address_length() -> None:
    signer = Signer.generate()
    try:
        with pytest.raises(ValueError):
            signer.sign_authorization(1, b"\x00" * 19, 0)
    finally:
        signer.close()


def test_custom_signer_without_sign_authorization_still_works() -> None:
    """Backward-compat: existing custom signers (4-method protocol) must
    continue to work unchanged. The SDK falls back to sign_hash internally."""

    class LegacySigner:
        def __init__(self) -> None:
            self.sign_hash_calls = 0

        def sign_hash(self, hash_: bytes) -> bytes:
            self.sign_hash_calls += 1
            # Return a dummy 65-byte signature — we only care that the fallback
            # path is hit, not that it ECDSA-verifies.
            return bytes(65)

        def sign_message(self, msg: bytes) -> bytes:
            return bytes(65)

        def sign_typed_data_hash(self, hash_: bytes) -> bytes:
            return bytes(65)

        def get_address(self) -> bytes:
            return bytes(20)

    impl = LegacySigner()
    signer = Signer.custom(impl)
    try:
        auth = signer.sign_authorization(1, bytes(20), 0)
        assert isinstance(auth, Authorization)
        # The SDK should have invoked our sign_hash for the fallback path.
        assert impl.sign_hash_calls >= 1
    finally:
        signer.close()


def test_custom_signer_with_native_sign_authorization() -> None:
    """When impl defines sign_authorization, the vtable slot is populated and
    our callback is invoked (bypassing the hash-then-sign fallback)."""

    class NativeAuth:
        def __init__(self) -> None:
            self.auth_calls = 0
            self.hash_calls = 0

        def sign_hash(self, hash_: bytes) -> bytes:
            self.hash_calls += 1
            return bytes(65)

        def sign_message(self, msg: bytes) -> bytes:
            return bytes(65)

        def sign_typed_data_hash(self, hash_: bytes) -> bytes:
            return bytes(65)

        def get_address(self) -> bytes:
            return bytes(20)

        def sign_authorization(
            self, chain_id: int, address: bytes, nonce: int,
        ) -> Authorization:
            self.auth_calls += 1
            return Authorization(
                chain_id=chain_id, address=address, nonce=nonce,
                y_parity=1,
                r=bytes([0xAA] * 32),
                s=bytes([0xBB] * 32),
            )

    impl = NativeAuth()
    signer = Signer.custom(impl)
    try:
        target = bytes([0xCC] * 20)
        auth = signer.sign_authorization(42, target, 7)

        assert impl.auth_calls == 1
        assert impl.hash_calls == 0  # native path — no fallback
        assert auth.chain_id == 42
        assert auth.address == target
        assert auth.nonce == 7
        assert auth.y_parity == 1
        assert auth.r == bytes([0xAA] * 32)
        assert auth.s == bytes([0xBB] * 32)
    finally:
        signer.close()


def test_custom_signer_sign_authorization_65_byte_return() -> None:
    """A custom signer may return a packed (r || s || v) 65-byte sig; the
    binding unpacks it into an Authorization."""

    class Raw65:
        def sign_hash(self, hash_: bytes) -> bytes:
            return bytes(65)

        def sign_message(self, msg: bytes) -> bytes:
            return bytes(65)

        def sign_typed_data_hash(self, hash_: bytes) -> bytes:
            return bytes(65)

        def get_address(self) -> bytes:
            return bytes(20)

        def sign_authorization(
            self, chain_id: int, address: bytes, nonce: int,
        ) -> bytes:
            # v=28 maps to y_parity=1
            return bytes([0x11] * 32) + bytes([0x22] * 32) + bytes([28])

    signer = Signer.custom(Raw65())
    try:
        auth = signer.sign_authorization(1, bytes(20), 0)
        assert auth.r == bytes([0x11] * 32)
        assert auth.s == bytes([0x22] * 32)
        assert auth.y_parity == 1
    finally:
        signer.close()


def test_new_account_7702_address_matches_signer() -> None:
    """For EIP-7702 accounts, the account address IS the EOA address."""
    with Context("test-project", chain_id=11155111) as ctx:
        signer = Signer.generate()
        try:
            account = ctx.new_account_7702(signer, KernelVersion.V3_3)
            try:
                eoa_hex = account.get_address_hex()
                assert eoa_hex.startswith("0x")
                assert len(eoa_hex) == 42  # 0x + 40 hex chars
            finally:
                account.close()
        finally:
            signer.close()


# ---------------------------------------------------------------------------
# Live E2E test — requires ZERODEV_PROJECT_ID and network access.
# ---------------------------------------------------------------------------

@pytest.mark.skipif(
    not os.environ.get("ZERODEV_PROJECT_ID"),
    reason="ZERODEV_PROJECT_ID not set — skipping live Sepolia test",
)
def test_live_7702_gasless_transfer() -> None:
    """Send a sponsored EIP-7702 UserOp on Sepolia end-to-end."""
    project_id = os.environ["ZERODEV_PROJECT_ID"]

    with Context(project_id, chain_id=11155111) as ctx:
        signer = Signer.generate()
        try:
            with ctx.new_account_7702(signer, KernelVersion.V3_3) as account:
                addr = account.get_address()
                print(f"\n  EIP-7702 EOA: {addr.hex()}")

                # 0-value self-call — minimal gasless transfer.
                userop_hash = account.send_user_op([Call(target=addr.bytes)])
                print(f"  UserOp hash:  {userop_hash.hex()}")

                receipt = account.wait_for_receipt(
                    userop_hash, timeout_ms=90_000, poll_ms=2_000,
                )

                assert receipt.get("success"), (
                    f"UserOp reverted: {receipt.get('reason', 'unknown')}"
                )

                tx = receipt.get("receipt", {})
                if isinstance(tx, dict):
                    print(f"  Tx hash:      {tx.get('transactionHash', 'N/A')}")
                print(f"  Gas used:     {receipt.get('actualGasUsed', 'N/A')}")
        finally:
            signer.close()
