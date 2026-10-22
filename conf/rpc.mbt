///|
/// zRPC server configuration (← go-zero's `zrpc.RpcServerConf`): the service
/// name, the address it listens on, and a per-call timeout in milliseconds
/// (`0` disables it). The registry/etcd fields of go-zero's conf are modelled by
/// the separate discovery layer; this is the transport-facing core.
pub(all) struct RpcServerConf {
  name : String
  host : String
  port : Int32
  timeout_ms : Int32
} derive(FromJson, Eq, Debug)

///|
/// Build an RPC server config with go-zero-style defaults (`0.0.0.0:8080`, 2s
/// timeout).
pub fn RpcServerConf::new(
  name~ : String = "rpc",
  host~ : String = "0.0.0.0",
  port~ : Int32 = rpc_port,
  timeout_ms~ : Int32 = 2000,
) -> RpcServerConf {
  { name, host, port, timeout_ms, }
}

///|
/// Load an `RpcServerConf` from a JSON config string, filling omitted fields
/// from the `new()` defaults — the lenient loader matching go-zero's
/// `,optional`/`,default=` config tags. Keys are matched canonically, so
/// go-zero's `Name`/`Host`/`Port`/`Timeout` load as readily as moonzero's own
/// `timeout_ms`.
pub fn RpcServerConf::from_json(
  src : String,
) -> RpcServerConf raise ConfigError {
  rpc_conf_of(Conf::of_json(src))
}

///|
/// Load an `RpcServerConf` from a YAML config string (self-built `yaml_parse`),
/// with the same default-filling semantics as `from_json`.
pub fn RpcServerConf::from_yaml(
  src : String,
) -> RpcServerConf raise ConfigError {
  rpc_conf_of(Conf::of_yaml(src))
}

///|
/// Decode an `RpcServerConf` from a loaded document, filling omitted fields from
/// `RpcServerConf::new()`. Shared by the JSON and YAML loaders.
fn rpc_conf_of(c : Conf) -> RpcServerConf raise ConfigError {
  let def = RpcServerConf::new()
  {
    name: c.string("Name", default=def.name),
    host: c.string("Host", default=def.host),
    port: c.int("Port", default=def.port),
    timeout_ms: c.int("Timeout", default=def.timeout_ms, also=["TimeoutMs"]),
  }
}

///|
pub extend RpcServerConf with Debug::{to_repr}

///|
pub extend RpcServerConf with Eq::{not_equal, equal}
