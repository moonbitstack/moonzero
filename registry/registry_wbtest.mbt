///|
/// The addresses `lb` hands out over `n` picks.
fn weighted_run(
  lb : WeightedRoundRobin,
  eps : Array[Endpoint],
  n : Int32,
) -> Array[String] {
  let out : Array[String] = []
  for _ in 0..<n {
    out.push(lb.pick(eps).unwrap().address())
  }
  out
}

///|
test "persistent registry registers, resolves, and bumps the revision" {
  let reg = PersistentRegistry::new()
  assert_eq(reg.revision(), 0L)
  let k1 = reg.register("greeter", Endpoint::new("10.0.0.1", 9001))
  let _ = reg.register("greeter", Endpoint::new("10.0.0.2", 9002))
  assert_eq(k1, "greeter/1")
  assert_eq(reg.resolve("greeter").length(), 2)
  assert_eq(reg.revision(), 2L)
  assert_eq(reg.services().length(), 1)
}

///|
test "persistent registry deregister removes an instance and emits a Delete" {
  let reg = PersistentRegistry::new()
  let k1 = reg.register("svc", Endpoint::new("a", 1))
  let _ = reg.register("svc", Endpoint::new("b", 2))
  assert_eq(reg.deregister("svc", k1), true)
  assert_eq(reg.resolve("svc").length(), 1)
  assert_eq(reg.resolve("svc")[0].address(), "b:2")
  // a failed deregister neither removes nor bumps the revision
  let rev = reg.revision()
  assert_eq(reg.deregister("svc", "svc/999"), false)
  assert_eq(reg.revision(), rev)
}

///|
/// A live watcher sees every mutation after it subscribes, in revision order, as
/// etcd-shaped Put/Delete events.
test "persistent registry watch delivers Put and Delete events in order" {
  let reg = PersistentRegistry::new()
  let seen : Array[RegistryEvent] = []
  reg.watch(e => seen.push(e))
  let k = reg.register("svc", Endpoint::new("a", 1))
  let _ = reg.register("svc", Endpoint::new("b", 2))
  let _ = reg.deregister("svc", k)
  assert_eq(seen.length(), 3)
  assert_eq(
    seen[0],
    Put(key="svc/1", endpoint=Endpoint::new("a", 1), revision=1L),
  )
  assert_eq(
    seen[1],
    Put(key="svc/2", endpoint=Endpoint::new("b", 2), revision=2L),
  )
  assert_eq(seen[2], Delete(key="svc/1", revision=3L))
}

///|
/// The registry serializes to an etcd v3 `RangeResponse`-shaped snapshot and
/// restores to an identical registry: same instances, same revision, and the id
/// counter continues where it left off so the next key does not collide.
test "persistent registry snapshot round-trips through restore" {
  let reg = PersistentRegistry::new()
  let _ = reg.register("greeter", Endpoint::new("10.0.0.1", 9001, weight=3))
  let _ = reg.register("greeter", Endpoint::new("10.0.0.2", 9002))
  let _ = reg.register("orders", Endpoint::new("10.0.0.9", 7000))
  let snap = reg.snapshot()
  let restored = PersistentRegistry::restore(snap)
  assert_eq(restored.revision(), reg.revision())
  assert_eq(restored.resolve("greeter").length(), 2)
  assert_eq(restored.resolve("orders").length(), 1)
  // the weight survived the round-trip
  let g = restored.resolve("greeter")
  let mut found = false
  for e in g {
    if e.address() == "10.0.0.1:9001" {
      assert_eq(e.weight, 3)
      found = true
    }
  }
  assert_eq(found, true)
  // the id counter resumes: the next key is /4, not a collision with /1
  let k = restored.register("greeter", Endpoint::new("10.0.0.3", 9003))
  assert_eq(k, "greeter/4")
}

///|
test "balancer round-robin and pick-first over a resolved set" {
  let eps = [Endpoint::new("a", 1), Endpoint::new("b", 2)]
  let rr = Balancer::round_robin()
  assert_eq(rr.pick(eps).unwrap().address(), "a:1")
  assert_eq(rr.pick(eps).unwrap().address(), "b:2")
  assert_eq(rr.pick(eps).unwrap().address(), "a:1")
  let pf : Balancer = PickFirst
  assert_eq(pf.pick(eps).unwrap().address(), "a:1")
  assert_eq(pf.pick(eps).unwrap().address(), "a:1")
  assert_eq(rr.pick([]) is None, true)
  assert_eq(pf.pick([]) is None, true)
}

///|
test "endpoint address and default weight" {
  let e = Endpoint::new("127.0.0.1", 8080)
  assert_eq(e.address(), "127.0.0.1:8080")
  assert_eq(e.weight, 1)
  let w = Endpoint::new("10.0.0.5", 9000, weight=5)
  assert_eq(w.weight, 5)
  assert_eq(w.address(), "10.0.0.5:9000")
}

///|
test "registry registers, resolves, and lists services" {
  let reg = InMemoryRegistry::new()
  assert_eq(reg.revision(), 0L)
  assert_eq(reg.resolve("greeter").length(), 0)
  let k1 = reg.register("greeter", Endpoint::new("10.0.0.1", 9001))
  let _ = reg.register("greeter", Endpoint::new("10.0.0.2", 9002))
  assert_eq(reg.resolve("greeter").length(), 2)
  assert_eq(reg.revision(), 2L)
  // distinct keys for distinct instances
  assert_eq(k1, "greeter/1")
  let services = reg.services()
  assert_eq(services.length(), 1)
  assert_eq(services[0], "greeter")
}

