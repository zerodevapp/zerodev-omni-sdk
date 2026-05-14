package aa

/*
#include <stdlib.h>
#include <string.h>
#include "aa.h"

extern int goSignHash(void *ctx, void *hash, void *sig_out);
extern int goSignMessage(void *ctx, void *msg, size_t msg_len, void *sig_out);
extern int goSignTypedDataHash(void *ctx, void *hash, void *sig_out);
extern int goGetAddress(void *ctx, void *addr_out);
extern int goSignAuthorization(void *ctx, uint64_t chain_id, void *address,
                                uint64_t nonce, void *out);

// Default vtable — sign_authorization left NULL so the SDK falls back to
// hashing the EIP-7702 auth tuple and calling sign_hash.
static inline aa_signer_vtable* get_go_signer_vtable() {
    static aa_signer_vtable vt = {
        (int (*)(void*, const uint8_t[32], uint8_t[65]))goSignHash,
        (int (*)(void*, const uint8_t*, size_t, uint8_t[65]))goSignMessage,
        (int (*)(void*, const uint8_t[32], uint8_t[65]))goSignTypedDataHash,
        (int (*)(void*, uint8_t[20]))goGetAddress,
        NULL,
    };
    return &vt;
}

// Vtable for custom signers that provide a native SignAuthorization callback.
// The SDK invokes sign_authorization directly instead of falling back.
static inline aa_signer_vtable* get_go_signer_vtable_with_auth() {
    static aa_signer_vtable vt = {
        (int (*)(void*, const uint8_t[32], uint8_t[65]))goSignHash,
        (int (*)(void*, const uint8_t*, size_t, uint8_t[65]))goSignMessage,
        (int (*)(void*, const uint8_t[32], uint8_t[65]))goSignTypedDataHash,
        (int (*)(void*, uint8_t[20]))goGetAddress,
        (int (*)(void*, uint64_t, const uint8_t[20], uint64_t, aa_authorization_t*))goSignAuthorization,
    };
    return &vt;
}
*/
import "C"
import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sync"
	"sync/atomic"
	"unsafe"
)

// KernelVersion represents the Kernel smart account version.
type KernelVersion int

