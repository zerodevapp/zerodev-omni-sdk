//go:build linux && amd64

package aa

// #cgo CFLAGS: -I${SRCDIR}/native/include
// #cgo LDFLAGS: ${SRCDIR}/native/linux_amd64/libzerodev_aa.a ${SRCDIR}/native/linux_amd64/libsecp256k1.a -lc -lm
import "C"
