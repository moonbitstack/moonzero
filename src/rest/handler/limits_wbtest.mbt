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