const (
	KernelV3_3 KernelVersion = 0
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
	ptr      *C.aa_signer_t
	customID *uint64 // non-nil for custom signers; used to clean up registry
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

// GenerateSigner creates a signer with a randomly generated private key.
func GenerateSigner() (*Signer, error) {
	var s *C.aa_signer_t
	status := C.aa_signer_generate(&s)
	if status != C.AA_OK {
		return nil, fmt.Errorf("aa_signer_generate failed: %s (code %d)", C.GoString(C.aa_get_last_error()), int(status))
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

// Authorization is an EIP-7702 authorization tuple. `YParity`, `R`, and `S`
// together form the signature over keccak256(0x05 || rlp([chainId, address, nonce])).
type Authorization struct {
	ChainID uint64
	Address [20]byte
	Nonce   uint64
	YParity uint8
	R       [32]byte
	S       [32]byte
}

// SignerFuncs holds the Go callback functions for a custom signer.
//
// SignAuthorization is optional — when nil, the SDK falls back to computing
// keccak256(0x05 || rlp([chainId, address, nonce])) and invoking SignHash.
// Provide a native implementation for hardware wallets or MPC backends that
// expose an EIP-7702-aware signing primitive.
type SignerFuncs struct {
	SignHash          func(hash [32]byte) ([65]byte, error)
	SignMessage       func(msg []byte) ([65]byte, error)
	SignTypedDataHash func(hash [32]byte) ([65]byte, error)
	GetAddress        func() [20]byte
	SignAuthorization func(chainID uint64, address [20]byte, nonce uint64) (Authorization, error)
}

var (
	customSignerRegistry sync.Map
	customSignerCounter  atomic.Uint64
)

//export goSignHash
func goSignHash(ctx unsafe.Pointer, hash unsafe.Pointer, sigOut unsafe.Pointer) C.int {
	id := uint64(uintptr(ctx))
	val, ok := customSignerRegistry.Load(id)
	if !ok {
		return 1
	}
	fns := val.(*SignerFuncs)

	var h [32]byte
	copy(h[:], unsafe.Slice((*byte)(hash), 32))

	sig, err := fns.SignHash(h)
	if err != nil {
		return 1
	}

	copy(unsafe.Slice((*byte)(sigOut), 65), sig[:])
	return 0
}

//export goSignMessage
func goSignMessage(ctx unsafe.Pointer, msg unsafe.Pointer, msgLen C.size_t, sigOut unsafe.Pointer) C.int {
	id := uint64(uintptr(ctx))
	val, ok := customSignerRegistry.Load(id)
	if !ok {
		return 1
	}
	fns := val.(*SignerFuncs)

	goMsg := C.GoBytes(msg, C.int(msgLen))

	sig, err := fns.SignMessage(goMsg)
	if err != nil {
		return 1
	}

	copy(unsafe.Slice((*byte)(sigOut), 65), sig[:])
	return 0
}

//export goSignTypedDataHash
func goSignTypedDataHash(ctx unsafe.Pointer, hash unsafe.Pointer, sigOut unsafe.Pointer) C.int {
	id := uint64(uintptr(ctx))
	val, ok := customSignerRegistry.Load(id)
	if !ok {
		return 1
	}
	fns := val.(*SignerFuncs)

	var h [32]byte
	copy(h[:], unsafe.Slice((*byte)(hash), 32))

	sig, err := fns.SignTypedDataHash(h)
	if err != nil {
		return 1
	}

	copy(unsafe.Slice((*byte)(sigOut), 65), sig[:])
	return 0
}

//export goGetAddress
func goGetAddress(ctx unsafe.Pointer, addrOut unsafe.Pointer) C.int {
	id := uint64(uintptr(ctx))
	val, ok := customSignerRegistry.Load(id)
	if !ok {
		return 1
	}
	fns := val.(*SignerFuncs)

	addr := fns.GetAddress()
	copy(unsafe.Slice((*byte)(addrOut), 20), addr[:])
	return 0
}

//export goSignAuthorization
func goSignAuthorization(ctx unsafe.Pointer, chainID C.uint64_t, address unsafe.Pointer, nonce C.uint64_t, out unsafe.Pointer) C.int {
	id := uint64(uintptr(ctx))
	val, ok := customSignerRegistry.Load(id)
	if !ok {
		return 1
	}
	fns := val.(*SignerFuncs)
	if fns.SignAuthorization == nil {
		// Should never happen: this stub is only installed in the vtable when
		// the user provided SignAuthorization. Guard anyway.
		return 1
	}

	var addr [20]byte
	copy(addr[:], unsafe.Slice((*byte)(address), 20))

	auth, err := fns.SignAuthorization(uint64(chainID), addr, uint64(nonce))
	if err != nil {
		return 1
	}

	// Write into the C aa_authorization_t struct (layout defined in aa.h).
	cAuth := (*C.aa_authorization_t)(out)
	cAuth.chain_id = C.uint64_t(auth.ChainID)
	C.memcpy(unsafe.Pointer(&cAuth.address[0]), unsafe.Pointer(&auth.Address[0]), 20)
	cAuth.nonce = C.uint64_t(auth.Nonce)
	cAuth.y_parity = C.uint8_t(auth.YParity)
	C.memcpy(unsafe.Pointer(&cAuth.r[0]), unsafe.Pointer(&auth.R[0]), 32)
	C.memcpy(unsafe.Pointer(&cAuth.s[0]), unsafe.Pointer(&auth.S[0]), 32)
	return 0
}

// CustomSigner creates a signer backed by Go callback functions.
//
// If fns.SignAuthorization is non-nil, the SDK will call it directly for
// EIP-7702 authorization signing. Otherwise the SDK falls back to hashing the
// auth tuple and invoking fns.SignHash.
func CustomSigner(fns SignerFuncs) (*Signer, error) {
	id := customSignerCounter.Add(1)
	customSignerRegistry.Store(id, &fns)

	vtable := C.get_go_signer_vtable()
	if fns.SignAuthorization != nil {
		vtable = C.get_go_signer_vtable_with_auth()
	}

	var s *C.aa_signer_t
	status := C.aa_signer_custom(vtable, unsafe.Pointer(uintptr(id)), &s)
	if status != C.AA_OK {
		customSignerRegistry.Delete(id)
		return nil, fmt.Errorf("aa_signer_custom failed: %s (code %d)", C.GoString(C.aa_get_last_error()), int(status))
	}

	return &Signer{ptr: s, customID: &id}, nil
}

// SignAuthorization signs an EIP-7702 authorization tuple. Useful for
// pre-signing flows (hardware wallets, cold storage) where the authorization
// is attached to a UserOperation assembled elsewhere.
//
// Works on any signer type. For custom signers that did not provide a native
// SignAuthorization callback, the SDK computes
// keccak256(0x05 || rlp([chainId, address, nonce])) and signs the hash via
// SignHash automatically.
func (s *Signer) SignAuthorization(chainID uint64, address [20]byte, nonce uint64) (*Authorization, error) {
	if s == nil || s.ptr == nil {
		return nil, fmt.Errorf("signer is nil")
	}

	cAddr := (*C.uint8_t)(C.malloc(20))
	defer C.free(unsafe.Pointer(cAddr))
	C.memcpy(unsafe.Pointer(cAddr), unsafe.Pointer(&address[0]), 20)

	var out C.aa_authorization_t
	status := C.aa_signer_sign_authorization(s.ptr, C.uint64_t(chainID), cAddr, C.uint64_t(nonce), &out)
	if status != C.AA_OK {
		return nil, fmt.Errorf("aa_signer_sign_authorization failed: %s (code %d)", C.GoString(C.aa_get_last_error()), int(status))
	}

	auth := &Authorization{
		ChainID: uint64(out.chain_id),
		Nonce:   uint64(out.nonce),
		YParity: uint8(out.y_parity),
	}
	copy(auth.Address[:], C.GoBytes(unsafe.Pointer(&out.address[0]), 20))
	copy(auth.R[:], C.GoBytes(unsafe.Pointer(&out.r[0]), 32))
	copy(auth.S[:], C.GoBytes(unsafe.Pointer(&out.s[0]), 32))
	return auth, nil
}

// Close destroys the signer handle.
func (s *Signer) Close() {
	if s.ptr != nil {
		C.aa_signer_destroy(s.ptr)
		s.ptr = nil
	}
	if s.customID != nil {
		customSignerRegistry.Delete(*s.customID)
		s.customID = nil
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
//
// Audit F-09: Account holds strong references to both the parent Context and
// the Signer so neither is garbage-collected while the Account is alive. This
// prevents the use-after-free that would occur if the user let the Signer fall
// out of scope. Explicit signer.Close() still bypasses this — that's user
// error and documented as unsupported while an Account references the signer.
type Account struct {
	acc    *C.aa_account_t
	ctx    *Context
	signer *Signer
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

	return &Account{acc: acc, ctx: c, signer: signer}, nil
}

// NewAccount7702 creates a Kernel smart account using EIP-7702 delegation.
//
// The account's address is the signer's EOA address — there is no CREATE2, no
// init code, and no index. On the first UserOperation the SDK signs an
// authorization tuple (chainId, Kernel implementation for `version`, EOA nonce)
// and attaches it via the `eip7702Auth` field; subsequent UserOps skip the
// authorization once delegation is installed on-chain.
//
// Today only KernelV3_3 supports EIP-7702; passing another version returns an
// error.
func (c *Context) NewAccount7702(signer *Signer, version KernelVersion) (*Account, error) {
	if c.ctx == nil {
		return nil, fmt.Errorf("context is nil")
	}
	if signer == nil || signer.ptr == nil {
		return nil, fmt.Errorf("signer is nil")
	}

	var acc *C.aa_account_t
	status := C.aa_context_new_account_7702(c.ctx, signer.ptr, C.aa_kernel_version(version), &acc)
	if status != C.AA_OK {
		return nil, fmt.Errorf("aa_context_new_account_7702 failed: %s (code %d)", C.GoString(C.aa_get_last_error()), int(status))
	}

	return &Account{acc: acc, ctx: c, signer: signer}, nil
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
