///|
test "a CPU spike with nothing queued sheds nothing" {
  let usage : Ref[Int64] = { val: 1000L, }
  let mc = @clock.ManualClock::new()
  let s = Shedder::new(mc.as_clock(), usage=() => usage.val)
  for _ in 0..<50 {
    guard s.allow() is Some(t) else { fail("shed with nothing in flight") }
    mc.advance(1)
    t.pass()
  }
  assert_eq(Shedder::new(mc.as_clock()).usage(), 0L)
}

///|
test "a hot server with requests piling up sheds the next one" {
  let usage : Ref[Int64] = { val: 0L, }
  let mc = @clock.ManualClock::new()
  let s = Shedder::new(mc.as_clock(), usage=() => usage.val)
  let held = Array::makei(5, _ => s.allow().unwrap())
  for _ in 0..<40 {
    guard s.allow() is Some(t) else { fail("shed while cool") }
    mc.advance(1)
    t.pass()
  }
  usage.val = 1000L
  assert_eq(s.allow() is None, true)
  for t in held {
    t.fail()
  }
}
