package aa

/*
#cgo CFLAGS: -I${SRCDIR}/../../../include
#cgo LDFLAGS: ${SRCDIR}/../../../zig-out/lib/libzerodev_aa.a ${SRCDIR}/../../../zig-out/lib/libsecp256k1.a -lc
#include <stdlib.h>
#include <string.h>
#include "aa.h"
*/
import "C"
import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"unsafe"
)

// KernelVersion represents the Kernel smart account version.
type KernelVersion int

const (
	KernelV3_1 KernelVersion = 0
	KernelV3_2 KernelVersion = 1
	KernelV3_3 KernelVersion = 2
)

// GasMiddleware selects the gas pricing provider.
type GasMiddleware int

const (
	// GasZeroDev uses zd_getUserOperationGasPrice.
	GasZeroDev GasMiddleware = iota
)

// PaymasterMiddleware selects the paymaster sponsorship provider.
type PaymasterMiddleware int

const (
	// PaymasterNone sends unsponsored UserOps (user pays gas).
	PaymasterNone PaymasterMiddleware = iota
	// PaymasterZeroDev uses pm_getPaymasterStubData/pm_getPaymasterData.
	PaymasterZeroDev
)

// Signer wraps an opaque signer handle.
type Signer struct {
	ptr *C.aa_signer_t
}

// LocalSigner creates a signer from a 32-byte private key.
func LocalSigner(privateKey [32]byte) (*Signer, error) {
	cKey := (*C.uint8_t)(C.malloc(32))
	defer C.free(unsafe.Pointer(cKey))
	C.memcpy(unsafe.Pointer(cKey), unsafe.Pointer(&privateKey[0]), 32)

	var s *C.aa_signer_t
	status := C.aa_signer_local(cKey, &s)
	if status != C.AA_OK {
		return nil, fmt.Errorf("aa_signer_local failed: %s (code %d)", C.GoString(C.aa_get_last_error()), int(status))
	}
	return &Signer{ptr: s}, nil
}

// RpcSigner creates a signer that signs via a JSON-RPC endpoint (Privy, custodial, etc.).
func RpcSigner(rpcURL string, address [20]byte) (*Signer, error) {
	cURL := C.CString(rpcURL)
	defer C.free(unsafe.Pointer(cURL))

	cAddr := (*C.uint8_t)(C.malloc(20))
	defer C.free(unsafe.Pointer(cAddr))
	C.memcpy(unsafe.Pointer(cAddr), unsafe.Pointer(&address[0]), 20)

	var s *C.aa_signer_t
	status := C.aa_signer_rpc(cURL, cAddr, &s)
	if status != C.AA_OK {
		return nil, fmt.Errorf("aa_signer_rpc failed: %s (code %d)", C.GoString(C.aa_get_last_error()), int(status))
	}
	return &Signer{ptr: s}, nil
}

// Close destroys the signer handle.
func (s *Signer) Close() {
	if s.ptr != nil {
		C.aa_signer_destroy(s.ptr)
		s.ptr = nil
	}
}

// Context holds RPC URLs and chain configuration.
type Context struct {
	ctx *C.aa_context_t
}

// NewContext creates a new SDK context with the specified gas and paymaster middleware.
func NewContext(projectID, rpcURL, bundlerURL string, chainID uint64, gas GasMiddleware, paymaster PaymasterMiddleware) (*Context, error) {
	cProjectID := C.CString(projectID)
	defer C.free(unsafe.Pointer(cProjectID))
	cRpcURL := C.CString(rpcURL)
	defer C.free(unsafe.Pointer(cRpcURL))
	cBundlerURL := C.CString(bundlerURL)
	defer C.free(unsafe.Pointer(cBundlerURL))

	var ctx *C.aa_context_t
	status := C.aa_context_create(cProjectID, cRpcURL, cBundlerURL, C.uint64_t(chainID), &ctx)
	if status != C.AA_OK {
		return nil, fmt.Errorf("aa_context_create failed: %s (code %d)", C.GoString(C.aa_get_last_error()), int(status))
	}

	switch gas {
	case GasZeroDev:
		C.aa_context_set_gas_middleware(ctx, C.aa_gas_price_fn(C.aa_gas_zerodev))
	default:
		C.aa_context_destroy(ctx)
		return nil, fmt.Errorf("unknown gas middleware: %d", gas)
	}

	switch paymaster {
	case PaymasterZeroDev:
		C.aa_context_set_paymaster_middleware(ctx, C.aa_paymaster_fn(C.aa_paymaster_zerodev))
	case PaymasterNone:
		// No paymaster — send unsponsored
	default:
		C.aa_context_destroy(ctx)
		return nil, fmt.Errorf("unknown paymaster middleware: %d", paymaster)
	}

	return &Context{ctx: ctx}, nil
}

