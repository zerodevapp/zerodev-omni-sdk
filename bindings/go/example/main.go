package main

import (
	"encoding/hex"
	"fmt"
	"os"

	"github.com/zerodevapp/zerodev-omni-sdk/bindings/go/aa"
)

func main() {
	fmt.Println("ZeroDev Omni SDK — Go Example")
	fmt.Println("==============================")

	projectID := os.Getenv("ZERODEV_PROJECT_ID")
	if projectID == "" {
		projectID = "test-project"
	}

	rpcURL := os.Getenv("RPC_URL")
	if rpcURL == "" {
		rpcURL = "https://rpc.zerodev.app/api/v3/" + projectID + "/chain/8453"
	}

	bundlerURL := os.Getenv("BUNDLER_URL")
	if bundlerURL == "" {
		bundlerURL = rpcURL
	}

	// Create context with ZeroDev middleware (gas + paymaster)
	ctx, err := aa.NewContext(projectID, rpcURL, bundlerURL, 8453, aa.GasZeroDev, aa.PaymasterZeroDev)
	if err != nil {
		fmt.Printf("Error creating context: %v\n", err)
		return
	}
	defer ctx.Close()
	fmt.Println("Context created")

	// Create signer from private key
	pk, _ := hex.DecodeString("ac0974bec39a17e36ba4a6b4d238ff944bacb35e5dc4700215cf651439dfba4")
	var privateKey [32]byte
	copy(privateKey[:], pk)

	signer, err := aa.LocalSigner(privateKey)
	if err != nil {
		fmt.Printf("Error creating signer: %v\n", err)
		return
	}
	defer signer.Close()

	// Create account (Kernel v3.3, index 0)
	account, err := ctx.NewAccount(signer, aa.KernelV3_3, 0)
	if err != nil {
		fmt.Printf("Error creating account: %v\n", err)
		return
	}
	defer account.Close()

	// Get address
	addrHex, err := account.GetAddressHex()
	if err != nil {
		fmt.Printf("Error getting address: %v\n", err)
		return
	}
	fmt.Printf("Account address: %s\n", addrHex)

	// Build a UserOp (send 0 ETH to self)
	addr, _ := account.GetAddress()
	calls := []aa.Call{
		{
			Target:   addr,
			Value:    [32]byte{}, // 0 ETH
			Calldata: []byte{},
		},
	}

	op, err := account.BuildUserOp(calls)
	if err != nil {
		fmt.Printf("Error building UserOp: %v\n", err)
		return
	}
	defer op.Close()
	fmt.Println("UserOp built")

	// Hash
	hash, err := op.Hash(account)
	if err != nil {
		fmt.Printf("Error hashing UserOp: %v\n", err)
		return
	}
	fmt.Printf("UserOp hash: 0x%s\n", hex.EncodeToString(hash[:]))

	// Sign
	err = op.Sign(account)
	if err != nil {
		fmt.Printf("Error signing UserOp: %v\n", err)
		return
	}
	fmt.Println("UserOp signed")

	// Serialize to JSON
	jsonStr, err := op.ToJSON()
	if err != nil {
		fmt.Printf("Error serializing UserOp: %v\n", err)
		return
	}
	fmt.Printf("UserOp JSON: %s\n", jsonStr[:min(len(jsonStr), 200)])

	fmt.Println("\nAll steps completed successfully!")
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
