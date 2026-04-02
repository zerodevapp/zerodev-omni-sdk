// Privy Embedded Wallet — Custom Signer Example
//
// Creates a Privy server wallet on the fly and uses it to sign UserOperations
// for a ZeroDev Kernel smart account. The signing key never leaves Privy.
//
// Requirements:
//   - Environment variables:
//       ZERODEV_PROJECT_ID  — Your ZeroDev project ID
//       PRIVY_APP_ID        — Your Privy application ID
//       PRIVY_APP_SECRET    — Your Privy application secret

package main

import (
	"context"
	"encoding/hex"
	"fmt"
	"os"
	"strings"

	privy "github.com/privy-io/go-sdk"
	"github.com/zerodevapp/zerodev-omni-sdk/bindings/go/aa"
)

const sepoliaChainID = 11155111

func main() {
	fmt.Println("ZeroDev Omni SDK — Privy Signer Example")
	fmt.Println("========================================")

	projectID := requireEnv("ZERODEV_PROJECT_ID")
	privyAppID := requireEnv("PRIVY_APP_ID")
	privyAppSecret := requireEnv("PRIVY_APP_SECRET")

	// --- Create Privy client + wallet ---

	privyClient := privy.NewPrivyClient(privy.PrivyClientOptions{
		AppID:     privyAppID,
		AppSecret: privyAppSecret,
	})

	wallet, err := privyClient.Wallets.New(context.Background(), privy.WalletNewParams{
		ChainType: privy.WalletChainTypeEthereum,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating Privy wallet: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Privy wallet created: %s (address: %s)\n", wallet.ID, wallet.Address)

	ownerAddress, err := parseAddress(wallet.Address)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error parsing wallet address: %v\n", err)
		os.Exit(1)
	}

	// --- Create custom signer backed by Privy ---

	sign := func(msg []byte) ([65]byte, error) {
		resp, err := privyClient.Wallets.Ethereum.SignMessageBytes(
			context.Background(), wallet.ID, msg,
		)
		if err != nil {
			return [65]byte{}, fmt.Errorf("privy SignMessageBytes: %w", err)
		}
		return parseSig(resp.Signature)
	}

	signer, err := aa.CustomSigner(aa.SignerFuncs{
		SignHash:          func(hash [32]byte) ([65]byte, error) { return sign(hash[:]) },
		SignMessage:       func(msg []byte) ([65]byte, error) { return sign(msg) },
		SignTypedDataHash: func(hash [32]byte) ([65]byte, error) { return sign(hash[:]) },
		GetAddress:        func() [20]byte { return ownerAddress },
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating signer: %v\n", err)
		os.Exit(1)
	}
	defer signer.Close()

	// --- Create ZeroDev context + account ---

	ctx, err := aa.NewContext(projectID, "", "", sepoliaChainID, aa.GasZeroDev, aa.PaymasterZeroDev)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating context: %v\n", err)
		os.Exit(1)
	}
	defer ctx.Close()

	account, err := ctx.NewAccount(signer, aa.KernelV3_3, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating account: %v\n", err)
		os.Exit(1)
	}
	defer account.Close()

	addrHex, _ := account.GetAddressHex()
	fmt.Printf("Smart account: %s\n", addrHex)

	// --- Send sponsored UserOp ---

	smartAddr, _ := account.GetAddress()
	calls := []aa.Call{{Target: smartAddr, Value: [32]byte{}, Calldata: []byte{}}}

	fmt.Println("Sending sponsored UserOp...")
	hash, err := account.SendUserOp(calls)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("UserOp hash: 0x%s\n", hex.EncodeToString(hash[:]))

	receipt, err := account.WaitForUserOperationReceipt(hash, 0, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Success: %v | Gas: %s | Paymaster: %s\n",
		receipt.Success, receipt.ActualGasUsed, receipt.Paymaster)
}

func parseSig(sigHex string) ([65]byte, error) {
	var sig [65]byte
	b, err := hex.DecodeString(strings.TrimPrefix(sigHex, "0x"))
	if err != nil {
		return sig, err
	}
	if len(b) != 65 {
		return sig, fmt.Errorf("sig length %d, want 65", len(b))
	}
	copy(sig[:], b)
	return sig, nil
}

func requireEnv(name string) string {
	val := os.Getenv(name)
	if val == "" {
		fmt.Fprintf(os.Stderr, "Missing %s\n", name)
		os.Exit(1)
	}
	return val
}

func parseAddress(s string) ([20]byte, error) {
	var addr [20]byte
	b, err := hex.DecodeString(strings.TrimPrefix(s, "0x"))
	if err != nil {
		return addr, err
	}
	if len(b) != 20 {
		return addr, fmt.Errorf("want 20 bytes, got %d", len(b))
	}
	copy(addr[:], b)
	return addr, nil
}
