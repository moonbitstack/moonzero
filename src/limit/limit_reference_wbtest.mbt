// Replay the reference limiter's decision table through this library's bucket.
//
// The table comes from the implementation go-zero ships rather than from a second
// implementation written here: `scripts/reference/limit_vector_gen.go` runs
// golang.org/x/time/rate — the bucket go-zero's Redis limiter falls back to — over a
// fixed sequence of (time, cost) asks, and `scripts/gen_reference_vectors.py` turns
// its output into `limit_vectors_wbtest.mbt`.

///|
test "the token bucket admits and refuses what the reference decides" {
  let vectors = limit_vectors()
  // A truncated table would replay green, so the row count is asserted too.
  assert_eq(vectors.length(), 56)
  // The reference bucket starts full and so does this one; only the clock differs,
  // and only the differences between readings reach the arithmetic.
  let bucket = TokenBucket::new(10.0, burst=20.0, now=0L)
  let mut disagreements = 0
  let mut first = ""
  for vector in vectors {
    let admitted = bucket.allow_n(vector.n.to_double(), vector.at_ms)
    if admitted != vector.allowed {
      disagreements = disagreements + 1
      if first == "" {
        first = "at " +
          vector.at_ms.to_string() +
          "ms for " +
          vector.n.to_string() +
          ": admitted " +
          admitted.to_string() +
          ", reference " +
          vector.allowed.to_string()
      }
    }
  }
  assert_eq(first, "")
  assert_eq(disagreements, 0)
}
