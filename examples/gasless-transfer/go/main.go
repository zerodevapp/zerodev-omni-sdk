package main

import (
	"encoding/hex"
	"fmt"
	"os"
	"strings"

	"github.com/zerodevapp/zerodev-omni-sdk/bindings/go/aa"
)

func main() {
	fmt.Println("===========================================")
	fmt.Println("  ZeroDev Gasless Transfer — Go Example")
	fmt.Println("===========================================")
	fmt.Println()

	// ── Step 1: Read environment variables ──────────────────────────
	projectID := os.Getenv("ZERODEV_PROJECT_ID")
	if projectID == "" {
		fmt.Fprintln(os.Stderr, "Error: ZERODEV_PROJECT_ID environment variable is required.")
		fmt.Fprintln(os.Stderr, "Usage:")
		fmt.Fprintln(os.Stderr, "  export ZERODEV_PROJECT_ID=<your-project-id>")
		fmt.Fprintln(os.Stderr, "  export PRIVATE_KEY=<32-byte-hex-private-key>")
		fmt.Fprintln(os.Stderr, "  go run main.go")
		os.Exit(1)
	}

	pkHex := os.Getenv("PRIVATE_KEY")
	var useGeneratedKey bool
	var privateKey [32]byte

	if pkHex == "" {
		useGeneratedKey = true
	} else {
		pkHex = strings.TrimPrefix(pkHex, "0x")
		pkHex = strings.TrimPrefix(pkHex, "0X")
		pkBytes, err := hex.DecodeString(pkHex)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: invalid PRIVATE_KEY hex: %v\n", err)
			os.Exit(1)
		}
		if len(pkBytes) != 32 {
			fmt.Fprintf(os.Stderr, "Error: PRIVATE_KEY must be 32 bytes, got %d\n", len(pkBytes))
			os.Exit(1)
		}
		copy(privateKey[:], pkBytes)
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

	// ── Step 3: Create signer ──────────────────────────────────────
	var signer *aa.Signer
	if useGeneratedKey {
		signer, err = aa.GenerateSigner()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error generating signer: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("[3/6] Signer created (random key generated)")
	} else {
		signer, err = aa.LocalSigner(privateKey)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error creating signer: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("[3/6] Signer created (from PRIVATE_KEY)")
	}
	defer signer.Close()

	// ── Step 4: Create Kernel v3.3 smart account ────────────────────
	account, err := ctx.NewAccount(signer, aa.KernelV3_3, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating account: %v\n", err)
		os.Exit(1)
	}
	defer account.Close()

	addrHex, err := account.GetAddressHex()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error getting account address: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("[4/6] Smart account ready: %s\n", addrHex)

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

	fmt.Println("[5/6] Sending sponsored UserOp...")

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
	fmt.Printf("  Sender:       %s\n", receipt.Sender)
	fmt.Printf("  Paymaster:    %s\n", receipt.Paymaster)
	fmt.Printf("  UserOp Hash:  %s\n", receipt.UserOpHash)
	fmt.Printf("  Entry Point:  %s\n", receipt.EntryPoint)
	fmt.Println("===========================================")

	if !receipt.Success {
		fmt.Fprintf(os.Stderr, "\nUserOp execution reverted: %s\n", receipt.Reason)
		os.Exit(1)
	}

	fmt.Println("\nGasless transfer completed successfully!")
}
