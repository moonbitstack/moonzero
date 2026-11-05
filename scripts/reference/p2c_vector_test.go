package p2c

// Reference vectors for the two-node comparison in `p2cPicker.choose`.
//
// This file must live inside a go-zero checkout, beside the implementation whose
// decisions it records, because the picker and its nodes are package-private:
//
//   cp scripts/reference/p2c_vector_test.go \
//      $(go env GOMODCACHE)/../go-zero/zrpc/internal/balancer/p2c/
//   cd <go-zero> && go test ./zrpc/internal/balancer/p2c -run TestEmitVectors -v \
//     | grep '^{' > scripts/reference/p2c_vectors.txt
//
// A node's state is expressed in milliseconds and scaled to the nanoseconds the
// picker keeps internally, and a pick time is expressed as an age rather than an
// absolute reading — the only form that can be replayed under another clock.

import (
	"fmt"
	"sync/atomic"
	"testing"

	"github.com/zeromicro/go-zero/core/timex"
)

// node builds a subConn with the given state, `ageMs` milliseconds after its last
// pick at `now`.
func node(lagMs float64, inflight int64, ageMs int64, now int64) *subConn {
	c := &subConn{success: initSuccess}
	atomic.StoreUint64(&c.lag, uint64(lagMs*1e6))
	atomic.StoreInt64(&c.inflight, inflight)
	atomic.StoreInt64(&c.pick, now-ageMs*1e6)
	return c
}

// TestEmitVectors prints one JSON object per decision.
func TestEmitVectors(t *testing.T) {
	lags := []float64{0, 1, 4, 100, 400, 10_000}
	inflights := []int64{0, 1, 4}
	ages := []int64{0, 500, 999, 1_001, 5_000}

	for _, lagA := range lags {
		for _, inflightA := range inflights {
			for _, lagB := range lags {
				for _, inflightB := range inflights {
					for _, ageB := range ages {
						now := int64(timex.Now())
						a := node(lagA, inflightA, 100, now)
						b := node(lagB, inflightB, ageB, now)
						picker := &p2cPicker{conns: []*subConn{a, b}}
						chosen := picker.choose(a, b)
						name := "a"
						if chosen == b {
							name = "b"
						}
						fmt.Printf(
							`{"lag_a":%v,"inflight_a":%d,"age_a":100,`+
								`"lag_b":%v,"inflight_b":%d,"age_b":%d,`+
								`"expected":"%s"}`+"\n",
							lagA, inflightA, lagB, inflightB, ageB, name)
					}
				}
			}
		}
	}
}
