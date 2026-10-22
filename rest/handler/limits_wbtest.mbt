///|
test "deadline expiry and remaining budget" {
  let d = Deadline::start(1000L, 0L)
  assert_eq(d.expired(500L), false)
  assert_eq(d.remaining(500L), 500L)
  assert_eq(d.expired(1000L), true)
  assert_eq(d.remaining(1000L), 0L)
  assert_eq(d.remaining(5000L), 0L) // never negative
  // a non-positive budget is a disabled deadline
  let off = Deadline::start(0L, 0L)
  assert_eq(off.expired(999_999L), false)
  assert_eq(off.remaining(10L), -1L)
}

///|
test "maxbytes: content-length parsing and threshold, case-insensitive" {
  assert_eq(parse_uint("2048"), Some(2048))
  assert_eq(parse_uint(""), None)
  assert_eq(parse_uint("12a"), None)
  let big = scope_with([("content-length", "2000")])
  assert_eq(content_length_exceeds(big, 1024), true)
  assert_eq(content_length_exceeds(big, 4096), false)
  let mixed = scope_with([("Content-Length", "10")])
  assert_eq(content_length_exceeds(mixed, 5), true)
  // missing / unparseable length never trips
  assert_eq(content_length_exceeds(scope_with([]), 5), false)
}
