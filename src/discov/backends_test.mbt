// One path through the framework against each real service: an instance holds its registration,
// a client's view follows it, and a load-balanced call reaches it. Each client's own repository
// tests the client; this tests that moonzero is wired to them.

///|
async fn calls_through(
  registry : &@moonzero.Registrar,
  discovery : &@moonzero.Discovery,
) -> Unit {
  let service = "moonzero-ci-\{@env.now()}"
  let endpoint = @moonzero.Endpoint::new("127.0.0.1", 12000)
  let server = @moonzero.RpcServer::new(@moonzero.RpcServerConf::new())
  server.group("hello.Greeter").register("Who", _ => b"here")
  let cluster = @moonzero.RpcCluster::new()
  cluster.add(endpoint, server)
  let view = @moonzero.View::new()
  let channel = @moonzero.LoadBalancedChannel::new(
    _ => view.endpoints(),
    cluster,
    service,
  )
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      @moonzero.hold(registry, service, endpoint, ttl=30_000)
    })
    group.spawn_bg(no_wait=true, () => view.follow(discovery, service))
    for _ in 0..<200 {
      if !view.endpoints().is_empty() {
        break
      }
      @async.sleep(50)
    }
    match channel.call("/hello.Greeter/Who", b"") {
      Ok(reply) => assert_eq(reply, b"here")
      Err(status) => fail("the call failed: " + status.name())
    }
  })
}

///|
async test "a call finds its instance through redis" {
  guard @env.get_env_var("MOON_REDIS_TEST") is Some(_) else { return }
  let host = @env.get_env_var("MOON_REDIS_HOST").unwrap_or("127.0.0.1")
  let options = { ..@moonredis.client_default, host, }
  let client = @moonredis.Client::new(@socket.Connection::connect(options))
  let registry = @redis_sd.Registry::new(client)
  calls_through(registry, registry)
}

///|
async test "a call finds its instance through etcd" {
  guard @env.get_env_var("MOON_ETCD_TEST") is Some(_) else { return }
  let host = @env.get_env_var("MOON_ETCD_HOST").unwrap_or("127.0.0.1")
  let client = @client.Client::connect({
    ..@moonetcd.default_client_config,
    endpoints: ["\{host}:2379"],
  })
  defer client.close()
  let registry = @etcd_sd.Registry::new(client)
  calls_through(registry, registry)
}

///|
async test "a call finds its instance through consul" {
  guard @env.get_env_var("MOON_CONSUL_TEST") is Some(_) else { return }
  let registry = @consul_sd.Registry::new(@fetch.connect())
  calls_through(registry, registry)
}
