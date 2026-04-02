"""Public types for the ZeroDev AA SDK."""

from dataclasses import dataclass, field
from enum import IntEnum


class KernelVersion(IntEnum):
    V3_1 = 0
    V3_2 = 1
    V3_3 = 2


class GasMiddleware(IntEnum):
    ZERODEV = 0


class PaymasterMiddleware(IntEnum):
    NONE = -1
    ZERODEV = 0


@dataclass
class Call:
    """A single call in a UserOperation."""
    target: bytes  # 20 bytes
    value: bytes = field(default_factory=lambda: b"\x00" * 32)  # u256, big-endian
    calldata: bytes = b""


class Address:
    """20-byte Ethereum address."""

    def __init__(self, bytes_: bytes):
        if len(bytes_) != 20:
            raise ValueError(f"Address must be 20 bytes, got {len(bytes_)}")
        self.bytes = bytes_

    def hex(self) -> str:
        return "0x" + self.bytes.hex()

    def __repr__(self) -> str:
        return self.hex()

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Address) and self.bytes == other.bytes

    def __hash__(self) -> int:
        return hash(self.bytes)

    @staticmethod
    def from_hex(hex_str: str) -> "Address":
        s = hex_str.removeprefix("0x").removeprefix("0X")
        return Address(bytes.fromhex(s))


class Hash:
    """32-byte hash."""

    def __init__(self, bytes_: bytes):
        if len(bytes_) != 32:
            raise ValueError(f"Hash must be 32 bytes, got {len(bytes_)}")
        self.bytes = bytes_

    def hex(self) -> str:
        return "0x" + self.bytes.hex()

    def __repr__(self) -> str:
        return self.hex()

    @property
    def is_zero(self) -> bool:
        return all(b == 0 for b in self.bytes)
