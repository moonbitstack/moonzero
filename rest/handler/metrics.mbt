///|
/// A handler that serves the current metric set in the text exposition format,
/// with the Prometheus content type — the scrape target go-zero's
/// `prometheus.StartAgent` publishes at `/metrics`.
pub fn metrics_handler(m : @metric.ServerMetrics) -> @moonapi.ApiHandler {
  _ctx => {
    @moonasgi.Response::new(
      200,
      [("content-type", @metric.exposition_content_type)],
      @utf8.encode(m.to_exposition()),
    )
  }
}

///|
/// Register the `GET /metrics` scrape endpoint on `app` (← go-zero's
/// `prometheus.StartAgent`), so a Prometheus server can pull the exposition.
pub fn mount_metrics(app : @moonapi.App, m : @metric.ServerMetrics) -> Unit {
  app.get("/metrics", metrics_handler(m))
}

///|
/// Metrics middleware (← go-zero's `prometheus` interceptor): time each HTTP
/// request on the shared clock and, when the response starts, count it under
/// `"<METHOD> <path> <status>"` and record its latency in milliseconds. The
/// record is taken once per request even if a downstream (under a recovery race)
/// emits a second start. Non-HTTP scopes pass through unmeasured.
pub fn metrics(m : @metric.ServerMetrics, clock : @clock.Clock) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(hs) => {
          let start = clock.now()
          let verb = hs.http_method
          let path = hs.path
          let recorded : Ref[Bool] = { val: false, }
          let observed : @moonasgi.Send = event => {
            match event {
              HttpResponseStart(status~, headers~, trailers~) => {
                if !recorded.val {
                  recorded.val = true
                  m.requests.inc(verb + " " + path + " " + status.to_string())
                  m.latency.observe((clock.now() - start).to_double())
                }
                send(
                  @moonasgi.Event::HttpResponseStart(
                    status~,
                    headers~,
                    trailers~,
                  ),
                )
              }
              other => send(other)
            }
          }
          inner(scope, receive, observed)
        }
        _ => inner(scope, receive, send)
      }
    }
  }
}
