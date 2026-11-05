// Request-body decompression: a client that sends `Content-Encoding: gzip` has its
// body inflated before the handler sees it, and one whose body will not inflate is
// told so instead of reaching the handler.

///|
/// What the application underneath a layer saw.
struct Seen {
  mut calls : Int32
  mut body : Bytes
  mut headers : Array[(String, String)]
}

///|
fn Seen::new() -> Seen {
  { calls: 0, body: b"", headers: [], }
}

///|
/// An app that records the request it was given and answers 200, so a test can
/// tell whether a layer passed the request on and in what shape.
fn recording(seen : Seen) -> @moonasgi.AsgiApp {
  (scope, receive, send) => {
    seen.calls = seen.calls + 1
    match scope {
      Http(hs) => seen.headers = hs.headers
      _ => ()
    }
    seen.body = read_body(receive)
    send(
      @moonasgi.Event::HttpResponseStart(
        status=200,
        headers=[("content-type", "text/plain")],
        trailers=false,
      ),
    )
    send(@moonasgi.Event::HttpResponseBody(body=b"ok", more_body=false))
  }
}

///|
/// A scope for one request with `headers` and a declared body length.
fn gzip_scope(headers : Array[(String, String)]) -> @moonasgi.Scope {
  @moonasgi.Scope::Http({
    http_version: "1.1",
    http_method: "POST",
    scheme: "http",
    path: "/upload",
    raw_path: None,
    query_string: b"",
    root_path: "",
    headers,
    client: None,
    server: None,
    asgi: @moonasgi.AsgiVersion::http(),
    extensions: @moonasgi.Extensions::none(),
    state: Map([]),
  })
}

///|
/// Drive an app with one request whose body is `body`.
async fn run_body(
  app : @moonasgi.AsgiApp,
  scope : @moonasgi.Scope,
  body : Bytes,
) -> Array[@moonasgi.Event] {
  let events : Array[@moonasgi.Event] = []
  let sent : Ref[Bool] = { val: false, }
  let receive : @moonasgi.Receive = () => {
    if sent.val {
      @moonasgi.Event::HttpDisconnect
    } else {
      sent.val = true
      @moonasgi.Event::HttpRequest(body~, more_body=false)
    }
  }
  app(scope, receive, event => events.push(event))
  events
}

///|
/// The status of an event list's response start.
fn response_status(events : Array[@moonasgi.Event]) -> Int32 {
  for event in events {
    match event {
      HttpResponseStart(status~, ..) => return status
      _ => ()
    }
  }
  0
}

///|
async test "a gzipped body reaches the handler as plain bytes" {
  let seen = Seen::new()
  let app = gunzip()(recording(seen))
  let events = run_body(
    app,
    gzip_scope([("content-encoding", "gzip")]),
    @gzip.gzip(b"{\"hello\":\"world\"}"),
  )
  assert_eq(response_status(events), 200)
  assert_eq(seen.calls, 1)
  assert_eq(seen.body, b"{\"hello\":\"world\"}")
}

///|
async test "the headers that described the compressed body are gone" {
  let seen = Seen::new()
  let app = gunzip()(recording(seen))
  let _ = run_body(
    app,
    gzip_scope([
      ("content-encoding", "gzip"),
      ("content-length", "35"),
      ("content-type", "application/json"),
    ]),
    @gzip.gzip(b"{\"hello\":\"world\"}"),
  )
  let mut encoding = ""
  let mut length = ""
  let mut content_type = ""
  for pair in seen.headers {
    if pair.0 == "content-encoding" {
      encoding = pair.1
    }
    if pair.0 == "content-length" {
      length = pair.1
    }
    if pair.0 == "content-type" {
      content_type = pair.1
    }
  }
  // A handler that trusted either of these would misread the request it was given.
  assert_eq(encoding, "")
  assert_eq(length, "")
  // Everything else is the client's, untouched.
  assert_eq(content_type, "application/json")
}

///|
async test "a body that will not inflate is refused before the handler" {
  let seen = Seen::new()
  let app = gunzip()(recording(seen))
  let events = run_body(
    app,
    gzip_scope([("content-encoding", "gzip")]),
    b"not gzip at all",
  )
  assert_eq(response_status(events), 400)
  assert_eq(seen.calls, 0)
}

///|
async test "a declared coding with no body behind it passes through" {
  let seen = Seen::new()
  let app = gunzip()(recording(seen))
  // A client that sets the header on an empty request is not sending a corrupt
  // body, and its handler still gets to run.
  let events = run_body(app, gzip_scope([("content-encoding", "gzip")]), b"")
  assert_eq(response_status(events), 200)
  assert_eq(seen.calls, 1)
  assert_eq(seen.body, b"")
}

///|
async test "a request without the header is untouched" {
  let seen = Seen::new()
  let app = gunzip()(recording(seen))
  let events = run_body(
    app,
    gzip_scope([("content-type", "text/plain")]),
    b"raw",
  )
  assert_eq(response_status(events), 200)
  assert_eq(seen.body, b"raw")
}

///|
async test "the decompressed size is what the cap is compared against" {
  let seen = Seen::new()
  let app = gunzip(limit=1_024)(recording(seen))
  // Ten kilobytes of one letter compresses to almost nothing: a body this size is
  // what a compression bomb looks like, and the cap is on the inflated side.
  let bomb = @gzip.gzip(Bytes::make(10_000, b'a'))
  let events = run_body(app, gzip_scope([("content-encoding", "gzip")]), bomb)
  assert_eq(response_status(events), 400)
  assert_eq(seen.calls, 0)
  // The same body under a cap that fits is served.
  let ok_seen = Seen::new()
  let roomy = gunzip(limit=20_000)(recording(ok_seen))
  let ok = run_body(
    roomy,
    gzip_scope([("content-encoding", "gzip")]),
    @gzip.gzip(Bytes::make(10_000, b'a')),
  )
  assert_eq(response_status(ok), 200)
  assert_eq(ok_seen.body.length(), 10_000)
}

///|
test "the coding is matched as a token, not as the whole header" {
  assert_eq(is_gzip_encoding("gzip"), true)
  assert_eq(is_gzip_encoding("GZIP"), true)
  assert_eq(is_gzip_encoding(" gzip "), true)
  assert_eq(is_gzip_encoding("br, gzip"), true)
  assert_eq(is_gzip_encoding("gzip, br"), true)
  assert_eq(is_gzip_encoding("br"), false)
  assert_eq(is_gzip_encoding("x-gzip"), false)
  assert_eq(is_gzip_encoding(""), false)
}
