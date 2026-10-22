///|
test "an rpc config loads go-zero's key spelling as readily as moonzero's" {
  let gozero = RpcServerConf::from_yaml(
    "Name: greeter\nHost: 10.0.0.1\nPort: 9001\nTimeout: 1200\n",
  )
  assert_eq(gozero.name, "greeter")
  assert_eq(gozero.host, "10.0.0.1")
  assert_eq(gozero.port, 9001)
  assert_eq(gozero.timeout_ms, 1200)
  let flat = RpcServerConf::from_json(
    "{\"name\":\"greeter\",\"timeout_ms\":1200}",
  )
  assert_eq(flat.timeout_ms, 1200)
  assert_eq(flat.port, 12001)
}
