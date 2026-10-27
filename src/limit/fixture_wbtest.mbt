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
test "a go-zero etc/*.yaml loads instead of silently defaulting" {
  let conf = @conf.ServiceConf::from_yaml(gozero_yaml())
  assert_eq(conf.name, "greet-api")
  assert_eq(conf.host, "127.0.0.1")
  assert_eq(conf.port, 9000)
  assert_eq(conf.timeout_ms, 5000)
  assert_eq(conf.log_level, Error)
}

///|
test "dotted paths reach into nested mappings" {
  let c = @conf.Conf::of_yaml(gozero_yaml())
  assert_eq(c.string("Log.Level"), "error")
  assert_eq(c.string("log.level"), "error")
  assert_eq(c.bool("Middlewares.Prometheus"), false)
  assert_eq(c.at("Log.Missing"), None)
  // walking into a scalar is a miss, not a crash
  assert_eq(c.at("Name.Level"), None)
}

///|
test "string lists load from a sequence, from a comma-separated env, or default" {
  let c = @conf.Conf::of_yaml(gozero_yaml())
  assert_eq(c.strings("TraceIgnorePaths"), ["/healthz", "/metrics"])
  assert_eq(c.strings("Missing", default=[]), [])
  @env.set_env_var("MOONZERO_IGNORE", "/a, /b ,,/c")
  defer @env.unset_env_var("MOONZERO_IGNORE")
  assert_eq(c.strings("TraceIgnorePaths", env="MOONZERO_IGNORE"), [
    "/a", "/b", "/c",
  ])
}

///|
test "a list of mappings reads back through the same accessors" {
  let c = @conf.Conf::of_yaml(gozero_yaml())
  let keys = c.list("Signature.PrivateKeys")
  assert_eq(keys.length(), 1)
  assert_eq(keys[0].string("Fingerprint"), "qwe")
  assert_eq(keys[0].string("KeyFile"), "/etc/keys/qwe.pem")
  assert_eq(c.list("Signature.Missing").length(), 0)
}

///|
test "a go-zero rest yaml loads every RestConf field" {
  let conf = @conf.RestConf::from_yaml(gozero_yaml())
  assert_eq(conf.service.name, "greet-api")
  assert_eq(conf.host(), "127.0.0.1")
  assert_eq(conf.port(), 9000)
  assert_eq(conf.timeout_ms(), 5000)
  assert_eq(conf.max_conns, 500)
  assert_eq(conf.max_bytes, 2048)
  assert_eq(conf.cpu_threshold, 800L)
  assert_eq(conf.verbose, true)
  assert_eq(conf.cert_file, "/etc/tls/server.crt")
  assert_eq(conf.key_file, "/etc/tls/server.key")
  assert_eq(conf.tls(), true)
  assert_eq(conf.trace_ignore_paths, ["/healthz", "/metrics"])
  assert_eq(conf.signature.strict, false)
  assert_eq(conf.signature.expiry_ms, 1800000L)
  assert_eq(conf.signature.private_keys.length(), 1)
  assert_eq(conf.signature.private_keys[0].fingerprint, "qwe")
  // the two flags the file turns off, and the nine it says nothing about
  assert_eq(conf.middlewares.prometheus, false)
  assert_eq(conf.middlewares.gunzip, false)
  assert_eq(conf.middlewares.trace, true)
  assert_eq(conf.middlewares.max_bytes, true)
}
