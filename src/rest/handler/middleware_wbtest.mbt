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
test "an allowed origin is echoed back with credentials" {
  let conf = CorsConf::new(origins=["https://example.com"])
  let headers = cors_response_headers(conf, Some("https://example.com"))
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
    Some(cors_methods),
  )
}

///|
test "the wildcard origin never advertises credentials" {
  let headers = cors_response_headers(
    CorsConf::new(),
    Some("https://any.example"),
  )
  assert_eq(header_of(headers, "access-control-allow-credentials"), None)
  assert_eq(header_of(headers, "access-control-allow-origin"), Some("*"))
}

///|
test "an origin outside the policy gets no CORS headers" {
  let conf = CorsConf::new(origins=["https://example.com"])
  let headers = cors_response_headers(conf, Some("https://evil.example"))
  assert_eq(headers.length(), 0)
}

///|
test "an allowed origin covers its own subdomains" {
  assert_eq(cors_allows(["example.com"], "https://api.example.com"), true)
  assert_eq(cors_allows(["https://example.com"], "https://example.com"), true)
  assert_eq(cors_allows(["exam00.com"], "https://sub.exam00.com"), true)
  assert_eq(cors_allows(["example.com"], "https://notexample.com"), false)
  assert_eq(cors_allows(["*"], "https://anything.example"), true)
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

///|
async test "recovery answers 500 only while the response has not started" {
  let raising : @moonasgi.AsgiApp = (_scope, _receive, _send) => {
    raise Failure("handler blew up")
  }
  let events = run_app(
    recovery(raising),
    @moonasgi.Scope::Http(
      @moonasgi.HttpScope::new(http_method="GET", path="/x"),
    ),
  )
  assert_eq(events[0] is HttpResponseStart(status=500, ..), true)

  // Once the response has started, the error is re-raised instead of appending a
  // second status line to a response the client is already reading.
  let half : @moonasgi.AsgiApp = (_scope, _receive, send) => {
    send(
      @moonasgi.Event::HttpResponseStart(status=200, headers=[], trailers=false),
    )
    raise Failure("late failure")
  }
  let outcome = try {
    let events = run_app(
      recovery(half),
      @moonasgi.Scope::Http(
        @moonasgi.HttpScope::new(http_method="GET", path="/x"),
      ),
    )
    Ok(events.length())
  } catch {
    error => Err(error)
  }
  assert_eq(outcome is Err(_), true)
}
