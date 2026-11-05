// The HTTP server metrics, on the Prometheus registry the process already owns.
//
// go-zero registers two families: a duration histogram and a code counter, both
// labelled `path`/`method`/`code`. The three stay three here — folding them into
// one `"GET /ping 200"` string makes the series unqueryable, because Prometheus
// cannot select on a substring of a label value.

///|
/// The latency buckets go-zero registers for a server route, in milliseconds.
pub let default_latency_buckets : Array[Double] = [
  5, 10, 25, 50, 100, 250, 500, 750, 1000,
]

///|
/// The content type a `/metrics` scrape carries so a Prometheus server reads the
/// body as the text exposition format.
pub let exposition_content_type : String = "text/plain; version=0.0.4; charset=utf-8"

///|
/// The label names both families carry, in the order `observe` fills them.
let server_labels : Array[String] = ["path", "method", "code"]

///|
/// The request metrics an HTTP service exposes: `http_server_requests_duration_ms`
/// and `http_server_requests_code_total`, each partitioned by `path`, `method` and
/// `code`. Held by the caller so it can be scraped after serving, and shared with
/// `RestEngine` so the `prometheus` layer and the `/metrics` route read one set.
pub struct ServerMetrics {
  registry : @moonp8s.Registry
  requests : @moonp8s.Family[@moonp8s.Counter]
  latency : @moonp8s.Family[@moonp8s.Histogram]
}

///|
/// A fresh metric set on its own registry — the two families ready, nothing
/// observed yet. Raises `Refused` only if a metric or label name is invalid,
/// which cannot happen for the fixed names here.
pub fn ServerMetrics::new() -> ServerMetrics raise @metric.Refused {
  let registry = @moonp8s.Registry::new()
  {
    registry,
    requests: @moonp8s.Family::new(server_labels, () => @moonp8s.Counter::new()),
    latency: @moonp8s.Family::new(server_labels, () => {
      @moonp8s.Histogram::new(buckets=default_latency_buckets)
    }),
  }
}

///|
/// The registry the families hang off, so a caller can add collectors of its own
/// and publish everything through one scrape.
pub fn ServerMetrics::registry(self : ServerMetrics) -> @moonp8s.Registry {
  self.registry
}

///|
/// The request counter family, labelled `path`, `method`, `code`.
pub fn ServerMetrics::requests(
  self : ServerMetrics,
) -> @moonp8s.Family[@moonp8s.Counter] {
  self.requests
}

///|
/// The request-duration family, in milliseconds, labelled `path`, `method`,
/// `code`.
pub fn ServerMetrics::latency(
  self : ServerMetrics,
) -> @moonp8s.Family[@moonp8s.Histogram] {
  self.latency
}

///|
/// Record one finished request: count it under its `path`/`method`/`code` and
/// observe `duration_ms`. A label set whose arity does not match the registered
/// names is dropped rather than raised — both families always carry three labels,
/// so this is unreachable from `observe_request`.
pub fn ServerMetrics::observe(
  self : ServerMetrics,
  path : String,
  verb : String,
  code : Int32,
  duration_ms : Double,
) -> Unit {
  let labels = [path, verb, code.to_string()]
  self.requests.labels(labels).inc() catch {
    _ => ()
  }
  self.latency.labels(labels).observe(duration_ms) catch {
    _ => ()
  }
}

///|
/// The counter value recorded for one route and status, `0` before the first
/// request. A read-out for tests and for a health endpoint that reports its own
/// traffic without scraping.
pub fn ServerMetrics::request_count(
  self : ServerMetrics,
  path : String,
  verb : String,
  code : Int32,
) -> Double {
  self.requests.labels([path, verb, code.to_string()]).get() catch {
    _ => 0.0
  }
}

///|
/// The latency observations recorded for one route and status.
pub fn ServerMetrics::latency_total(
  self : ServerMetrics,
  path : String,
  verb : String,
  code : Int32,
) -> Int64 {
  self.latency.labels([path, verb, code.to_string()]).total() catch {
    _ => 0L
  }
}

///|
/// Render this set as the Prometheus text exposition format — the body
/// `metrics_handler` serves.
pub fn ServerMetrics::to_exposition(self : ServerMetrics) -> String {
  let families : Array[@moonp8s.MetricFamily] = []
  families.push(@moonp8s.MetricFamily::{
    name: "http_server_requests_duration_ms",
    kind: Histogram,
    help: "http server requests duration(ms).",
    unit: None,
    metrics: self.latency.points(),
  })
  families.push(@moonp8s.MetricFamily::{
    name: "http_server_requests_code",
    kind: Counter,
    help: "http server requests code count.",
    unit: None,
    metrics: self.requests.points(),
  })
  for family in self.registry.collect() {
    families.push(family)
  }
  @moonp8s.text(families)
}

///|
/// A handler that serves the current metric set in the text exposition format,
/// with the Prometheus content type.
pub fn metrics_handler(m : ServerMetrics) -> @moonapi.ApiHandler {
  _ctx => {
    @moonasgi.Response::new(
      200,
      [("content-type", exposition_content_type)],
      @utf8.encode(m.to_exposition()),
    )
  }
}

///|
/// Register the `GET /metrics` scrape endpoint on `app`, so a Prometheus server
/// can pull the exposition.
pub fn mount_metrics(app : @moonapi.App, m : ServerMetrics) -> Unit {
  app.get("/metrics", metrics_handler(m))
}

///|
/// Metrics middleware: time each HTTP request on the shared clock and, when the
/// response starts, count it under its path, method and status and record its
/// latency in milliseconds. The record is taken once per request even if a
/// downstream emits a second start. Non-HTTP scopes pass through unmeasured.
pub fn metrics(m : ServerMetrics, clock : @clock.Clock) -> Middleware {
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
                  m.observe(
                    path,
                    verb,
                    status,
                    (clock.now() - start).to_double(),
                  )
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
