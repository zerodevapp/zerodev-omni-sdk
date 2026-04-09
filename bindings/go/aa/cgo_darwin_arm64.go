//go:build darwin && arm64

package aa

// #cgo CFLAGS: -I${SRCDIR}/native/include
// #cgo LDFLAGS: ${SRCDIR}/native/darwin_arm64/libzerodev_aa.a ${SRCDIR}/native/darwin_arm64/libsecp256k1.a -lc -framework Security
import "C"
