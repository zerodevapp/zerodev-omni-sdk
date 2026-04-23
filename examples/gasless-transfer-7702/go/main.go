package main

import (
	"encoding/hex"
	"fmt"
	"os"

	"github.com/zerodevapp/zerodev-omni-sdk/bindings/go/aa"
)

func main() {
	fmt.Println("===========================================")
	fmt.Println("  ZeroDev Gasless Transfer (EIP-7702) — Go")
	fmt.Println("===========================================")
	fmt.Println()

	// ── Step 1: Read environment variables ──────────────────────────
	projectID := os.Getenv("ZERODEV_PROJECT_ID")
	if projectID == "" {
		fmt.Fprintln(os.Stderr, "Error: ZERODEV_PROJECT_ID environment variable is required.")
		fmt.Fprintln(os.Stderr, "Usage:")
		fmt.Fprintln(os.Stderr, "  export ZERODEV_PROJECT_ID=<your-project-id>")
		fmt.Fprintln(os.Stderr, "  go run main.go")
		os.Exit(1)
	}

	fmt.Printf("[1/6] Configuration loaded (project: %s, chain: Sepolia 11155111)\n", projectID)

	// ── Step 2: Create context with ZeroDev gas + paymaster on Sepolia ─
	chainID := uint64(11155111) // Sepolia

	ctx, err := aa.NewContext(projectID, "", "", chainID, aa.GasZeroDev, aa.PaymasterZeroDev)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating context: %v\n", err)
		os.Exit(1)
	}
	defer ctx.Close()

	fmt.Println("[2/6] Context created (gas: ZeroDev, paymaster: ZeroDev)")

	// ── Step 3: Generate a fresh EOA key ───────────────────────────
	//
	// EIP-7702 delegation lets *any* EOA act as a Kernel smart account — no
	// CREATE2 deployment is needed. We generate a key to demonstrate the
	// delegation-install path; replace with aa.LocalSigner(pk) to reuse an
	// existing EOA.
	signer, err := aa.GenerateSigner()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error generating signer: %v\n", err)
		os.Exit(1)
	}
	defer signer.Close()

	fmt.Println("[3/6] Signer created (random EOA key generated)")

	// ── Step 4: Create the 7702 account (sender == EOA) ────────────
	//
	// Unlike NewAccount, this does NOT take an index — a 7702 account's
	// address is the EOA itself. On the first UserOperation the SDK signs an
	// authorization tuple and attaches it via `eip7702Auth`; subsequent UserOps
	// skip the auth once delegation is installed on-chain.
	account, err := ctx.NewAccount7702(signer, aa.KernelV3_3)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating 7702 account: %v\n", err)
		os.Exit(1)
	}
	defer account.Close()

	addrHex, err := account.GetAddressHex()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error getting account address: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("[4/6] Smart account (EOA + delegation) ready: %s\n", addrHex)

	// ── Step 5: Build a call (send 0 ETH to self — noop) ───────────
	addr, err := account.GetAddress()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error getting account address bytes: %v\n", err)
		os.Exit(1)
	}

	calls := []aa.Call{
		{
			Target:   addr,
			Value:    [32]byte{}, // 0 ETH
			Calldata: []byte{},   // empty calldata
		},
	}

	fmt.Println("[5/6] Sending sponsored UserOp with eip7702Auth...")

	// ── Step 6: Send the UserOp (build + sponsor + sign + submit) ──
	hash, err := account.SendUserOp(calls)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error sending UserOp: %v\n", err)
		os.Exit(1)
	}

	hashHex := "0x" + hex.EncodeToString(hash[:])
	fmt.Printf("       UserOp hash: %s\n", hashHex)

	// ── Step 7: Wait for the receipt ────────────────────────────────
	fmt.Println("[6/6] Waiting for receipt (timeout: 60s, poll: 2s)...")

	receipt, err := account.WaitForUserOperationReceipt(hash, 60000, 2000)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error waiting for receipt: %v\n", err)
		os.Exit(1)
	}

	// ── Print results ───────────────────────────────────────────────
	fmt.Println()
	fmt.Println("===========================================")
	fmt.Println("  UserOp Receipt")
	fmt.Println("===========================================")
	fmt.Printf("  Success:      %v\n", receipt.Success)

	if txHash, ok := receipt.Receipt["transactionHash"].(string); ok {
		fmt.Printf("  Tx Hash:      %s\n", txHash)
	}

	fmt.Printf("  Gas Used:     %s\n", receipt.ActualGasUsed)
	fmt.Printf("  Gas Cost:     %s\n", receipt.ActualGasCost)
	fmt.Printf("  Sender (EOA): %s\n", receipt.Sender)
	fmt.Printf("  Paymaster:    %s\n", receipt.Paymaster)
	fmt.Printf("  UserOp Hash:  %s\n", receipt.UserOpHash)
	fmt.Printf("  Entry Point:  %s\n", receipt.EntryPoint)
	fmt.Println("===========================================")

	if !receipt.Success {
		fmt.Fprintf(os.Stderr, "\nUserOp execution reverted: %s\n", receipt.Reason)
		os.Exit(1)
	}

	fmt.Println("\n7702 gasless transfer completed successfully!")
}
