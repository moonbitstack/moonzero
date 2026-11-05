// The two RPC metric families, on moonp8s.
//
// A zRPC call is measured on two dimensions the HTTP side does not have: the
// method, because there is no route template to group by, and the status code,
// which is a number rather than an HTTP status. The names keep the reference
// implementation's `rpc_client_` and `rpc_server_` prefixes so a dashboard written
// for one reads the other.

///|
/// The per-method call metrics of one side of the wire.
pub struct RpcMetrics {
  registry : @moonp8s.Registry
  requests : @moonp8s.Family[@moonp8s.Counter]
  latency : @moonp8s.Family[@moonp8s.Histogram]
  prefix : String
  side : String
}

///|
/// The latency buckets the reference implementation registers for an RPC method.
pub let default_latency_buckets : Array[Double] = [
  1, 2, 5, 10, 25, 50, 100, 250, 500, 1000, 2000, 5000,
]

///|
/// Metrics for the client side (`kind="client"`) or the server side
/// (`kind="server"`).
pub fn RpcMetrics::new(
  kind~ : String = "client",
) -> RpcMetrics raise @metric.Refused {
  let prefix = "rpc_" + kind
  let registry = @moonp8s.Registry::new()
  {
    registry,
    requests: @moonp8s.Family::new(["method", "code"], () => {
      @moonp8s.Counter::new()
    }),
    latency: @moonp8s.Family::new(["method"], () => {
      @moonp8s.Histogram::new(buckets=default_latency_buckets)
    }),
    prefix,
    side: kind,
  }
}

///|
/// The registry these families hang off.
pub fn RpcMetrics::registry(self : RpcMetrics) -> @moonp8s.Registry {
  self.registry
}

///|
/// Record one finished call: its duration in milliseconds and its status code,
/// under the method's full path.
pub fn RpcMetrics::observe(
  self : RpcMetrics,
  path : String,
  status : Int32,
  duration_ms : Double,
) -> Unit {
  self.requests.labels([path, status.to_string()]).inc() catch {
    _ => ()
  }
  self.latency.labels([path]).observe(duration_ms) catch {
    _ => ()
  }
}

///|
/// The number of calls recorded for `path` with `status`.
pub fn RpcMetrics::calls(
  self : RpcMetrics,
  path : String,
  status : Int32,
) -> Double {
  self.requests.labels([path, status.to_string()]).get() catch {
    _ => 0.0
  }
}

///|
/// The latency observations recorded for `path`.
pub fn RpcMetrics::observations(self : RpcMetrics, path : String) -> Int64 {
  self.latency.labels([path]).total() catch {
    _ => 0L
  }
}

///|
/// The two families as the Prometheus text exposition a `/metrics` scrape reads.
pub fn RpcMetrics::to_exposition(self : RpcMetrics) -> String {
  let families : Array[@moonp8s.MetricFamily] = [
    @moonp8s.MetricFamily::{
      name: self.prefix + "_requests_duration_ms",
      kind: Histogram,
      help: "rpc " + self.side + " requests duration(ms).",
      unit: None,
      metrics: self.latency.points(),
    },
    @moonp8s.MetricFamily::{
      name: self.prefix + "_requests_code",
      kind: Counter,
      help: "rpc " + self.side + " requests code count.",
      unit: None,
      metrics: self.requests.points(),
    },
  ]
  @moonp8s.text(families)
}
