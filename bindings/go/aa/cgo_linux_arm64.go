//go:build linux && arm64

package aa

// #cgo CFLAGS: -I${SRCDIR}/native/include
// #cgo LDFLAGS: ${SRCDIR}/native/linux_arm64/libzerodev_aa.a ${SRCDIR}/native/linux_arm64/libsecp256k1.a -lc -lm
import "C"
