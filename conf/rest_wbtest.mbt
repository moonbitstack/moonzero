///|
test "the same config loads from JSON" {
  let conf = RestConf::from_json(
    "{\"Name\":\"api\",\"Port\":8888,\"MaxConns\":7,\"Middlewares\":{\"Breaker\":false}}",
  )
  assert_eq(conf.service.name, "api")
  assert_eq(conf.port(), 8888)
  assert_eq(conf.max_conns, 7)
  assert_eq(conf.middlewares.breaker, false)
}

///|
test "an omitted field takes go-zero's default" {
  let conf = RestConf::from_yaml("Name: api\nPort: 8888\n")
  assert_eq(conf.host(), "0.0.0.0")
  assert_eq(conf.timeout_ms(), 3000)
  assert_eq(conf.max_conns, 10000)
  assert_eq(conf.max_bytes, 1048576)
  assert_eq(conf.cpu_threshold, 900L)
  assert_eq(conf.verbose, false)
  assert_eq(conf.tls(), false)
  assert_eq(conf.signature.expiry_ms, 3600000L)
  assert_eq(conf.middlewares, MiddlewaresConf::new())
  assert_eq(conf.trace_ignore_paths, [])
}

///|
test "a rest service must name itself and its port" {
  for src in ["Port: 8888\n", "Name: api\n"] {
    try {
      let _ = RestConf::from_yaml(src)
    } catch {
      ConfigError(msg) => assert_eq(msg.has_suffix(" is not set"), true)
    } noraise {
      _ => fail("go-zero has no default for Name or Port")
    }
  }
}

///|
test "an out-of-range RestConf value is refused" {
  try {
    let _ = RestConf::from_yaml("Name: api\nPort: 8888\nCpuThreshold: 1200\n")
  } catch {
    ConfigError(msg) =>
      assert_eq(
        msg, "value 1200 for field CpuThreshold is out of range [0:1000]",
      )
  } noraise {
    _ => fail("a threshold above 1000 must not load")
  }
  try {
    let _ = RestConf::from_yaml("Name: api\nPort: 8888\nMaxBytes: 33554433\n")
  } catch {
    ConfigError(msg) =>
      assert_eq(msg.has_suffix("out of range [0:33554432]"), true)
  } noraise {
    _ => fail("a body cap above 32 MiB must not load")
  }
}
