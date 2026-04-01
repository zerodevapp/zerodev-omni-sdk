module github.com/zerodevapp/zerodev-omni-sdk/examples/privy-signer

go 1.23.0

require (
	github.com/privy-io/go-sdk v0.3.0
	github.com/zerodevapp/zerodev-omni-sdk/bindings/go v0.0.0
)

require (
	github.com/cloudflare/circl v1.6.3 // indirect
	github.com/cyberphone/json-canonicalization v0.0.0-20241213102144-19d51d7fe467 // indirect
	github.com/tidwall/gjson v1.18.0 // indirect
	github.com/tidwall/match v1.1.1 // indirect
	github.com/tidwall/pretty v1.2.1 // indirect
	github.com/tidwall/sjson v1.2.5 // indirect
	golang.org/x/crypto v0.41.0 // indirect
	golang.org/x/sys v0.35.0 // indirect
)

replace github.com/zerodevapp/zerodev-omni-sdk/bindings/go => ../../../bindings/go
