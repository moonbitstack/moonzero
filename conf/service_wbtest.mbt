///|
test "default config" {
  let conf = ServiceConf::new()
  assert_eq(conf.name, "app")
  assert_eq(conf.host, "0.0.0.0")
  assert_eq(conf.port, 12000)
  assert_eq(conf.timeout_ms, 3000)
  assert_eq(conf.log_level, Info)
}
