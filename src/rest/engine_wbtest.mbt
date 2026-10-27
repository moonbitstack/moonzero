///|
/// A go-zero `etc/*.yaml` as `goctl` writes one: every key PascalCase, the log
/// level nested under `Log`, middleware flags under `Middlewares`.
fn gozero_yaml() -> String {
  (
    #|Name: greet-api
    #|Host: 127.0.0.1
    #|Port: 9000
    #|Timeout: 5000
    #|MaxConns: 500
    #|MaxBytes: 2048
    #|CpuThreshold: 800
    #|Verbose: true
    #|CertFile: /etc/tls/server.crt
    #|KeyFile: /etc/tls/server.key
    #|TraceIgnorePaths:
    #|  - /healthz
    #|  - /metrics
    #|Log:
    #|  Level: error
    #|  Mode: console
    #|Middlewares:
    #|  Prometheus: false
    #|  Gunzip: false
    #|Signature:
    #|  Strict: false
    #|  Expiry: 1800000
    #|  PrivateKeys:
    #|    - Fingerprint: qwe
    #|      KeyFile: /etc/keys/qwe.pem
  )
}

///|
/// An engine over `conf`, on a manual clock and a logger nobody reads, so a test
/// never touches the process logger.
fn test_engine(conf : @conf.RestConf) -> RestEngine raise @conf.ConfigError {
  let clock = @clock.ManualClock::new().as_clock()
  RestEngine::new(
    conf,
    clock~,
    logger=@logx.Logger::new(clock, sink=@moonlog.Discard::{ }),
  )
}

///|
/// The whole chain, in go-zero's order.
fn full_chain() -> Array[String] {
  [
    "trace", "log", "prometheus", "maxConns", "breaker", "shedding", "timeout", "recover",
    "maxBytes",
  ]
}

///|
test "the chain installs exactly what the flags ask for" {
  let conf = @conf.RestConf::from_yaml("Name: api\nPort: 8888\n")
  assert_eq(test_engine(conf).names(), full_chain())

  // each flag drops exactly its own layer
  let off : Array[(@conf.MiddlewaresConf, String)] = [
    (@conf.MiddlewaresConf::new(trace=false), "trace"),
    (@conf.MiddlewaresConf::new(log=false), "log"),
    (@conf.MiddlewaresConf::new(prometheus=false), "prometheus"),
    (@conf.MiddlewaresConf::new(max_conns=false), "maxConns"),
    (@conf.MiddlewaresConf::new(breaker=false), "breaker"),
    (@conf.MiddlewaresConf::new(shedding=false), "shedding"),
    (@conf.MiddlewaresConf::new(timeout=false), "timeout"),
    (@conf.MiddlewaresConf::new(recover=false), "recover"),
    (@conf.MiddlewaresConf::new(max_bytes=false), "maxBytes"),
  ]
  for pair in off {
    let names = test_engine(@conf.RestConf::new(middlewares=pair.0)).names()
    let want = full_chain().filter(n => n != pair.1)
    assert_eq(names, want)
  }
}

///|
test "the two flags with nothing behind them install nothing either way" {
  // Metrics is go-zero's internal stat sink and Gunzip needs a DEFLATE decoder;
  // moonzero has neither, so both flags load and change no layer
  let on = test_engine(@conf.RestConf::new()).names()
  let off = test_engine(
    @conf.RestConf::new(
      middlewares=@conf.MiddlewaresConf::new(metrics=false, gunzip=false),
    ),
  ).names()
  assert_eq(on, full_chain())
  assert_eq(off, full_chain())
}

///|
test "a layer whose setting disables it is left out even with its flag on" {
  let conf = @conf.RestConf::new(
    max_conns=0,
    max_bytes=0,
    cpu_threshold=0L,
    service=@conf.ServiceConf::new(timeout_ms=0),
  )
  assert_eq(test_engine(conf).names(), [
    "trace", "log", "prometheus", "breaker", "recover",
  ])
}

///|
test "the chain the engine builds is the chain it names" {
  let conf = @conf.RestConf::from_yaml(gozero_yaml())
  let engine = test_engine(conf)
  // the file turns Prometheus off
  assert_eq(engine.names(), [
    "trace", "log", "maxConns", "breaker", "shedding", "timeout", "recover", "maxBytes",
  ])
  let app = @moonapi.App::new()
  app.get("/ping", _ctx => @moonapi.text(200, "pong"))
  let server = engine.build(app)
  assert_eq(server.describe(), "greet-api listening on 127.0.0.1:9000")
  let _ = server.to_asgi()
}

///|
test "a strict signature with no keys is refused" {
  let strict = @conf.RestConf::new(
    signature=@conf.SignatureConf::new(strict=true),
  )
  try {
    let _ = test_engine(strict)
  } catch {
    ConfigError(msg) =>
      assert_eq(msg, "signature is strict but no private keys are configured")
  } noraise {
    _ =>
      fail("go-zero refuses a strict signature config with nothing to verify")
  }
  // with a key it assembles
  let keyed = @conf.RestConf::new(
    signature=@conf.SignatureConf::new(strict=true, private_keys=[
      { fingerprint: "qwe", key_file: "/k.pem", },
    ]),
  )
  assert_eq(test_engine(keyed).names(), full_chain())
}

///|
test "the engine points the logger at the configured level" {
  let clock = @clock.ManualClock::new().as_clock()
  let logger = @logx.Logger::new(clock, sink=@moonlog.Discard::{ })
  let conf = @conf.RestConf::from_yaml(gozero_yaml())
  let _ = RestEngine::new(conf, clock~, logger~)
  assert_eq(logger.level(), Error)
}
