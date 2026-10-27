///|
test "the system clock reads a real wall time" {
  let now = Clock::system().now()
  // milliseconds since the epoch, so comfortably past 2020
  assert_eq(now > 1_600_000_000_000L, true)
}

///|
test "manual clock advances and drives a Clock view" {
  let mc = ManualClock::new(start=100)
  let ck = mc.as_clock()
  assert_eq(ck.now(), 100L)
  mc.advance(50)
  assert_eq(ck.now(), 150L)
  mc.advance(1000)
  assert_eq(ck.now(), 1150L)
}
