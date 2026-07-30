"""Context — holds RPC URLs, chain config, and middleware."""

import ctypes
from typing import Optional

from ._ffi import _lib, _Context, _Account
from .error import check
from .types import KernelVersion, GasMiddleware, PaymasterMiddleware
from .signer import Signer
from .account import Account


class Context:
    """SDK context with RPC configuration and middleware."""

    def __init__(
        self,
        project_id: str,
        rpc_url: str = "",
        bundler_url: str = "",
        chain_id: int = 11155111,
        gas: GasMiddleware = GasMiddleware.ZERODEV,
        paymaster: PaymasterMiddleware = PaymasterMiddleware.ZERODEV,
    ):
        ptr = ctypes.POINTER(_Context)()
        check(_lib.aa_context_create(
            project_id.encode(), rpc_url.encode(), bundler_url.encode(),
            chain_id, ctypes.byref(ptr),
        ))
        self._ptr = ptr

        # Set gas middleware — pass C function pointer directly
        if gas == GasMiddleware.ZERODEV:
            # Get raw function pointer from the loaded library
            gas_fn = ctypes.cast(_lib.aa_gas_zerodev, ctypes.c_void_p)
            check(_lib.aa_context_set_gas_middleware(self._ptr, gas_fn))

        # Set paymaster middleware
        if paymaster == PaymasterMiddleware.ZERODEV:
            pm_fn = ctypes.cast(_lib.aa_paymaster_zerodev, ctypes.c_void_p)
            check(_lib.aa_context_set_paymaster_middleware(self._ptr, pm_fn))

    def new_account(
        self,
        signer: Signer,
        version: KernelVersion = KernelVersion.V3_3,
        index: int = 0,
        address: Optional[bytes] = None,
    ) -> Account:
        """Create a Kernel smart account.

        When ``address`` is ``None`` (the default), the sender address is
        derived counterfactually via CREATE2 from ``(signer, version,
        index)``. When supplied as 20 raw bytes, the account's sender is
        pinned to that address (migration path for kernel-version upgrades
        or legacy wallets whose CREATE2 salt this SDK no longer computes).
        Pinning affects the sender only; factory init_code is still
        emitted on the first UserOp exactly as it would be for a
        counterfactually-derived account (governed by the EntryPoint
        nonce). Callers pinning an already-deployed account with
        EntryPoint nonce 0 (rare — funded but never used) should drop the
        factory bytes via the low-level UserOp API.

        The returned :class:`Account` holds a strong reference to ``signer``
        (audit F-09) so GC won't finalize it while the account is alive.
        """
        return Account._create(self, signer, int(version), index, address)

    def new_account_7702(
        self,
        signer: Signer,
        version: KernelVersion = KernelVersion.V3_3,
    ) -> Account:
        """Create an EIP-7702 delegated account.

        The account address IS the signer's EOA address — no CREATE2, no init
        code, no index. On the first UserOperation the SDK signs an
        authorization tuple ``(chainId, kernelImpl, EOA-nonce)`` and attaches it
        via the ``eip7702Auth`` field; later ops skip the auth once the
        delegation is installed on-chain. Today only ``KernelVersion.V3_3``
        supports EIP-7702.

        The returned :class:`Account` holds a strong reference to ``signer``
        (audit F-09).
        """
        ptr = ctypes.POINTER(_Account)()
        check(_lib.aa_context_new_account_7702(
            self._ptr, signer._ptr, int(version), ctypes.byref(ptr),
        ))
        return Account(ptr, signer)

    def close(self) -> None:
        if self._ptr:
            _lib.aa_context_destroy(self._ptr)
            self._ptr = None

    def __enter__(self) -> "Context":
        return self

    def __exit__(self, *args) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()
