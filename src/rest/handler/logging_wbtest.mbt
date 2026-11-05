///|
/// A logger writing into `lines` instead of stdout.
fn collecting(
  lines : Array[String],
  level~ : @logx.LogLevel = Info,
  clock? : @clock.Clock,
) -> @logx.Logger {
  @logx.Logger::new(
    clock.unwrap_or(@clock.ManualClock::new(start=233L).as_clock()),
    level~,
    sink=@moonlog.Lines::new(line => lines.push(line)),
  )
}

///|
/// Read a string field out of a rendered JSON log line.
fn json_str(j : Json, key : String) -> String {
  match j {
    Object(m) =>
      match m.get(key) {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
/// Read a numeric field out of a rendered JSON log line.
fn json_num(j : Json, key : String) -> Double {
  match j {
    Object(m) =>
      match m.get(key) {
        Some(Number(n, ..)) => n
        _ => -1.0
      }
    _ => -1.0
  }
}

///|
test "an access record turns into the fields that go on the log entry" {
  let entry = RequestLog::{
    http_method: "GET",
    path: "/ping",
    status: 503,
    duration_ms: 12L,
    request_id: "req-7",
    client_ip: "127.0.0.1",
    user_agent: "curl/8",
  }
  let lines : Array[String] = []
  collecting(lines).info("x", fields=entry.fields())
  let j = @json.parse(lines[0])
  assert_eq(json_num(j, "status"), 503.0)
  assert_eq(json_num(j, "duration_ms"), 12.0)
  assert_eq(json_str(j, "client_ip"), "127.0.0.1")
  assert_eq(json_str(j, "user_agent"), "curl/8")
}

///|
test "structured request log renders stable JSON fields" {
  let entry = RequestLog::{
    http_method: "GET",
    path: "/ping",
    status: 200,
    duration_ms: 5L,
    request_id: "req-7",
    client_ip: "127.0.0.1",
    user_agent: "curl/8",
  }
  let j = @json.parse(entry.render())
  assert_eq(json_str(j, "method"), "GET")
  assert_eq(json_str(j, "path"), "/ping")
  assert_eq(json_num(j, "status"), 200.0)
  assert_eq(json_num(j, "duration_ms"), 5.0)
  assert_eq(json_str(j, "request_id"), "req-7")
  assert_eq(json_str(j, "client_ip"), "127.0.0.1")
  assert_eq(json_str(j, "user_agent"), "curl/8")
}

///|
test "client ip prefers the first X-Forwarded-For hop" {
  let fwd = scope_with([("x-forwarded-for", "1.2.3.4, 5.6.7.8")])
  assert_eq(client_ip_of(fwd), "1.2.3.4")
  // no forwarded header and no transport peer -> "-"
  assert_eq(client_ip_of(scope_with([])), "-")
}

///|
/// Drive an app with one request whose body is `body`, and collect the events it
/// answers with.
async fn log_run_body(
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
/// An app that reads its body and answers 200, recording what it read.
fn log_echo(seen : Ref[Bytes]) -> @moonasgi.AsgiApp {
  (scope, receive, send) => {
    let _ = scope
    seen.val = read_body(receive)
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
async test "a verbose entry carries the headers and a preview of the body" {
  let lines : Array[String] = []
  let manual = @clock.ManualClock::new(start=1_000L)
  let clock = manual.as_clock()
  let logger = collecting(lines, clock~)
  let seen : Ref[Bytes] = { val: b"", }
  let app = structured_logging(clock, logger~, verbose=true)(log_echo(seen))
  let body = b"{\"order\":42}"
  let _ = log_run_body(
    app,
    scope_with([("content-type", "application/json")]),
    body,
  )
  assert_eq(lines.length(), 1)
  let entry = @json.parse(lines[0]) catch { _ => Json::null() }
  // The request is described, and the handler still received every byte of it.
  assert_eq(json_str(entry, "request_body"), "{\"order\":42}")
  assert_eq(seen.val, body)
  match entry {
    Object(fields) =>
      match fields.get("request_headers") {
        Some(Object(headers)) =>
          assert_eq(
            headers.get("content-type"),
            Some(Json::string("application/json")),
          )
        _ => abort("a verbose entry carries the request headers")
      }
    _ => abort("an access entry is a JSON object")
  }
}

///|
async test "an ordinary entry carries neither headers nor body" {
  let lines : Array[String] = []
  let manual = @clock.ManualClock::new(start=1_000L)
  let clock = manual.as_clock()
  let logger = collecting(lines, clock~)
  let seen : Ref[Bytes] = { val: b"", }
  let app = structured_logging(clock, logger~)(log_echo(seen))
  let _ = log_run_body(
    app,
    scope_with([("content-type", "text/plain")]),
    b"body",
  )
  assert_eq(lines.length(), 1)
  let entry = @json.parse(lines[0]) catch { _ => Json::null() }
  match entry {
    Object(fields) => {
      assert_eq(fields.get("request_body") is None, true)
      assert_eq(fields.get("request_headers") is None, true)
    }
    _ => abort("an access entry is a JSON object")
  }
  // The body is still the handler's to read when nothing is logged about it.
  assert_eq(seen.val, b"body")
}

///|
test "a body preview is capped and marked when it was cut" {
  assert_eq(body_preview(b"short"), "short")
  let long = Bytes::make(verbose_body_preview + 10, b'a')
  let shown = body_preview(long)
  assert_eq(shown.has_suffix("…"), true)
  // The cap is on bytes, so the preview is the cap plus the mark.
  assert_eq(shown.length(), verbose_body_preview + 1)
}
