"""Context — holds RPC URLs, chain config, and middleware."""

import ctypes

from ._ffi import _lib, _Context
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
    ) -> Account:
        """Create a Kernel smart account."""
        return Account._create(self._ptr, signer._ptr, int(version), index)

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