///|
test "registry deregister removes an instance and bumps the revision" {
  let reg = InMemoryRegistry::new()
  let k1 = reg.register("svc", Endpoint::new("a", 1))
  let _ = reg.register("svc", Endpoint::new("b", 2))
  assert_eq(reg.resolve("svc").length(), 2)
  let rev_before = reg.revision()
  assert_eq(reg.deregister("svc", k1), true)
  assert_eq(reg.resolve("svc").length(), 1)
  assert_eq(reg.revision(), rev_before + 1L)
  // the survivor is the second instance
  assert_eq(reg.resolve("svc")[0].address(), "b:2")
}

///|
test "registry deregister of an unknown key or service is a no-op" {
  let reg = InMemoryRegistry::new()
  assert_eq(reg.deregister("nope", "nope/1"), false)
  let _ = reg.register("svc", Endpoint::new("a", 1))
  let rev = reg.revision()
  assert_eq(reg.deregister("svc", "svc/999"), false)
  // a failed deregister must not bump the revision
  assert_eq(reg.revision(), rev)
}

///|
test "round-robin balancer cycles through the instances" {
  let lb = RoundRobin::new()
  let eps = [
    Endpoint::new("a", 1),
    Endpoint::new("b", 2),
    Endpoint::new("c", 3),
  ]
  assert_eq(lb.pick(eps).unwrap().address(), "a:1")
  assert_eq(lb.pick(eps).unwrap().address(), "b:2")
  assert_eq(lb.pick(eps).unwrap().address(), "c:3")
  assert_eq(lb.pick(eps).unwrap().address(), "a:1")
}

///|
test "round-robin and pick_first on an empty set return None" {
  let lb = RoundRobin::new()
  assert_eq(lb.pick([]) is None, true)
  assert_eq(pick_first([]) is None, true)
  assert_eq(pick_first([Endpoint::new("a", 1)]).unwrap().address(), "a:1")
}

///|
test "weighted balancer shares traffic in proportion to weight" {
  let lb = WeightedRoundRobin::new()
  let eps = [
    Endpoint::new("a", 1, weight=5),
    Endpoint::new("b", 2, weight=1),
    Endpoint::new("c", 3, weight=1),
  ]
  // one full cycle of 7 picks serves each instance exactly its weight, and
  // spreads the heavy one out instead of running it five times over
  assert_eq(weighted_run(lb, eps, 7), [
    "a:1", "a:1", "b:2", "a:1", "c:3", "a:1", "a:1",
  ])
  // and the cycle repeats from a clean slate
  assert_eq(weighted_run(lb, eps, 7), [
    "a:1", "a:1", "b:2", "a:1", "c:3", "a:1", "a:1",
  ])
}

///|
test "weighted balancer keeps the 3:1 split over a whole cycle" {
  let lb = WeightedRoundRobin::new()
  let eps = [Endpoint::new("big", 1, weight=3), Endpoint::new("small", 2)]
  let picks = weighted_run(lb, eps, 8)
  let mut big = 0
  for p in picks {
    if p == "big:1" {
      big = big + 1
    }
  }
  assert_eq(big, 6)
  assert_eq(picks.length() - big, 2)
}

///|
test "weighted balancer skips a non-positive weight" {
  let lb = WeightedRoundRobin::new()
  let eps = [Endpoint::new("off", 1, weight=0), Endpoint::new("on", 2)]
  assert_eq(weighted_run(lb, eps, 3), ["on:2", "on:2", "on:2"])
  // nothing eligible, and nothing at all, both yield None
  assert_eq(lb.pick([Endpoint::new("off", 1, weight=0)]) is None, true)
  assert_eq(lb.pick([]) is None, true)
}

///|
test "weighted balancer drops the credit of an instance that left" {
  let lb = WeightedRoundRobin::new()
  let small = Endpoint::new("small", 1)
  let big = Endpoint::new("big", 2, weight=3)
  assert_eq(lb.pick([small, big]).unwrap().address(), "big:2")
  // while big is away, small's credit is the only one that moves
  assert_eq(lb.pick([small]).unwrap().address(), "small:1")
  // big comes back with no stale credit, so it wins outright rather than tying
  // with small and losing the tie-break to it
  assert_eq(lb.pick([small, big]).unwrap().address(), "big:2")
}

///|
test "the weighted balancer plugs into Balancer" {
  let b = Balancer::weighted()
  let eps = [Endpoint::new("a", 1, weight=2), Endpoint::new("b", 2)]
  assert_eq(b.pick(eps).unwrap().address(), "a:1")
  assert_eq(b.pick(eps).unwrap().address(), "b:2")
  assert_eq(b.pick(eps).unwrap().address(), "a:1")
  assert_eq(b.pick([]) is None, true)
}

///|
test "resolve_one drives a Discovery through the balancer" {
  let reg = InMemoryRegistry::new()
  let _ = reg.register("greeter", Endpoint::new("10.0.0.1", 9001))
  let _ = reg.register("greeter", Endpoint::new("10.0.0.2", 9002))
  let lb = RoundRobin::new()
  assert_eq(resolve_one(reg, "greeter", lb).unwrap().address(), "10.0.0.1:9001")
  assert_eq(resolve_one(reg, "greeter", lb).unwrap().address(), "10.0.0.2:9002")
  // an unknown service yields no endpoint
  assert_eq(resolve_one(reg, "absent", lb) is None, true)
}
