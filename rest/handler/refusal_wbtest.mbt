///|
/// The status carried by an event array's `HttpResponseStart`, or `0`.
fn start_status(events : Array[@moonasgi.Event]) -> Int32 {
  for e in events {
    match e {
      HttpResponseStart(status~, ..) => return status
      _ => ()
    }
  }
  0
}

///|
test "reject responses carry the right status codes" {
  assert_eq(start_status(too_many.events()), 429)
  assert_eq(start_status(unavailable.events()), 503)
  assert_eq(start_status(timed_out.events()), 503)
  assert_eq(start_status(too_large.events()), 413)
}

///|
/// The refusal is a knob at both ends: the presets are go-zero's, and the same
/// three spellings of a changed one agree.
test "a refusal is a knob, and its three spellings agree" {
  let named = Refusal::new(status=429, body=b"slow down")
  let updated = { ..unavailable, status: 429, body: b"slow down", }
  assert_eq(named.status, updated.status)
  assert_eq(named.body, updated.body)
  assert_eq(named.headers, updated.headers)
  assert_eq(start_status(named.events()), 429)
  // Gateways that answer 429 where the service alone answers 503.
  let shed = Refusal::new(status=429)
  assert_eq(start_status(shed.events()), 429)
  assert_eq(start_status(unavailable.events()), 503)
  // The headers travel with it.
  let json = Refusal::new(status=503, body=b"{}", headers=[
    ("content-type", "application/json"),
  ])
  let mut seen = ""
  for e in json.events() {
    match e {
      HttpResponseStart(headers~, ..) => seen = headers[0].1
      _ => ()
    }
  }
  assert_eq(seen, "application/json")
}
