"""ZeroDev Gasless Transfer — Python Example.

Sends a sponsored (gasless) UserOperation that transfers 0 ETH to self.

Requirements:
    ZERODEV_PROJECT_ID  — Your ZeroDev project ID
    PRIVATE_KEY         — (optional) 32-byte hex private key; generates one if omitted
"""

import os
import sys

from zerodev_aa import Context, Signer, Call, KernelVersion


def main() -> None:
    print("===========================================")
    print("  ZeroDev Gasless Transfer — Python Example")
    print("===========================================")
    print()

    # ── Step 1: Read environment variables ──────────────────────────
    project_id = os.environ.get("ZERODEV_PROJECT_ID", "")
    if not project_id:
        print("Error: ZERODEV_PROJECT_ID environment variable is required.", file=sys.stderr)
        print("Usage:", file=sys.stderr)
        print("  export ZERODEV_PROJECT_ID=<your-project-id>", file=sys.stderr)
        print("  export PRIVATE_KEY=<32-byte-hex-private-key>  # optional", file=sys.stderr)
        print("  python3 main.py", file=sys.stderr)
        sys.exit(1)

    pk_hex = os.environ.get("PRIVATE_KEY", "")
    print(f"[1/6] Configuration loaded (project: {project_id}, chain: Sepolia 11155111)")

    # ── Step 2: Create context with ZeroDev gas + paymaster on Sepolia ─
    with Context(project_id, chain_id=11155111) as ctx:
        print("[2/6] Context created (gas: ZeroDev, paymaster: ZeroDev)")

        # ── Step 3: Create signer ──────────────────────────────────
        if pk_hex:
            pk_hex = pk_hex.removeprefix("0x").removeprefix("0X")
            private_key = bytes.fromhex(pk_hex)
            signer = Signer.local(private_key)
            print("[3/6] Signer created (from PRIVATE_KEY)")
        else:
            signer = Signer.generate()
            print("[3/6] Signer created (random key generated)")

        with signer:
            # ── Step 4: Create Kernel v3.3 smart account ───────────
            with ctx.new_account(signer, KernelVersion.V3_3) as account:
                addr = account.get_address()
                print(f"[4/6] Smart account ready: {addr.hex()}")

                # ── Step 5: Build a call (send 0 ETH to self) ──────
                call = Call(target=addr.bytes)  # 0 ETH, empty calldata
                print("[5/6] Sending sponsored UserOp...")

                # ── Step 6: Send UserOp (build + sponsor + sign + submit)
                userop_hash = account.send_user_op([call])
                print(f"       UserOp hash: {userop_hash.hex()}")

                # ── Wait for receipt ───────────────────────────────
                print("[6/6] Waiting for receipt (timeout: 60s, poll: 2s)...")
                receipt = account.wait_for_receipt(userop_hash, timeout_ms=60000, poll_ms=2000)

                # ── Print results ──────────────────────────────────
                print()
                print("===========================================")
                print("  UserOp Receipt")
                print("===========================================")
                print(f"  Success:      {receipt.get('success')}")

                tx_receipt = receipt.get("receipt", {})
                if isinstance(tx_receipt, dict):
                    print(f"  Tx Hash:      {tx_receipt.get('transactionHash', 'N/A')}")

                print(f"  Gas Used:     {receipt.get('actualGasUsed', 'N/A')}")
                print(f"  Gas Cost:     {receipt.get('actualGasCost', 'N/A')}")
                print(f"  Sender:       {receipt.get('sender', 'N/A')}")
                print(f"  Paymaster:    {receipt.get('paymaster', 'N/A')}")
                print(f"  UserOp Hash:  {receipt.get('userOpHash', 'N/A')}")
                print(f"  Entry Point:  {receipt.get('entryPoint', 'N/A')}")
                print("===========================================")

                if not receipt.get("success"):
                    print(f"\nUserOp execution reverted: {receipt.get('reason', 'unknown')}", file=sys.stderr)
                    sys.exit(1)

                print("\nGasless transfer completed successfully!")


if __name__ == "__main__":
    main()
