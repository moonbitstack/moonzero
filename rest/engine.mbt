///|
/// One layer of the assembled chain: go-zero's name for the handler, and the
/// middleware that stands in for it.
pub(all) struct Layer {
  name : String
  middleware : @handler.Middleware
}

///|
/// The engine that turns a `RestConf` into a runnable service (← go-zero's
/// `rest.engine`). It owns the state the built-in layers need — the connection
/// permits, the breaker window, the metric set, the shedder — so every request
/// shares one of each, and it installs exactly the layers `Middlewares` asks for.
pub struct RestEngine {
  conf : @conf.RestConf
  clock : @clock.Clock
  logger : @logx.Logger
  metrics : @metric.ServerMetrics
  conns : @limit.MaxConns
  circuit : @breaker.Breaker
  shedder : @shedder.Shedder
}

///|
/// Build the engine for `conf`, pointing the logger at the configured level (←
/// `ServiceConf.SetUp`'s `logx.SetUp`).
///
/// `usage` is the CPU meter the shedder reads, per mille. Raises `ConfigError`
/// for a strict signature config with no keys, which is go-zero's
/// `ErrSignatureConfig`.
pub fn RestEngine::new(
  conf : @conf.RestConf,
  clock~ : @clock.Clock = @clock.Clock::system(),
  logger? : @logx.Logger,
  metrics~ : @metric.ServerMetrics = @metric.ServerMetrics::new(),
  usage? : () -> Int64,
) -> RestEngine raise @conf.ConfigError {
  if conf.signature.strict && conf.signature.private_keys.length() == 0 {
    raise @conf.ConfigError(
      "signature is strict but no private keys are configured",
    )
  }
  let logger = logger.unwrap_or(@logx.logx)
  logger.set_level(conf.service.log_level)
  {
    conf,
    clock,
    logger,
    metrics,
    conns: @limit.MaxConns::new(conf.max_conns),
    circuit: @breaker.Breaker::new(clock),
    shedder: @shedder.Shedder::new(conf.cpu_threshold, usage?),
  }
}

///|
/// The config the engine was built from.
pub fn RestEngine::conf(self : RestEngine) -> @conf.RestConf {
  self.conf
}

///|
/// The metric set the `prometheus` layer records into — the same one
/// `mount_metrics` publishes.
pub fn RestEngine::metrics(self : RestEngine) -> @metric.ServerMetrics {
  self.metrics
}

///|
/// The chain the flags ask for, outermost first, in go-zero's
/// `buildChainWithNativeMiddlewares` order.
///
/// A layer whose configured value disables it is left out even when its flag is
/// on, as in go-zero: no shedder without a `CpuThreshold`, no timeout without a
/// budget, no body cap without a `MaxBytes`.
///
/// Two of go-zero's eleven flags install nothing here. `Metrics` is go-zero's
/// internal `stat.Metrics` sink, which moonzero has no counterpart for — its one
/// metric set is the Prometheus one the `Prometheus` flag installs. `Gunzip`
/// needs a DEFLATE decoder, which neither moonzero nor any dependency carries.
/// Both flags still load, so a go-zero config round-trips through `RestConf`.
pub fn RestEngine::layers(self : RestEngine) -> Array[Layer] {
  let mw = self.conf.middlewares
  let out : Array[Layer] = []
  if mw.trace {
    out.push({
      name: "trace",
      middleware: @handler.tracing(ignore_paths=self.conf.trace_ignore_paths),
    })
  }
  if mw.log {
    out.push({
      name: "log",
      middleware: @handler.structured_logging(self.clock, logger=self.logger),
    })
  }
  if mw.prometheus {
    out.push({
      name: "prometheus",
      middleware: @handler.metrics(self.metrics, self.clock),
    })
  }
  if mw.max_conns && self.conf.max_conns > 0 {
    out.push({ name: "maxConns", middleware: @handler.max_conns(self.conns), })
  }
  if mw.breaker {
    out.push({ name: "breaker", middleware: @handler.breaker(self.circuit), })
  }
  if mw.shedding && self.conf.cpu_threshold > 0L {
    out.push({ name: "shedding", middleware: @handler.shedding(self.shedder), })
  }
  if mw.timeout && self.conf.service.timeout_ms > 0 {
    out.push({
      name: "timeout",
      middleware: @handler.timeout(
        self.conf.service.timeout_ms.to_int64(),
        self.clock,
      ),
    })
  }
  if mw.recover {
    out.push({ name: "recover", middleware: inner => @handler.recovery(inner), })
  }
  if mw.max_bytes && self.conf.max_bytes > 0 {
    out.push({
      name: "maxBytes",
      middleware: @handler.maxbytes(self.conf.max_bytes),
    })
  }
  out
}

///|
/// The names of the layers `layers` would install, outermost first.
pub fn RestEngine::names(self : RestEngine) -> Array[String] {
  self.layers().map(l => l.name)
}

///|
/// Assemble `app` under the configured chain. go-zero's `chain.New` names the
/// outermost handler first while `Server::use_` makes the most recent layer
/// outermost, so the list goes on back to front.
pub fn RestEngine::build(self : RestEngine, app : @moonapi.App) -> Server {
  let layers = self.layers()
  let mut server = Server::new(self.conf.service, app)
  for i = layers.length() - 1; i >= 0; i = i - 1 {
    server = server.use_(layers[i].middleware)
  }
  server
}
