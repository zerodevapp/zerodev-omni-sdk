"""Privy Embedded Wallet — Custom Signer Example (Python)

Creates a Privy server wallet via REST API and uses it to sign
UserOperations for a ZeroDev Kernel smart account.

Required env vars:
    ZERODEV_PROJECT_ID
    PRIVY_APP_ID
    PRIVY_APP_SECRET

Note: When a Privy Python SDK is available on PyPI, replace the REST
calls with the SDK's client.wallets.rpc() method.
"""

import os
import sys

import requests
from zerodev_aa import Context, Signer, Call, KernelVersion


class PrivySigner:
    """Custom signer backed by Privy's embedded wallet REST API."""

    def __init__(self, app_id: str, app_secret: str, wallet_id: str, address: bytes):
        self.app_id = app_id
        self.app_secret = app_secret
        self.wallet_id = wallet_id
        self._address = address

    def sign_hash(self, hash: bytes) -> bytes:
        return self._rpc("raw_sign", {"hash": "0x" + hash.hex()})

    def sign_message(self, msg: bytes) -> bytes:
        """Privy personal_sign does EIP-191 wrapping internally."""
        return self._rpc("personal_sign", {"message": msg.hex(), "encoding": "hex"})

    def sign_typed_data_hash(self, hash: bytes) -> bytes:
        return self.sign_hash(hash)

    def get_address(self) -> bytes:
        return self._address

    def _rpc(self, method: str, params: dict) -> bytes:
        resp = requests.post(
            f"https://api.privy.io/v1/wallets/{self.wallet_id}/rpc",
            json={"method": method, "params": params},
            headers={"privy-app-id": self.app_id},
            auth=(self.app_id, self.app_secret),
        )
        resp.raise_for_status()
        sig_hex = resp.json()["data"]["signature"]
        sig = bytes.fromhex(sig_hex.removeprefix("0x"))
        if len(sig) != 65:
            raise ValueError(f"Signature must be 65 bytes, got {len(sig)}")
        return sig


def main():
    print("ZeroDev Omni SDK — Privy Signer Example (Python)")
    print("=================================================")

    project_id = _require_env("ZERODEV_PROJECT_ID")
    app_id = _require_env("PRIVY_APP_ID")
    app_secret = _require_env("PRIVY_APP_SECRET")

    # Create Privy wallet
    resp = requests.post(
        "https://api.privy.io/v1/wallets",
        json={"chain_type": "ethereum"},
        headers={"privy-app-id": app_id},
        auth=(app_id, app_secret),
    )
    resp.raise_for_status()
    wallet = resp.json()
    print(f"Privy wallet: {wallet['id']} ({wallet['address']})")

    address = bytes.fromhex(wallet["address"].removeprefix("0x"))

    # Create custom signer + account + send
    with Signer.custom(PrivySigner(app_id, app_secret, wallet["id"], address)) as signer:
        with Context(project_id, chain_id=11155111) as ctx:
            with ctx.new_account(signer, KernelVersion.V3_3) as account:
                print(f"Smart account: {account.get_address_hex()}")

                call = Call(target=account.get_address().bytes)
                print("Sending sponsored UserOp...")
                hash = account.send_user_op([call])
                print(f"UserOp hash: {hash.hex()}")

                receipt = account.wait_for_receipt(hash)
                print(f"Success: {receipt.get('success')} | "
                      f"Gas: {receipt.get('actualGasUsed')} | "
                      f"Paymaster: {receipt.get('paymaster')}")

    print("\nDone!")


def _require_env(name: str) -> str:
    val = os.environ.get(name, "")
    if not val:
        print(f"Missing {name}", file=sys.stderr)
        sys.exit(1)
    return val


if __name__ == "__main__":
    main()
