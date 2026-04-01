// Privy Embedded Wallet — Custom Signer Example
//
// This example demonstrates how to use a Privy embedded wallet as the signer
// for a ZeroDev Kernel smart account. It uses Privy's REST API to sign
// hashes and messages, delegating all key custody to Privy's infrastructure.
//
// Requirements:
//   - A Privy account with an embedded wallet created (https://privy.io)
//   - The following environment variables must be set:
//       ZERODEV_PROJECT_ID  — Your ZeroDev project ID
//       PRIVY_APP_ID        — Your Privy application ID
//       PRIVY_APP_SECRET    — Your Privy application secret
//       PRIVY_WALLET_ID     — The Privy wallet ID to sign with
//       OWNER_ADDRESS       — The EOA address of the Privy wallet (0x-prefixed hex)
//
// The example creates a Kernel v3.3 smart account on Sepolia, sends a
// zero-value UserOp to itself (sponsored via ZeroDev paymaster), and
// waits for the receipt.

package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"

	"github.com/zerodevapp/zerodev-omni-sdk/bindings/go/aa"
)

const sepoliaChainID = 11155111

func main() {
	fmt.Println("ZeroDev Omni SDK — Privy Custom Signer Example")
	fmt.Println("================================================")

	// --- Read required environment variables ---

	projectID := requireEnv("ZERODEV_PROJECT_ID")
	privyAppID := requireEnv("PRIVY_APP_ID")
	privyAppSecret := requireEnv("PRIVY_APP_SECRET")
	privyWalletID := requireEnv("PRIVY_WALLET_ID")
	ownerAddressHex := requireEnv("OWNER_ADDRESS")

	// --- Parse owner address ---

	ownerAddress, err := parseAddress(ownerAddressHex)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: invalid OWNER_ADDRESS %q: %v\n", ownerAddressHex, err)
		os.Exit(1)
	}
	fmt.Printf("Owner address: 0x%s\n", hex.EncodeToString(ownerAddress[:]))

	// --- Create ZeroDev context on Sepolia ---

	rpcURL := fmt.Sprintf("https://rpc.zerodev.app/api/v3/%s/chain/%d", projectID, sepoliaChainID)
	bundlerURL := rpcURL

	ctx, err := aa.NewContext(projectID, rpcURL, bundlerURL, sepoliaChainID, aa.GasZeroDev, aa.PaymasterZeroDev)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating context: %v\n", err)
		os.Exit(1)
	}
	defer ctx.Close()
	fmt.Println("Context created (Sepolia, ZeroDev gas + paymaster)")

	// --- Create Privy custom signer ---

	signer, err := aa.CustomSigner(aa.SignerFuncs{
		SignHash: func(hash [32]byte) ([65]byte, error) {
			hashHex := "0x" + hex.EncodeToString(hash[:])
			return privyRawSign(privyAppID, privyAppSecret, privyWalletID, hashHex)
		},
		SignMessage: func(msg []byte) ([65]byte, error) {
			return privySignMessage(privyAppID, privyAppSecret, privyWalletID, msg)
		},
		SignTypedDataHash: func(hash [32]byte) ([65]byte, error) {
			// EIP-712 typed data hash is signed the same way as a raw hash.
			hashHex := "0x" + hex.EncodeToString(hash[:])
			return privyRawSign(privyAppID, privyAppSecret, privyWalletID, hashHex)
		},
		GetAddress: func() [20]byte {
			return ownerAddress
		},
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating custom signer: %v\n", err)
		os.Exit(1)
	}
	defer signer.Close()
	fmt.Println("Privy custom signer created")

	// --- Create Kernel v3.3 account ---

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
	fmt.Printf("Smart account address: %s\n", addrHex)

	// --- Build calls: send 0 ETH to self ---

	smartAddr, _ := account.GetAddress()
	calls := []aa.Call{
		{
			Target:   smartAddr,
			Value:    [32]byte{}, // 0 ETH
			Calldata: []byte{},
		},
	}

	// --- Send UserOp ---

	fmt.Println("Sending UserOp (0 ETH to self)...")
	useropHash, err := account.SendUserOp(calls)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error sending UserOp: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("UserOp hash: 0x%s\n", hex.EncodeToString(useropHash[:]))

	// --- Wait for receipt ---

	fmt.Println("Waiting for receipt...")
	receipt, err := account.WaitForUserOperationReceipt(useropHash, 0, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error waiting for receipt: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("UserOp included! success=%v gasUsed=%s\n", receipt.Success, receipt.ActualGasUsed)
	fmt.Println("Done.")
}

// ---------------------------------------------------------------------------
// Privy REST API helpers
// ---------------------------------------------------------------------------

// privyRawSign signs a 32-byte hash via Privy's raw_sign endpoint.
// The hash must be a 0x-prefixed hex string.
func privyRawSign(appID, appSecret, walletID, hashHex string) ([65]byte, error) {
	payload := map[string]any{
		"params": map[string]any{
			"hash": hashHex,
		},
	}
	return privySign(appID, appSecret, walletID, "raw_sign", payload)
}

// privySignMessage signs a message via Privy's personal_sign RPC method.
// Privy applies EIP-191 wrapping internally, matching viem's signMessage({ raw: hash }).
func privySignMessage(appID, appSecret, walletID string, msg []byte) ([65]byte, error) {
	msgHex := hex.EncodeToString(msg)
	payload := map[string]any{
		"method": "personal_sign",
		"params": map[string]any{
			"message":  msgHex,
			"encoding": "hex",
		},
	}
	return privySign(appID, appSecret, walletID, "rpc", payload)
}

// privySign POSTs to a Privy wallet endpoint and returns the 65-byte signature.
func privySign(appID, appSecret, walletID, endpoint string, payload map[string]any) ([65]byte, error) {
	var sig [65]byte

	body, err := json.Marshal(payload)
	if err != nil {
		return sig, fmt.Errorf("marshal request: %w", err)
	}

	url := fmt.Sprintf("https://api.privy.io/v1/wallets/%s/%s", walletID, endpoint)
	req, err := http.NewRequest("POST", url, bytes.NewReader(body))
	if err != nil {
		return sig, fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("privy-app-id", appID)
	req.SetBasicAuth(appID, appSecret)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return sig, fmt.Errorf("HTTP request: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return sig, fmt.Errorf("read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return sig, fmt.Errorf("Privy API error (HTTP %d): %s", resp.StatusCode, string(respBody))
	}

	sig, err = parsePrivySignature(respBody)
	if err != nil {
		return sig, fmt.Errorf("parse signature: %w", err)
	}

	return sig, nil
}

// parsePrivySignature extracts the 65-byte signature from a Privy response.
// Expected format: {"data":{"signature":"0x..."}}
func parsePrivySignature(body []byte) ([65]byte, error) {
	var sig [65]byte

	var resp struct {
		Data struct {
			Signature string `json:"signature"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return sig, fmt.Errorf("unmarshal response: %w", err)
	}

	sigHex := resp.Data.Signature
	if sigHex == "" {
		return sig, fmt.Errorf("empty signature in response: %s", string(body))
	}

	sigHex = strings.TrimPrefix(sigHex, "0x")
	sigBytes, err := hex.DecodeString(sigHex)
	if err != nil {
		return sig, fmt.Errorf("decode hex signature: %w", err)
	}

	if len(sigBytes) != 65 {
		return sig, fmt.Errorf("unexpected signature length %d (expected 65)", len(sigBytes))
	}

	copy(sig[:], sigBytes)
	return sig, nil
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

// requireEnv reads an environment variable or exits with a usage message.
func requireEnv(name string) string {
	val := os.Getenv(name)
	if val == "" {
		fmt.Fprintf(os.Stderr, "Error: required environment variable %s is not set.\n", name)
		fmt.Fprintf(os.Stderr, "\nUsage:\n")
		fmt.Fprintf(os.Stderr, "  export ZERODEV_PROJECT_ID=<your-zerodev-project-id>\n")
		fmt.Fprintf(os.Stderr, "  export PRIVY_APP_ID=<your-privy-app-id>\n")
		fmt.Fprintf(os.Stderr, "  export PRIVY_APP_SECRET=<your-privy-app-secret>\n")
		fmt.Fprintf(os.Stderr, "  export PRIVY_WALLET_ID=<your-privy-wallet-id>\n")
		fmt.Fprintf(os.Stderr, "  export OWNER_ADDRESS=0x<privy-wallet-eoa-address>\n")
		fmt.Fprintf(os.Stderr, "  go run main.go\n")
		os.Exit(1)
	}
	return val
}

// parseAddress parses a 0x-prefixed hex address into a [20]byte.
func parseAddress(s string) ([20]byte, error) {
	var addr [20]byte
	s = strings.TrimPrefix(s, "0x")
	if len(s) != 40 {
		return addr, fmt.Errorf("address must be 40 hex characters, got %d", len(s))
	}
	b, err := hex.DecodeString(s)
	if err != nil {
		return addr, err
	}
	copy(addr[:], b)
	return addr, nil
}