// Close destroys the context and frees resources.
func (c *Context) Close() {
	if c.ctx != nil {
		C.aa_context_destroy(c.ctx)
		c.ctx = nil
	}
}

// Account represents a Kernel smart account with an ECDSA validator.
type Account struct {
	acc *C.aa_account_t
	ctx *Context
}

// NewAccount creates a new Kernel account using the given signer.
func (c *Context) NewAccount(signer *Signer, version KernelVersion, index uint32) (*Account, error) {
	if c.ctx == nil {
		return nil, fmt.Errorf("context is nil")
	}
	if signer == nil || signer.ptr == nil {
		return nil, fmt.Errorf("signer is nil")
	}

	var acc *C.aa_account_t
	status := C.aa_account_create(c.ctx, signer.ptr, C.aa_kernel_version(version), C.uint32_t(index), &acc)
	if status != C.AA_OK {
		return nil, fmt.Errorf("aa_account_create failed: %s (code %d)", C.GoString(C.aa_get_last_error()), int(status))
	}

	return &Account{acc: acc, ctx: c}, nil
}

// Close destroys the account.
func (a *Account) Close() {
	if a.acc != nil {
		C.aa_account_destroy(a.acc)
		a.acc = nil
	}
}

// GetAddress returns the counterfactual smart account address.
func (a *Account) GetAddress() ([20]byte, error) {
	if a.acc == nil {
		return [20]byte{}, fmt.Errorf("account is nil")
	}

	var addr [20]byte
	status := C.aa_account_get_address(a.acc, (*C.uint8_t)(unsafe.Pointer(&addr[0])))
	if status != C.AA_OK {
		return [20]byte{}, fmt.Errorf("aa_account_get_address failed: %s (code %d)", C.GoString(C.aa_get_last_error()), int(status))
	}

	return addr, nil
}

// GetAddressHex returns the address as a 0x-prefixed hex string.
func (a *Account) GetAddressHex() (string, error) {
	addr, err := a.GetAddress()
	if err != nil {
		return "", err
	}
	return "0x" + hex.EncodeToString(addr[:]), nil
}

// Call represents a single call in a UserOp.
type Call struct {
	Target   [20]byte
	Value    [32]byte // u256, big-endian
	Calldata []byte
}

// UserOp wraps a C UserOp handle.
type UserOp struct {
	op *C.aa_userop_t
}

// BuildUserOp creates a UserOp from calls.
func (a *Account) BuildUserOp(calls []Call) (*UserOp, error) {
	if a.acc == nil {
		return nil, fmt.Errorf("account is nil")
	}
	if len(calls) == 0 {
		return nil, fmt.Errorf("no calls provided")
	}

	// Allocate C array in C memory
	cCalls := (*C.aa_call_t)(C.malloc(C.size_t(len(calls)) * C.size_t(unsafe.Sizeof(C.aa_call_t{}))))
	defer C.free(unsafe.Pointer(cCalls))

	callsSlice := unsafe.Slice(cCalls, len(calls))
	for i, call := range calls {
		var cCall C.aa_call_t
		C.memcpy(unsafe.Pointer(&cCall.target[0]), unsafe.Pointer(&call.Target[0]), 20)
		C.memcpy(unsafe.Pointer(&cCall.value_be[0]), unsafe.Pointer(&call.Value[0]), 32)

		if len(call.Calldata) > 0 {
			cCalldata := C.malloc(C.size_t(len(call.Calldata)))
			defer C.free(cCalldata)
			C.memcpy(cCalldata, unsafe.Pointer(&call.Calldata[0]), C.size_t(len(call.Calldata)))
			cCall.calldata = (*C.uint8_t)(cCalldata)
			cCall.calldata_len = C.size_t(len(call.Calldata))
		}

		callsSlice[i] = cCall
	}

	var op *C.aa_userop_t
	status := C.aa_userop_build(a.acc, cCalls, C.size_t(len(calls)), &op)
	if status != C.AA_OK {
		return nil, fmt.Errorf("aa_userop_build failed: %s (code %d)", C.GoString(C.aa_get_last_error()), int(status))
	}

	return &UserOp{op: op}, nil
}

