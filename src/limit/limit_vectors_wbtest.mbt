// Generated from scripts/reference/limit_vectors.txt by
// scripts/gen_reference_vectors.py. Do not edit.

///|
/// One ask of the reference limiter: a cost, the time it was asked at, and
/// whether it was admitted.
struct LimitVector {
  at_ms : Int64
  n : Int32
  allowed : Bool
}

///|
fn limit_vectors() -> Array[LimitVector] {
  [
    { at_ms: 0L, n: 1, allowed: true, },
    { at_ms: 0L, n: 1, allowed: true, },
    { at_ms: 0L, n: 1, allowed: true, },
    { at_ms: 0L, n: 1, allowed: true, },
    { at_ms: 0L, n: 1, allowed: true, },
    { at_ms: 0L, n: 1, allowed: true, },
    { at_ms: 0L, n: 1, allowed: true, },
    { at_ms: 0L, n: 1, allowed: true, },
    { at_ms: 0L, n: 1, allowed: true, },
    { at_ms: 0L, n: 1, allowed: true, },
    { at_ms: 0L, n: 1, allowed: true, },
    { at_ms: 0L, n: 1, allowed: true, },
    { at_ms: 0L, n: 1, allowed: true, },
    { at_ms: 0L, n: 1, allowed: true, },
    { at_ms: 0L, n: 1, allowed: true, },
    { at_ms: 0L, n: 1, allowed: true, },
    { at_ms: 0L, n: 1, allowed: true, },
    { at_ms: 0L, n: 1, allowed: true, },
    { at_ms: 0L, n: 1, allowed: true, },
    { at_ms: 0L, n: 1, allowed: true, },
    { at_ms: 0L, n: 1, allowed: false, },
    { at_ms: 0L, n: 1, allowed: false, },
    { at_ms: 0L, n: 1, allowed: false, },
    { at_ms: 0L, n: 1, allowed: false, },
    { at_ms: 0L, n: 1, allowed: false, },
    { at_ms: 1000L, n: 1, allowed: true, },
    { at_ms: 1000L, n: 1, allowed: true, },
    { at_ms: 1000L, n: 1, allowed: true, },
    { at_ms: 1000L, n: 1, allowed: true, },
    { at_ms: 1000L, n: 1, allowed: true, },
    { at_ms: 1000L, n: 1, allowed: true, },
    { at_ms: 1000L, n: 1, allowed: true, },
    { at_ms: 1000L, n: 1, allowed: true, },
    { at_ms: 1000L, n: 1, allowed: true, },
    { at_ms: 1000L, n: 1, allowed: true, },
    { at_ms: 1000L, n: 1, allowed: false, },
    { at_ms: 1000L, n: 1, allowed: false, },
    { at_ms: 1000L, n: 1, allowed: false, },
    { at_ms: 1000L, n: 1, allowed: false, },
    { at_ms: 1000L, n: 1, allowed: false, },
    { at_ms: 1500L, n: 100, allowed: false, },
    { at_ms: 4000L, n: 3, allowed: true, },
    { at_ms: 10000L, n: 1, allowed: true, },
    { at_ms: 10000L, n: 1, allowed: true, },
    { at_ms: 10000L, n: 1, allowed: true, },
    { at_ms: 10000L, n: 1, allowed: true, },
    { at_ms: 10000L, n: 1, allowed: true, },
    { at_ms: 10000L, n: 3, allowed: true, },
    { at_ms: 10000L, n: 3, allowed: true, },
    { at_ms: 10000L, n: 3, allowed: true, },
    { at_ms: 10020L, n: 1, allowed: true, },
    { at_ms: 10020L, n: 1, allowed: true, },
    { at_ms: 10020L, n: 1, allowed: true, },
    { at_ms: 10020L, n: 1, allowed: true, },
    { at_ms: 10020L, n: 1, allowed: true, },
    { at_ms: 10020L, n: 1, allowed: true, },
  ]
}
