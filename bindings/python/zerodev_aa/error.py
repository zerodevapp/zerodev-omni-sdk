"""Error types for the ZeroDev AA SDK."""

from ._ffi import _lib


class AaError(Exception):
    """Exception raised for ZeroDev AA library errors."""

    STATUS_NAMES = {
        0: "OK", 1: "NullOutPtr", 2: "InvalidUrl", 3: "OutOfMemory",
        4: "InvalidPrivateKey", 5: "InvalidKernelVersion", 6: "NullContext",
        7: "NullAccount", 8: "NullUserOp", 9: "GetAddressFailed",
        10: "BuildUserOpFailed", 11: "HashUserOpFailed", 12: "SignUserOpFailed",
        13: "SendUserOpFailed", 14: "EstimateGasFailed", 15: "PaymasterFailed",
        16: "NoCalls", 17: "InvalidHex", 18: "ApplyJsonFailed",
        19: "SerializeFailed", 20: "NoGasMiddleware", 21: "NoPaymasterMiddleware",
        22: "ReceiptTimeout", 23: "ReceiptFailed", 24: "InvalidSigner",
    }

    def __init__(self, code: int, detail: str = ""):
        self.code = code
        self.name = self.STATUS_NAMES.get(code, f"Unknown({code})")
        self.detail = detail
        msg = f"{self.name} (code {code})"
        if detail:
            msg += f": {detail}"
        super().__init__(msg)


def check(status: int) -> None:
    """Raise AaError if status is non-zero."""
    if status != 0:
        raw = _lib.aa_get_last_error()
        detail = raw.decode("utf-8", errors="replace") if raw else ""
        raise AaError(status, detail)
