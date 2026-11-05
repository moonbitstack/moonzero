///|
test "metrics middleware assembles into an AsgiApp" {
  let app = @moonapi.App::new()
  app.get("/ping", _ctx => @moonapi.text(200, "pong"))
  let clock = @clock.ManualClock::new().as_clock()
  let m = ServerMetrics::new() catch {
    _ => fail("the fixed metric names must register")
  }
  let _ = metrics(m, clock)(app.to_asgi())
}

///|
test "a scrape carries three labels, not one flattened string" {
  let m = ServerMetrics::new() catch {
    _ => fail("the fixed metric names must register")
  }
  m.observe("/ping", "GET", 200, 23.0)
  m.observe("/ping", "GET", 200, 31.0)
  m.observe("/ping", "GET", 503, 7.0)
  let body = m.to_exposition()
  assert_eq(
    body.contains("# TYPE http_server_requests_duration_ms histogram"),
    true,
  )
  assert_eq(
    body.contains("# TYPE http_server_requests_code_total counter"),
    true,
  )
  assert_eq(
    body.contains(
      "http_server_requests_code_total{code=\"200\",method=\"GET\",path=\"/ping\"} 2.0",
    ),
    true,
  )
  assert_eq(m.request_count("/ping", "GET", 200), 2.0)
  assert_eq(m.request_count("/ping", "GET", 503), 1.0)
  assert_eq(m.latency_total("/ping", "GET", 200), 2L)
}

///|
async test "mounted /metrics endpoint serves a scrapeable exposition" {
  let m = ServerMetrics::new() catch {
    _ => fail("the fixed metric names must register")
  }
  m.observe("/ping", "GET", 200, 233.0)
  let app = @moonapi.App::new()
  mount_metrics(app, m)
  let ctx = @moonapi.Context::new({
    http_method: "GET",
    path: "/metrics",
    query_string: b"",
    headers: [],
    body: b"",
  })
  let resp = metrics_handler(m)(ctx) catch {
    e => fail("metrics handler must not raise: \{e}")
  }
  assert_eq(resp.header("content-type"), Some(exposition_content_type))
  let body = @utf8.decode_lossy(resp.body[:])
  assert_eq(
    body.contains(
      "_bucket{code=\"200\",le=\"25.0\",method=\"GET\",path=\"/ping\"}",
    ),
    true,
  )
  assert_eq(body.contains("http_server_requests_duration_ms_count"), true)
}
