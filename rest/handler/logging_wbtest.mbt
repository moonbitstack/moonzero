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
    sink=@moonlog.Lines::new(line => lines.push(line), format=@logx.entry),
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
