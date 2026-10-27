///|
test "moonzero's own flat keys still load" {
  let conf = ServiceConf::from_yaml(
    (
      #|name: greet
      #|host: 10.0.0.1
      #|port: 9100
      #|timeout_ms: 1500
      #|log_level: debug
    ),
  )
  assert_eq(conf.name, "greet")
  assert_eq(conf.host, "10.0.0.1")
  assert_eq(conf.port, 9100)
  assert_eq(conf.timeout_ms, 1500)
  assert_eq(conf.log_level, Debug)
}

///|
test "rpc server config loads from JSON and YAML" {
  let from_json = RpcServerConf::from_json(
    "{\"name\":\"rpc-svc\",\"port\":9443,\"timeout_ms\":5000}",
  )
  assert_eq(from_json.name, "rpc-svc")
  assert_eq(from_json.port, 9443)
  assert_eq(from_json.timeout_ms, 5000)
  // host omitted -> default
  assert_eq(from_json.host, "0.0.0.0")
  let yaml =
    #|name: rpc-svc
    #|port: 9443
    #|timeout_ms: 5000
  assert_eq(RpcServerConf::from_yaml(yaml) == from_json, true)
}
