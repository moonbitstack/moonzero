///|
/// Which of the zRPC server's own interceptors are installed (← go-zero's
/// `RpcServerMiddlewaresConf`). All eight default to on; a service narrows the
/// chain from its config rather than from code.
#derive(FromJson, Eq, Debug)
pub(all) struct RpcServerMiddlewaresConf {
  trace : Bool
  recover : Bool
  stat : Bool
  prometheus : Bool
  breaker : Bool
  shedding : Bool
  timeout : Bool
  auth : Bool
}

///|
/// The full server chain, which is what the reference implementation defaults to.
pub fn RpcServerMiddlewaresConf::new(
  trace~ : Bool = true,
  recover~ : Bool = true,
  stat~ : Bool = true,
  prometheus~ : Bool = true,
  breaker~ : Bool = true,
  shedding~ : Bool = true,
  timeout~ : Bool = true,
  auth~ : Bool = true,
) -> RpcServerMiddlewaresConf {
  { trace, recover, stat, prometheus, breaker, shedding, timeout, auth, }
}

///|
pub extend RpcServerMiddlewaresConf with @json.FromJson::{from_json}

///|
pub extend RpcServerMiddlewaresConf with Debug::{to_repr}

///|
pub extend RpcServerMiddlewaresConf with Eq::{not_equal, equal}

///|
/// Which of the zRPC client's interceptors are installed (←
/// `RpcClientMiddlewaresConf`). Five, and all on by default.
#derive(FromJson, Eq, Debug)
pub(all) struct RpcClientMiddlewaresConf {
  trace : Bool
  log : Bool
  prometheus : Bool
  breaker : Bool
  timeout : Bool
}

///|
/// The full client chain.
pub fn RpcClientMiddlewaresConf::new(
  trace~ : Bool = true,
  log~ : Bool = true,
  prometheus~ : Bool = true,
  breaker~ : Bool = true,
  timeout~ : Bool = true,
) -> RpcClientMiddlewaresConf {
  { trace, log, prometheus, breaker, timeout, }
}

///|
pub extend RpcClientMiddlewaresConf with @json.FromJson::{from_json}

///|
pub extend RpcClientMiddlewaresConf with Debug::{to_repr}

///|
pub extend RpcClientMiddlewaresConf with Eq::{not_equal, equal}

///|
/// zRPC server configuration (← go-zero's `RpcServerConf`): the service name, the
/// address it listens on, a per-call timeout in milliseconds (`0` disables it),
/// the two CPU thresholds, whether peers must authenticate, and which interceptors
/// run.
///
/// The registry block of the reference implementation's conf is modelled by the
/// discovery layer instead; everything transport-facing is here.
#derive(FromJson, Eq, Debug)
pub(all) struct RpcServerConf {
  name : String
  host : String
  port : Int32
  timeout_ms : Int32
  cpu_threshold : Int64
  cpu_threshold_overload : Int64
  auth : Bool
  health : Bool
  middlewares : RpcServerMiddlewaresConf
}

///|
/// Build an RPC server config with the reference implementation's defaults: the
/// family's rpc port, a 2s timeout, 90% CPU as the shed threshold and 95% as the
/// overload threshold.
pub fn RpcServerConf::new(
  name~ : String = "rpc",
  host~ : String = "0.0.0.0",
  port~ : Int32 = rpc_port,
  timeout_ms~ : Int32 = 2000,
  cpu_threshold~ : Int64 = 900L,
  cpu_threshold_overload~ : Int64 = 950L,
  auth~ : Bool = false,
  health~ : Bool = true,
  middlewares~ : RpcServerMiddlewaresConf = RpcServerMiddlewaresConf::new(),
) -> RpcServerConf {
  {
    name,
    host,
    port,
    timeout_ms,
    cpu_threshold,
    cpu_threshold_overload,
    auth,
    health,
    middlewares,
  }
}

///|
pub extend RpcServerConf with Debug::{to_repr}

///|
pub extend RpcServerConf with Eq::{not_equal, equal}

///|
/// Load an `RpcServerConf` from a JSON config string, filling omitted fields from
/// the `new()` defaults — the lenient loader matching the reference
/// implementation's `,optional`/`,default=` config tags.
pub fn RpcServerConf::from_json(src : String) -> RpcServerConf raise Refused {
  rpc_conf_of(Conf::of_json(src))
}

