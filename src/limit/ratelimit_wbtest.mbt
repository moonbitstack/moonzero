///|
test "token bucket allows the burst then blocks, and refills over time" {
  // 1000 tokens/sec == 1 token/ms; burst of 3, full at t=0.
  let b = TokenBucket::new(1000.0, burst=3.0, now=0L)
  assert_eq(b.allow(0L), true) // 3 -> 2
  assert_eq(b.allow(0L), true) // 2 -> 1
  assert_eq(b.allow(0L), true) // 1 -> 0
  assert_eq(b.allow(0L), false) // empty -> blocked
  // 2 ms later, 2 tokens have refilled
  assert_eq(b.available(2L) >= 2.0, true)
  assert_eq(b.allow(2L), true)
  assert_eq(b.allow(2L), true)
  assert_eq(b.allow(2L), false)
  // refill is capped at the burst capacity, never above
  assert_eq(b.available(1_000_000L) <= 3.0, true)
}

///|
test "token bucket: default burst equals the rate" {
  let b = TokenBucket::new(4.0, now=0L)
  assert_eq(b.available(0L), 4.0)
  assert_eq(b.allow_n(4.0, 0L), true)
  assert_eq(b.allow(0L), false)
}
