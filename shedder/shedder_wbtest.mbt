///|
test "the shedder admits at the threshold and sheds above it" {
  let usage : Ref[Int64] = { val: 0L, }
  let s = Shedder::new(900L, usage=() => usage.val)
  assert_eq(s.allow(), true)
  usage.val = 900L
  assert_eq(s.allow(), true)
  usage.val = 901L
  assert_eq(s.allow(), false)
  // with no meter wired there is nothing to shed on
  assert_eq(Shedder::new(900L).usage(), 0L)
  assert_eq(Shedder::new(900L).allow(), true)
}
