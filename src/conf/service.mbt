///|
/// Service configuration (← go-zero's `ServiceConf`): the service name, its bind
/// address, a request timeout, and the log level. `timeout_ms` is the per-request
/// budget in milliseconds; `0` disables the deadline.
pub(all) struct ServiceConf {
  name : String
  host : String
  port : Int32
  timeout_ms : Int32
  log_level : @logx.LogLevel
} derive(FromJson, Eq)

///|
/// Build a config with sensible defaults (`0.0.0.0:12000`, 3s timeout, `info`).
pub fn ServiceConf::new(
  name~ : String = "app",
  host~ : String = "0.0.0.0",
  port~ : Int32 = port,
  timeout_ms~ : Int32 = 3000,
  log_level~ : @logx.LogLevel = Info,
) -> ServiceConf {
  { name, host, port, timeout_ms, log_level, }
}

///|
pub extend ServiceConf with Eq::{not_equal, equal}

///|
/// The default port a moonzero service listens on.
///
/// 12000 is the family's number, not go-zero's 8888: every example, every
/// document and every local run in this ecosystem points at the same place, and
/// on a development machine 8888 is somebody else's already.
pub let port : Int32 = 12000

///|
/// The default port the zRPC server listens on.
///
/// gRPC shares 12000 with HTTP wherever one listener carries both, but a
/// moonzero process binds `RestEngine` and `RpcServer` separately — two
/// listeners cannot hold one port — so the second takes the next number.
pub let rpc_port : Int32 = 12001