// Hash computes the UserOp hash.
func (u *UserOp) Hash(a *Account) ([32]byte, error) {
	if u.op == nil {
		return [32]byte{}, fmt.Errorf("userop is nil")
	}
	if a.acc == nil {
		return [32]byte{}, fmt.Errorf("account is nil")
	}

	var hash [32]byte
	status := C.aa_userop_hash(u.op, a.acc, (*C.uint8_t)(unsafe.Pointer(&hash[0])))
	if status != C.AA_OK {
		return [32]byte{}, fmt.Errorf("aa_userop_hash failed: %s", C.GoString(C.aa_get_last_error()))
	}

	return hash, nil
}

// Sign signs the UserOp with the account's ECDSA key.
func (u *UserOp) Sign(a *Account) error {
	if u.op == nil {
		return fmt.Errorf("userop is nil")
	}
	if a.acc == nil {
		return fmt.Errorf("account is nil")
	}

	status := C.aa_userop_sign(u.op, a.acc)
	if status != C.AA_OK {
		return fmt.Errorf("aa_userop_sign failed: %s", C.GoString(C.aa_get_last_error()))
	}

	return nil
}

// ToJSON serializes the UserOp to JSON.
func (u *UserOp) ToJSON() (string, error) {
	if u.op == nil {
		return "", fmt.Errorf("userop is nil")
	}

	var jsonPtr *C.char
	var jsonLen C.size_t
	status := C.aa_userop_to_json(u.op, (**C.char)(unsafe.Pointer(&jsonPtr)), &jsonLen)
	if status != C.AA_OK {
		return "", fmt.Errorf("aa_userop_to_json failed: %s", C.GoString(C.aa_get_last_error()))
	}

	result := C.GoStringN(jsonPtr, C.int(jsonLen))
	C.aa_free(unsafe.Pointer(jsonPtr))
	return result, nil
}

// ApplyGasJSON applies gas estimates from a JSON response.
func (u *UserOp) ApplyGasJSON(gasJSON string) error {
	if u.op == nil {
		return fmt.Errorf("userop is nil")
	}

	cJSON := C.CString(gasJSON)
	defer C.free(unsafe.Pointer(cJSON))
	status := C.aa_userop_apply_gas_json(u.op, cJSON, C.size_t(len(gasJSON)))
	if status != C.AA_OK {
		return fmt.Errorf("aa_userop_apply_gas_json failed: %s", C.GoString(C.aa_get_last_error()))
	}

	return nil
}

// ApplyPaymasterJSON applies paymaster data from a JSON response.
func (u *UserOp) ApplyPaymasterJSON(pmJSON string) error {
	if u.op == nil {
		return fmt.Errorf("userop is nil")
	}

	cJSON := C.CString(pmJSON)
	defer C.free(unsafe.Pointer(cJSON))
	status := C.aa_userop_apply_paymaster_json(u.op, cJSON, C.size_t(len(pmJSON)))
	if status != C.AA_OK {
		return fmt.Errorf("aa_userop_apply_paymaster_json failed: %s", C.GoString(C.aa_get_last_error()))
	}

	return nil
}

// Close destroys the UserOp.
func (u *UserOp) Close() {
	if u.op != nil {
		C.aa_userop_destroy(u.op)
		u.op = nil
	}
}

