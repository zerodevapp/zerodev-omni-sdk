package aa_test

import (
	"encoding/hex"
	"os"
	"testing"

	"github.com/zerodevapp/zerodev-omni-sdk/bindings/go/aa"
)

// TestSendUserOpSepolia exercises the full aa_send_userop pipeline on Sepolia.
//
// Requires environment variables:
//   ZERODEV_PROJECT_ID — ZeroDev project ID
//   E2E_PRIVATE_KEY    — 32-byte hex private key (with or without 0x prefix)
//
// Run via: make test-go-live
func TestSendUserOpSepolia(t *testing.T) {
	projectID := os.Getenv("ZERODEV_PROJECT_ID")
	if projectID == "" {
		t.Skip("ZERODEV_PROJECT_ID not set, skipping live test")
	}

	pkHex := os.Getenv("E2E_PRIVATE_KEY")
	if pkHex == "" {
		t.Skip("E2E_PRIVATE_KEY not set, skipping live test")
	}

	// Strip 0x prefix if present
	if len(pkHex) >= 2 && pkHex[:2] == "0x" || pkHex[:2] == "0X" {
		pkHex = pkHex[2:]
	}

	pkBytes, err := hex.DecodeString(pkHex)
	if err != nil {
		t.Fatalf("invalid E2E_PRIVATE_KEY hex: %v", err)
	}
	if len(pkBytes) != 32 {
		t.Fatalf("E2E_PRIVATE_KEY must be 32 bytes, got %d", len(pkBytes))
	}

	var privateKey [32]byte
	copy(privateKey[:], pkBytes)

	chainID := uint64(11155111) // Sepolia

	// Step 1: Create context with ZeroDev middleware
	ctx, err := aa.NewContext(projectID, "", "", chainID, aa.ZeroDev)
	if err != nil {
		t.Fatalf("NewContext failed: %v", err)
	}
	defer ctx.Close()
	t.Log("Context created")

	// Step 2: Create account (Kernel v3.3, index 0)
	account, err := ctx.NewAccount(privateKey, aa.KernelV3_3, 0)
	if err != nil {
		t.Fatalf("NewAccount failed: %v", err)
	}
	defer account.Close()

	// Step 3: Get address
	addrHex, err := account.GetAddressHex()
	if err != nil {
		t.Fatalf("GetAddressHex failed: %v", err)
	}
	t.Logf("Account address: %s", addrHex)

	// Step 4: Build a call (send 0 ETH to self — noop)
	addr, _ := account.GetAddress()
	calls := []aa.Call{
		{
			Target:   addr,
			Value:    [32]byte{},
			Calldata: []byte{},
		},
	}

	// Step 5: Send UserOp via the high-level orchestrator
	hash, err := account.SendUserOp(calls)
	if err != nil {
		t.Fatalf("SendUserOp failed: %v", err)
	}

	hashHex := hex.EncodeToString(hash[:])
	t.Logf("UserOp hash: 0x%s", hashHex)

	// Verify hash is non-zero
	allZero := true
	for _, b := range hash {
		if b != 0 {
			allZero = false
			break
		}
	}
	if allZero {
		t.Fatal("UserOp hash is all zeros")
	}

	t.Log("SendUserOp SUCCESS!")
}
