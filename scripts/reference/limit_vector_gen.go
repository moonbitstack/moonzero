// Emits the decisions go-zero's in-process token bucket makes over a fixed sequence
// of timestamps and costs, so another implementation can replay the sequence.
//
// The bucket is golang.org/x/time/rate, which is what go-zero's Redis limiter falls
// back to when redis is unreachable (`rescueLimiter` in core/limit/tokenlimit.go).
// Every decision is a function of (time, cost), so the sequence replays exactly.
//
// Run it inside a go-zero checkout, so the module's dependencies resolve:
//
//   cd <go-zero> && mkdir -p cmd/mzlimit && cp <this file> cmd/mzlimit/main.go
//   go run ./cmd/mzlimit > <moonzero>/scripts/reference/limit_vectors.txt

package main

import (
	"fmt"
	"time"

	"golang.org/x/time/rate"
)

const (
	ratePerSecond = 10
	burst         = 20
)

// step is one ask: n tokens at atMs milliseconds after the start.
type step struct {
	atMs int64
	n    int
}

func main() {
	limiter := rate.NewLimiter(rate.Limit(ratePerSecond), burst)

	steps := []step{}
	// The burst, spent in one instant.
	for i := 0; i < 25; i++ {
		steps = append(steps, step{0, 1})
	}
	// One second later: the bucket has refilled by the rate.
	for i := 0; i < 15; i++ {
		steps = append(steps, step{1_000, 1})
	}
	// Half a second on, a cost larger than the bucket can ever hold.
	steps = append(steps, step{1_500, 100})
	// Two and a half seconds on, a cost the refill covers.
	steps = append(steps, step{4_000, 3})
	// Ten seconds on, the bucket is full again whatever happened before.
	for i := 0; i < 5; i++ {
		steps = append(steps, step{10_000, 1})
	}
	for i := 0; i < 3; i++ {
		steps = append(steps, step{10_000, 3})
	}
	// A sub-token interval: 20ms at ten a second is a fifth of a token.
	for i := 0; i < 6; i++ {
		steps = append(steps, step{10_020, 1})
	}

	for _, s := range steps {
		allowed := limiter.AllowN(time.Unix(1_700_000_000, s.atMs*1_000_000), s.n)
		fmt.Printf("{\"at_ms\":%d,\"n\":%d,\"allowed\":%t}\n", s.atMs, s.n, allowed)
	}
}