// SendUserOp is the high-level API: build + sign + hash in one call.
func (a *Account) SendUserOp(calls []Call) ([32]byte, error) {
	if a.acc == nil {
		return [32]byte{}, fmt.Errorf("account is nil")
	}
	if len(calls) == 0 {
		return [32]byte{}, fmt.Errorf("no calls provided")
	}

	cCalls := (*C.aa_call_t)(C.malloc(C.size_t(len(calls)) * C.size_t(unsafe.Sizeof(C.aa_call_t{}))))
	defer C.free(unsafe.Pointer(cCalls))

	callsSlice := unsafe.Slice(cCalls, len(calls))
	for i, call := range calls {
		var cCall C.aa_call_t
		C.memcpy(unsafe.Pointer(&cCall.target[0]), unsafe.Pointer(&call.Target[0]), 20)
		C.memcpy(unsafe.Pointer(&cCall.value_be[0]), unsafe.Pointer(&call.Value[0]), 32)

		if len(call.Calldata) > 0 {
			cCalldata := C.malloc(C.size_t(len(call.Calldata)))
			defer C.free(cCalldata)
			C.memcpy(cCalldata, unsafe.Pointer(&call.Calldata[0]), C.size_t(len(call.Calldata)))
			cCall.calldata = (*C.uint8_t)(cCalldata)
			cCall.calldata_len = C.size_t(len(call.Calldata))
		}

		callsSlice[i] = cCall
	}

	var hash [32]byte
	status := C.aa_send_userop(a.acc, cCalls, C.size_t(len(calls)), (*C.uint8_t)(unsafe.Pointer(&hash[0])))
	if status != C.AA_OK {
		return [32]byte{}, fmt.Errorf("aa_send_userop failed: %s (code %d)", C.GoString(C.aa_get_last_error()), int(status))
	}

	return hash, nil
}

// UserOperationReceipt is the full receipt from eth_getUserOperationReceipt.
// Matches the viem UserOperationReceipt type.
type UserOperationReceipt struct {
	UserOpHash    string           `json:"userOpHash"`
	EntryPoint    string           `json:"entryPoint"`
	Sender        string           `json:"sender"`
	Nonce         string           `json:"nonce"`
	Paymaster     string           `json:"paymaster,omitempty"`
	ActualGasCost string           `json:"actualGasCost"`
	ActualGasUsed string           `json:"actualGasUsed"`
	Success       bool             `json:"success"`
	Reason        string           `json:"reason,omitempty"`
	Logs          []map[string]any `json:"logs"`
	Receipt       map[string]any   `json:"receipt"`
}

// WaitForUserOperationReceipt polls for a UserOp receipt until it's included or times out.
// Pass 0 for timeoutMs to use default (60s), 0 for pollIntervalMs to use default (2s).
func (a *Account) WaitForUserOperationReceipt(useropHash [32]byte, timeoutMs, pollIntervalMs uint32) (*UserOperationReceipt, error) {
	if a.acc == nil {
		return nil, fmt.Errorf("account is nil")
	}

	var jsonPtr *C.char
	var jsonLen C.size_t
	status := C.aa_wait_for_user_operation_receipt(
		a.acc,
		(*C.uint8_t)(unsafe.Pointer(&useropHash[0])),
		C.uint32_t(timeoutMs),
		C.uint32_t(pollIntervalMs),
		(**C.char)(unsafe.Pointer(&jsonPtr)),
		&jsonLen,
	)
	if status != C.AA_OK {
		return nil, fmt.Errorf("aa_wait_for_user_operation_receipt failed: %s (code %d)", C.GoString(C.aa_get_last_error()), int(status))
	}
	defer C.aa_free(unsafe.Pointer(jsonPtr))

	jsonBytes := C.GoBytes(unsafe.Pointer(jsonPtr), C.int(jsonLen))

	var receipt UserOperationReceipt
	if err := json.Unmarshal(jsonBytes, &receipt); err != nil {
		return nil, fmt.Errorf("failed to parse receipt JSON: %w", err)
	}

	return &receipt, nil
}

// GetLastError returns the last error message from the SDK.
func GetLastError() string {
	return C.GoString(C.aa_get_last_error())
}
