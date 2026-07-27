"""Offline tests for the optional ``address`` param on ``Context.new_account``.

Exercises the FFI wiring: with ``address=None`` the sender is derived
counterfactually via CREATE2; with 20 raw bytes the account is pinned and
``get_address`` returns those exact bytes. No network needed — these paths
are pure computation on the Zig side.
"""

from __future__ import annotations

import pytest

from zerodev_aa import Context, KernelVersion, Signer


PK = bytes(range(1, 33))  # deterministic 0x01..0x20

# Legacy address a caller might want to keep operating post kernel upgrade.
PINNED = bytes.fromhex("deadbeef000102030405060708090a0b0c0d0e0f")


@pytest.fixture
def ctx() -> Context:
    with Context(project_id="test-project", chain_id=11155111) as c:
        yield c


def test_new_account_counterfactual_when_address_none(ctx: Context) -> None:
    """address=None → CREATE2-derived, stable across two calls (deterministic)."""
    with Signer.local(PK) as signer:
        with ctx.new_account(signer, KernelVersion.V3_3, 0) as a1, \
             ctx.new_account(signer, KernelVersion.V3_3, 0, address=None) as a2:
            addr1 = a1.get_address().bytes
            addr2 = a2.get_address().bytes
            assert addr1 == addr2, "CREATE2 derivation must be deterministic"
            assert addr1 != PINNED, "counterfactual must not equal the pinned test vector"


def test_new_account_pinned_when_address_supplied(ctx: Context) -> None:
    """address=<20 bytes> → get_address returns those exact bytes."""
    with Signer.local(PK) as signer:
        with ctx.new_account(signer, KernelVersion.V3_3, 0, address=PINNED) as account:
            assert account.get_address().bytes == PINNED


def test_new_account_wrong_address_length_rejected(ctx: Context) -> None:
    """Guard against callers passing a hex string / shorter buffer."""
    with Signer.local(PK) as signer:
        with pytest.raises(ValueError, match="20 bytes"):
            ctx.new_account(signer, KernelVersion.V3_3, 0, address=b"\x01\x02\x03")