///|
/// Load an `RpcServerConf` from a YAML config string, with the same
/// default-filling semantics as `from_json`.
pub fn RpcServerConf::from_yaml(src : String) -> RpcServerConf raise Refused {
  rpc_conf_of(Conf::of_yaml(src))
}

///|
/// Decode an `RpcServerConf` from a loaded document.
fn rpc_conf_of(c : Conf) -> RpcServerConf raise Refused {
  let def = RpcServerConf::new()
  {
    name: c.string("Name", default=def.name),
    host: c.string("Host", default=def.host),
    port: c.int("Port", default=def.port),
    timeout_ms: c.int("Timeout", default=def.timeout_ms, also=["TimeoutMs"]),
    cpu_threshold: c.int64(
      "CpuThreshold",
      default=def.cpu_threshold,
      range="[0:1000]",
    ),
    cpu_threshold_overload: c.int64(
      "CpuThresholdOverload",
      default=def.cpu_threshold_overload,
      range="[0:1000]",
    ),
    auth: c.bool("Auth", default=def.auth),
    health: c.bool("Health", default=def.health),
    middlewares: rpc_server_middlewares_of(c),
  }
}

///|
/// Decode the server's `Middlewares` block.
fn rpc_server_middlewares_of(
  c : Conf,
) -> RpcServerMiddlewaresConf raise Refused {
  {
    trace: c.bool("Middlewares.Trace", default=true),
    recover: c.bool("Middlewares.Recover", default=true),
    stat: c.bool("Middlewares.Stat", default=true),
    prometheus: c.bool("Middlewares.Prometheus", default=true),
    breaker: c.bool("Middlewares.Breaker", default=true),
    shedding: c.bool("Middlewares.Shedding", default=true),
    timeout: c.bool("Middlewares.Timeout", default=true),
    auth: c.bool("Middlewares.Auth", default=true),
  }
}

///|
/// zRPC client configuration (← go-zero's `RpcClientConf`): where a service is —
/// a direct `Target`, a list of `Endpoints`, or a name the discovery layer
/// resolves — plus the call timeout and which interceptors run.
#derive(FromJson, Eq, Debug)
pub(all) struct RpcClientConf {
  target : String
  endpoints : Array[String]
  timeout_ms : Int32
  non_block : Bool
  middlewares : RpcClientMiddlewaresConf
}

///|
/// A client config with a 2s call timeout and the full interceptor chain.
pub fn RpcClientConf::new(
  target~ : String = "",
  endpoints~ : Array[String] = [],
  timeout_ms~ : Int32 = 2000,
  non_block~ : Bool = false,
  middlewares~ : RpcClientMiddlewaresConf = RpcClientMiddlewaresConf::new(),
) -> RpcClientConf {
  { target, endpoints, timeout_ms, non_block, middlewares, }
}

///|
pub extend RpcClientConf with Debug::{to_repr}

///|
pub extend RpcClientConf with Eq::{not_equal, equal}

///|
/// Load an `RpcClientConf` from a JSON config string, filling omitted fields from
/// the `new()` defaults.
pub fn RpcClientConf::from_json(src : String) -> RpcClientConf raise Refused {
  rpc_client_conf_of(Conf::of_json(src))
}

///|
/// Load an `RpcClientConf` from a YAML config string.
pub fn RpcClientConf::from_yaml(src : String) -> RpcClientConf raise Refused {
  rpc_client_conf_of(Conf::of_yaml(src))
}

///|
/// Decode an `RpcClientConf` from a loaded document.
fn rpc_client_conf_of(c : Conf) -> RpcClientConf raise Refused {
  let def = RpcClientConf::new()
  {
    target: c.string("Target", default=def.target),
    endpoints: c.strings("Endpoints", default=def.endpoints),
    timeout_ms: c.int("Timeout", default=def.timeout_ms, also=["TimeoutMs"]),
    non_block: c.bool("NonBlock", default=def.non_block),
    middlewares: {
      trace: c.bool("Middlewares.Trace", default=true),
      log: c.bool("Middlewares.Log", default=true),
      prometheus: c.bool("Middlewares.Prometheus", default=true),
      breaker: c.bool("Middlewares.Breaker", default=true),
      timeout: c.bool("Middlewares.Timeout", default=true),
    },
  }
}
