///|
/// Look up a header value by name in a header list.
fn header_of(headers : Array[(String, String)], name : String) -> String? {
  for pair in headers {
    if pair.0 == name {
      return Some(pair.1)
    }
  }
  None
}

///|
test "cors_headers advertises the configured policy" {
  let conf = CorsConf::new(
    allow_origin="https://example.com",
    allow_credentials=true,
  )
  let headers = cors_headers(conf)
  assert_eq(
    header_of(headers, "access-control-allow-origin"),
    Some("https://example.com"),
  )
  assert_eq(
    header_of(headers, "access-control-allow-credentials"),
    Some("true"),
  )
  assert_eq(header_of(headers, "access-control-max-age"), Some("86400"))
  assert_eq(
    header_of(headers, "access-control-allow-methods"),
    Some("GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS"),
  )
}

///|
test "cors_headers omits credentials when disabled" {
  let headers = cors_headers(CorsConf::new())
  assert_eq(header_of(headers, "access-control-allow-credentials"), None)
  assert_eq(header_of(headers, "access-control-allow-origin"), Some("*"))
}

///|
test "cors middleware assembles into an AsgiApp" {
  let app = @moonapi.App::new()
  app.get("/ping", _ctx => @moonapi.text(200, "pong"))
  let _ = cors(CorsConf::new())(app.to_asgi())
}

///|
test "request-id resolution mints and reuses" {
  let counter : Ref[Int32] = { val: 0, }
  assert_eq(resolve_request_id(None, counter), "req-1")
  assert_eq(resolve_request_id(None, counter), "req-2")
  assert_eq(resolve_request_id(Some("abc-123"), counter), "abc-123")
  // reuse does not advance the counter
  assert_eq(resolve_request_id(None, counter), "req-3")
}

///|
test "request-id reads the inbound header from an HTTP scope" {
  assert_eq(
    scope_header(scope_with([("x-request-id", "trace-9")]), "x-request-id"),
    Some("trace-9"),
  )
  assert_eq(scope_header(scope_with([]), "x-request-id"), None)
  let _ = request_id()(@moonapi.App::new().to_asgi())
}

///|
test "recovery emits a 500 with a body" {
  let events = internal_error_events()
  let mut status = 0
  let mut body_len = 0
  for e in events {
    match e {
      HttpResponseStart(status=s, ..) => status = s
      HttpResponseBody(body~, more_body=_) => body_len = body.length()
      _ => ()
    }
  }
  assert_eq(status, 500)
  assert_eq(body_len > 0, true)
}
