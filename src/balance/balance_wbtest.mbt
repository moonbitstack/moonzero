///|
fn fixed(endpoints : Array[@moonsd.Endpoint]) -> Resolve {
  _ => endpoints
}

///|
fn ep(host : String, port : Int32, weight~ : Int32 = 1) -> @moonsd.Endpoint {
  @moonsd.Endpoint::new(host, port, weight~)
}

///|
test "a balancer takes turns, stays on the first, or shares by weight" {
  let set = [ep("a", 1), ep("b", 2), ep("c", 3, weight=5)]
  let turns = Balancer::round_robin()
  assert_eq(turns.pick(set).unwrap().host, "a")
  assert_eq(turns.pick(set).unwrap().host, "b")
  assert_eq(PickFirst.pick(set).unwrap().host, "a")
  assert_eq(PickFirst.pick(set).unwrap().host, "a")
  let shares = Balancer::weighted()
  let seen = Array::makei(7, _ => shares.pick(set).unwrap().host)
  assert_eq(seen.filter(host => host == "c").length(), 5)
}

///|
test "no instances means no pick" {
  assert_true(Balancer::round_robin().pick([]) is None)
  assert_true(PickFirst.pick([]) is None)
  assert_true(Balancer::weighted().pick([]) is None)
}

///|
test "load-balanced channel resolves and round-robins across instances" {
  let cluster = RpcCluster::new()
  let a = ep("10.0.0.1", 9001)
  let b = ep("10.0.0.2", 9002)
  for pair in [(a, "instance-a"), (b, "instance-b")] {
    let (endpoint, tag) = pair
    let server = @zrpc.RpcServer::new(@conf.RpcServerConf::new())
    let marker = @utf8.encode(tag)
    server.group("hello.Greeter").register("Who", _req => marker)
    cluster.add(endpoint, server)
  }
  let channel = LoadBalancedChannel::new(
    fixed([a, b]),
    cluster,
    "hello.Greeter",
  )
  for tag in ["instance-a", "instance-b", "instance-a"] {
    match channel.call("/hello.Greeter/Who", b"") {
      Ok(reply) => assert_eq(reply, @utf8.encode(tag))
      Err(status) => fail("call failed: " + status.name())
    }
  }
}

///|
test "load-balanced channel with no instances is Unavailable" {
  let channel = LoadBalancedChannel::new(
    fixed([]),
    RpcCluster::new(),
    "absent.Service",
  )
  match channel.call("/absent.Service/Method", b"") {
    Ok(_) => fail("no instance should not return OK")
    Err(status) => assert_true(status == @moonrpc.Status::Unavailable)
  }
}

///|
test "load-balanced channel carries a server-streaming call" {
  let cluster = RpcCluster::new()
  let endpoint = ep("10.0.0.1", 9001)
  let server = @zrpc.RpcServer::new(@conf.RpcServerConf::new())
  server
  .group("feed.Feed")
  .register_server_streaming("Tail", _req => [b"x1", b"x2"])
  cluster.add(endpoint, server)
  let channel = LoadBalancedChannel::new(
    fixed([endpoint]),
    cluster,
    "feed.Feed",
    balancer=PickFirst,
  )
  match channel.call_server_streaming("/feed.Feed/Tail", b"") {
    Ok(replies) => assert_eq(replies, [b"x1", b"x2"])
    Err(status) => fail("stream failed: " + status.name())
  }
}
