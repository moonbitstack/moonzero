///|
test "PeriodLimit admits up to quota within a window, then rejects" {
  let pl = PeriodLimit::new(period_secs=1, quota=3)
  assert_eq(pl.take("k", 0L), PeriodAllowed)
  assert_eq(pl.take("k", 100L), PeriodAllowed)
  assert_eq(pl.take("k", 200L), PeriodHitQuota)
  assert_eq(pl.take("k", 300L), PeriodOverQuota)
  assert_eq(pl.take("k", 400L), PeriodOverQuota)
}

///|
test "PeriodLimit opens a fresh window after the period elapses" {
  let pl = PeriodLimit::new(period_secs=1, quota=2)
  assert_eq(pl.take("k", 0L), PeriodAllowed) // window [0, 1000)
  assert_eq(pl.take("k", 500L), PeriodHitQuota)
  assert_eq(pl.take("k", 999L), PeriodOverQuota)
  assert_eq(pl.take("k", 1000L), PeriodAllowed) // now - 0 >= 1000 -> new window
  assert_eq(pl.take("k", 1200L), PeriodHitQuota)
}

///|
test "PeriodLimit tracks each key independently" {
  let pl = PeriodLimit::new(period_secs=1, quota=1)
  assert_eq(pl.take("a", 0L), PeriodHitQuota) // quota 1: the first request is the quota
  assert_eq(pl.take("a", 10L), PeriodOverQuota)
  assert_eq(pl.take("b", 10L), PeriodHitQuota) // b is a separate window
}
