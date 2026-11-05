///|
/// One layer of the assembled chain: go-zero's name for the handler, and the
/// middleware that stands in for it.
pub(all) struct Layer {
  name : String
  middleware : @handler.Middleware
}

///|
/// The engine that turns a `RestConf` into a runnable service. It owns the state
/// the built-in layers need — the connection permits, the breaker window, the
/// metric set, the two shedders — so every request shares one of each, and it
/// installs exactly the layers `Middlewares` asks for.
pub struct RestEngine {
  conf : @conf.RestConf
  clock : @clock.Clock
  logger : @logx.Logger
  metrics : @handler.ServerMetrics
  conns : @limit.MaxConns
  circuit : @breaker.Breaker
  shedder : @shedder.Shedder
  priority_shedder : @shedder.Shedder
  tracer : @trace.Tracer
  recorder : @trace.Recorder
  signature : @handler.SignatureVerifier?
}

///|
/// Build the engine for `conf`, pointing the logger at the configured level.
///
/// `usage` is the CPU meter the shedder reads, per mille; `tracer` decides where
/// spans go (the default keeps them in an in-process recorder the engine owns);
/// `signature` is the verifier the content-security layer checks against.
///
/// Raises `Refused` for a strict signature config with no keys, and for a metric
/// registry that will not register its families.
pub fn RestEngine::new(
  conf : @conf.RestConf,
  clock~ : @clock.Clock = @clock.Clock::system(),
  logger? : @logx.Logger,
  metrics? : @handler.ServerMetrics,
  usage? : () -> Int64,
  tracer? : @trace.Tracer,
  signature? : @handler.SignatureVerifier,
) -> RestEngine raise @conf.Refused {
  if conf.signature.strict && conf.signature.private_keys.length() == 0 {
    raise @conf.Refused(
      "signature is strict but no private keys are configured",
    )
  }
  let logger = logger.unwrap_or(@logx.logx)
  logger.set_level(conf.service.log_level)
  let metrics = match metrics {
    Some(metrics) => metrics
    None =>
      @handler.ServerMetrics::new() catch {
        _ =>
          raise @conf.Refused(
            "metric registry refused: the metric or label names are not valid",
          )
      }
  }
  let recorder = @trace.Recorder::new()
  let tracer = tracer.unwrap_or(@handler.tracer(sink=recorder))
  let priority_threshold = (conf.cpu_threshold + 1000L) >> 1
  {
    conf,
    clock,
    logger,
    metrics,
    conns: @limit.MaxConns::new(conf.max_conns),
    circuit: @breaker.Breaker::new(clock),
    shedder: @shedder.Shedder::new(clock, threshold=conf.cpu_threshold, usage?),
    priority_shedder: @shedder.Shedder::new(
      clock,
      threshold=priority_threshold,
      usage?,
    ),
    tracer,
    recorder,
    signature,
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
pub fn RestEngine::metrics(self : RestEngine) -> @handler.ServerMetrics {
  self.metrics
}

///|
/// The shedder ordinary routes draw on.
pub fn RestEngine::shedder(self : RestEngine) -> @shedder.Shedder {
  self.shedder
}

///|
/// The shedder a route opts into with `RouteOptions::priority`: it sheds at half
/// the distance to saturation, so a busy service sacrifices ordinary traffic
/// before these calls.
pub fn RestEngine::priority_shedder(self : RestEngine) -> @shedder.Shedder {
  self.priority_shedder
}

///|
/// The tracer the `trace` layer runs on.
pub fn RestEngine::tracer(self : RestEngine) -> @trace.Tracer {
  self.tracer
}

///|
/// The spans the engine's default tracer has finished, oldest first. A read-out
/// for tests and for a service that ships spans somewhere of its own.
pub fn RestEngine::spans(self : RestEngine) -> Array[@trace.SpanData] {
  self.recorder.spans()
}

///|
/// The chain the flags ask for, outermost first, in the order the reference
/// implementation builds it: trace, log, prometheus, max conns, breaker, shedding,
/// timeout, recover, max bytes, gunzip — with the content-security layer ahead of
/// all of them when a verifier is configured, because it must see the body before
/// anything else reads it.
///
/// A layer whose configured value disables it is left out even when its flag is
/// on: no shedder without a `CpuThreshold`, no timeout without a budget, no body
/// cap without a `MaxBytes`.
///
/// go-zero's `Metrics` flag is its internal `stat.Metrics` sink, which records the
/// same numbers the Prometheus families do here; it loads and installs nothing.
pub fn RestEngine::layers(self : RestEngine) -> Array[Layer] {
  let mw = self.conf.middlewares
  let out : Array[Layer] = []
  match self.signature {
    Some(verifier) =>
      out.push({
        name: "signature",
        middleware: @handler.content_security(verifier, self.clock),
      })
    None => ()
  }
  if mw.trace {
    out.push({
      name: "trace",
      middleware: @handler.tracing(
        tracer=self.tracer,
        ignore_paths=self.conf.trace_ignore_paths,
      ),
    })
  }
  if mw.log {
    let logger = self.logger
    let verbose = self.conf.verbose
    out.push({
      name: "log",
      middleware: @handler.structured_logging(self.clock, logger~, verbose~),
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
  if mw.gunzip {
    out.push({ name: "gunzip", middleware: @handler.gunzip(), })
  }
  out
}

///|
/// The names of the layers `layers` would install, outermost first.
pub fn RestEngine::names(self : RestEngine) -> Array[String] {
  self.layers().map(l => l.name)
}

///|
/// Assemble `app` under the configured chain. The outermost layer is named first
/// while `Server::use_` makes the most recent layer outermost, so the list goes on
/// back to front.
pub fn RestEngine::build(self : RestEngine, app : @moonapi.App) -> Server {
  let layers = self.layers()
  let mut server = Server::new(self.conf.service, app)
  for i = layers.length() - 1; i >= 0; i = i - 1 {
    server = server.use_(layers[i].middleware)
  }
  server
}
