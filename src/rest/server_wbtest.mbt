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
test "period_limit rejects with 429, and assembles as a Server layer" {
  assert_eq(start_status(@handler.too_many.events()), 429)
  let app = @moonapi.App::new()
  app.get("/ping", _ctx => @moonapi.text(200, "pong"))
  let mc = @clock.ManualClock::new()
  let assembled = Server::new(@conf.ServiceConf::new(), app).use_(
    @handler.period_limit(
      @limit.PeriodLimit::new(period_secs=1, quota=5),
      mc.as_clock(),
    ),
  )
  let _ = assembled.to_asgi()
}

///|
test "resilience middlewares assemble onto an AsgiApp" {
  let app = @moonapi.App::new()
  app.get("/ping", _ctx => @moonapi.text(200, "pong"))
  let mc = @clock.ManualClock::new()
  let ck = mc.as_clock()
  let assembled = Server::new(@conf.ServiceConf::new(), app)
    .use_(@handler.maxbytes(1024))
    .use_(@handler.max_conns(@limit.MaxConns::new(100)))
    .use_(@handler.rate_limit(@limit.TokenBucket::new(10.0, now=0L), ck))
    .use_(@handler.breaker(@breaker.Breaker::new(ck)))
    .use_(@handler.timeout(2000L, ck))
    .use_(@handler.structured_logging(ck))
  let _ = assembled.to_asgi()
}

///|
test "config-driven server assembly + describe" {
  let app = @moonapi.App::new()
  app.get("/ping", _ctx => @moonapi.text(200, "pong"))
  let conf = @conf.ServiceConf::new(name="greet", host="127.0.0.1", port=12000)
  let server = Server::new(conf, app).use_(@handler.logging)
  assert_eq(server.describe(), "greet listening on 127.0.0.1:12000")
  let _ = server.to_asgi()
}

///|
test "full middleware onion assembles and describes" {
  let app = @moonapi.App::new()
  let g = Group::new(app, "/api")
  g.get("/health", _ctx => @moonapi.text(200, "ok"))
  assert_eq(app.handle(mkreq("GET", "/api/health")).status, 200)
  let conf = @conf.ServiceConf::new(
    name="svc",
    host="127.0.0.1",
    port=9000,
    log_level=Error,
  )
  let server = Server::new(conf, app)
    .use_(@handler.cors(@handler.CorsConf::new()))
    .use_(@handler.request_id())
    .use_(@handler.recovery)
    .use_(@handler.logging)
  assert_eq(server.describe(), "svc listening on 127.0.0.1:9000")
  let _ = server.to_asgi()
}
