///|
/// Service discovery with no service to run: moonsd's in-memory registry, a view that follows it,
/// the balancers, and a load-balanced zRPC channel that reaches two live instances. moonredis,
/// moonetcd and moonconsul each have a `Registry` that goes where the in-memory one is here.
///
///     moon run --target native src/examples/08-discovery
#coverage.skip
async fn main {
  let a = @moonzero.Endpoint::new("10.0.0.1", 9090)
  let b = @moonzero.Endpoint::new("10.0.0.2", 9090)
  let heavy = @moonzero.Endpoint::new("10.0.0.3", 9090, weight=5)

  // Register, resolve, deregister. A lease lives as long as it is renewed.
  let registry = @memory.Registry::new()
  let lease = registry.register("greeter", a, 60_000)
  ignore(registry.register("greeter", b, 60_000))
  println("registered: " + addresses(registry.resolve("greeter")))
  registry.deregister(lease)
  println("after one left: " + addresses(registry.resolve("greeter")))

  // Balancers over a fixed set.
  let set = [a, b, heavy]
  println("in turn: " + picks(@moonzero.Balancer::round_robin(), set, 4))
  println("always the first: " + picks(PickFirst, set, 2))
  println("by weight: " + picks(@moonzero.Balancer::weighted(), set, 7))

  // `follow` keeps the view current in a task of its own, and the channel reads it on every call
  // without waiting.
  let cluster = @moonzero.RpcCluster::new()
  for endpoint in [a, b] {
    let server = @moonzero.RpcServer::new(@moonzero.RpcServerConf::new())
    let name = @utf8.encode(endpoint.address())
    server.group("hello.Greeter").register("Who", _ => name)
    cluster.add(endpoint, server)
    ignore(registry.register("hello.Greeter", endpoint, 60_000))
  }
  let view = @moonzero.View::new()
  let channel = @moonzero.LoadBalancedChannel::new(
    _ => view.endpoints(),
    cluster,
    "hello.Greeter",
  )
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => view.follow(registry, "hello.Greeter"))
    while view.endpoints().is_empty() {
      @async.sleep(10)
    }
    for _ in 0..<3 {
      match channel.call("/hello.Greeter/Who", b"") {
        Ok(reply) => println("answered by " + @utf8.decode_lossy(reply[:]))
        Err(status) => println("failed: " + status.name())
      }
    }
  })
}

///|
fn addresses(endpoints : Array[@moonzero.Endpoint]) -> String {
  let all = endpoints.map(e => e.address())
  all.sort()
  all.join(", ")
}

///|
fn picks(
  balancer : @moonzero.Balancer,
  set : Array[@moonzero.Endpoint],
  count : Int32,
) -> String {
  Array::makei(count, _ => balancer.pick(set).unwrap().host).join(" ")
}
