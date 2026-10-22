///|
/// Both registries expose a `Resolve` closure, so a `LoadBalancedChannel` drives
/// either backing store. Here the in-memory registry backs the channel end to end —
/// resolve, balance, dial, call — the same path the persisted registry drives below.
test "load-balanced channel works over the in-memory registry too" {
  let reg = InMemoryRegistry::new()
  let cluster = RpcCluster::new()
  let ep = Endpoint::new("10.0.0.7", 8100)
  let srv = @zrpc.RpcServer::new(@conf.RpcServerConf::new())
  srv.group("hello.Greeter").register("Who", _req => @utf8.encode("mem"))
  cluster.add(ep, srv)
  let _ = reg.register("hello.Greeter", ep)
  let ch = LoadBalancedChannel::new(reg.resolver(), cluster, "hello.Greeter")
  match ch.call("/hello.Greeter/Who", b"") {
    Ok(v) => assert_eq(v, @utf8.encode("mem"))
    Err(s) => fail("call failed: " + s.name())
  }
}

///|
/// A watcher that subscribes late replays missed changes with `events_since`, then
/// switches to live callbacks — etcd's start-revision catch-up.
test "persistent registry events_since replays only newer changes" {
  let reg = PersistentRegistry::new()
  let _ = reg.register("svc", Endpoint::new("a", 1))
  let mark = reg.revision()
  let _ = reg.register("svc", Endpoint::new("b", 2))
  let _ = reg.register("svc", Endpoint::new("c", 3))
  let missed = reg.events_since(mark)
  assert_eq(missed.length(), 2)
  assert_eq(missed[0].revision(), 2L)
  assert_eq(missed[1].revision(), 3L)
  // nothing is newer than the current revision
  assert_eq(reg.events_since(reg.revision()).length(), 0)
}

///|
/// The load-balanced client end to end: two greeter instances register in a
/// persisted registry, both bound in the cluster, and a round-robin channel
/// resolves and dials a live instance per call — each answering with its own
/// address so the alternation is observable. This is the registry-resolve→call
/// milestone, driven all the way through the real h2c transport.
test "load-balanced channel resolves and round-robins across instances" {
  let reg = PersistentRegistry::new()
  let cluster = RpcCluster::new()
  let a = Endpoint::new("10.0.0.1", 9001)
  let b = Endpoint::new("10.0.0.2", 9002)
  for pair in [(a, "instance-a"), (b, "instance-b")] {
    let (ep, tag) = pair
    let srv = @zrpc.RpcServer::new(@conf.RpcServerConf::new())
    let marker = @utf8.encode(tag)
    srv.group("hello.Greeter").register("Who", _req => marker)
    cluster.add(ep, srv)
    let _ = reg.register("hello.Greeter", ep)
  }
  let ch = LoadBalancedChannel::new(reg.resolver(), cluster, "hello.Greeter")
  let r1 = match ch.call("/hello.Greeter/Who", b"") {
    Ok(v) => v
    Err(s) => fail("call 1 failed: " + s.name())
  }
  let r2 = match ch.call("/hello.Greeter/Who", b"") {
    Ok(v) => v
    Err(s) => fail("call 2 failed: " + s.name())
  }
  // round-robin hits the two instances in turn
  assert_eq(r1, @utf8.encode("instance-a"))
  assert_eq(r2, @utf8.encode("instance-b"))
  // a third call wraps back to the first
  match ch.call("/hello.Greeter/Who", b"") {
    Ok(v) => assert_eq(v, @utf8.encode("instance-a"))
    Err(s) => fail("call 3 failed: " + s.name())
  }
}

///|
/// A load-balanced call to a service with no registered instance fails
/// `Unavailable`, the status a real client reports when no subchannel is ready.
test "load-balanced channel with no instances is Unavailable" {
  let reg = PersistentRegistry::new()
  let cluster = RpcCluster::new()
  let ch = LoadBalancedChannel::new(reg.resolver(), cluster, "absent.Service")
  match ch.call("/absent.Service/Method", b"") {
    Ok(_) => fail("no instance should not return OK")
    Err(s) => assert_eq(s == @moonrpc.Status::Unavailable, true)
  }
}

///|
/// The load-balanced client also carries server-streaming calls: it resolves an
/// instance, then streams every framed reply back.
test "load-balanced channel carries a server-streaming call" {
  let reg = PersistentRegistry::new()
  let cluster = RpcCluster::new()
  let ep = Endpoint::new("10.0.0.1", 9001)
  let srv = @zrpc.RpcServer::new(@conf.RpcServerConf::new())
  srv
  .group("feed.Feed")
  .register_server_streaming("Tail", _req => [b"x1", b"x2"])
  cluster.add(ep, srv)
  let _ = reg.register("feed.Feed", ep)
  let ch = LoadBalancedChannel::new(
    reg.resolver(),
    cluster,
    "feed.Feed",
    balancer=PickFirst,
  )
  match ch.call_server_streaming("/feed.Feed/Tail", b"") {
    Ok(msgs) => {
      assert_eq(msgs.length(), 2)
      assert_eq(msgs[0], b"x1")
      assert_eq(msgs[1], b"x2")
    }
    Err(s) => fail("stream failed: " + s.name())
  }
}
