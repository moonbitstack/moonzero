///|
test "metrics middleware assembles into an AsgiApp" {
  let app = @moonapi.App::new()
  app.get("/ping", _ctx => @moonapi.text(200, "pong"))
  let clock = @clock.ManualClock::new().as_clock()
  let _ = metrics(@metric.ServerMetrics::new(), clock)(app.to_asgi())
}

///|
test "mounted /metrics endpoint serves a scrapeable exposition" {
  let m = @metric.ServerMetrics::new()
  m.requests().add("GET /ping 200", 23333L)
  m.latency().observe(233.0)
  let app = @moonapi.App::new()
  mount_metrics(app, m)
  let _ = app.to_asgi()
  let ctx : @moonapi.Context = {
    request: {
      http_method: "GET",
      path: "/metrics",
      query_string: b"",
      headers: [],
      body: b"",
    },
    params: Map([]),
  }
  let resp = metrics_handler(m)(ctx) catch {
    e => fail("metrics handler must not raise: \{e}")
  }
  assert_eq(resp.header("content-type"), Some(@metric.exposition_content_type))
  let body = @utf8.decode_lossy(resp.body[:])
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
      "http_server_requests_code_total{request=\"GET /ping 200\"} 23333",
    ),
    true,
  )
  assert_eq(body.contains("http_server_requests_duration_ms_count 1"), true)
}
