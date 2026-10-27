///|
/// One registered service instance in the fake agent. `healthy` flips true only once
/// its TTL check has been passed, mirroring consul starting a fresh TTL check critical.
struct ConsulInstance {
  name : String
  address : String
  port : Int32
  mut healthy : Bool
}

///|
/// A fake consul agent backing register / check-pass / deregister / health / services
/// with a Map keyed by instance id — enough to exercise the discovery driver.
struct FakeConsul {
  services : Map[String, ConsulInstance]
}

///|
fn FakeConsul::new() -> FakeConsul {
  { services: Map([]), }
}

///|
impl ConsulHttp for FakeConsul with fn request(self, verb, path, body) {
  if verb == "PUT" && path == "/v1/agent/service/register" {
    let json = @json.parse(@utf8.decode_lossy(body[:])) catch {
      _ => return ConsulResponse::new(400, b"bad json")
    }
    let id = @consul.consul_str_field(json, "ID")
    self.services[id] = {
      name: @consul.consul_str_field(json, "Name"),
      address: @consul.consul_str_field(json, "Address"),
      port: @consul.consul_int_field(json, "Port"),
      healthy: false,
    }
    return ConsulResponse::new(200, b"")
  }
  if verb == "PUT" && path.strip_prefix("/v1/agent/check/pass/") is Some(check) {
    // The check id is `service:<instance-id>`.
    let id = check.strip_prefix("service:").unwrap_or(check).to_owned()
    match self.services.get(id) {
      Some(inst) => {
        inst.healthy = true
        return ConsulResponse::new(200, b"")
      }
      None => return ConsulResponse::new(404, b"unknown check")
    }
  }
  if verb == "PUT" &&
    path.strip_prefix("/v1/agent/service/deregister/") is Some(id) {
    self.services.remove(id.to_owned())
    return ConsulResponse::new(200, b"")
  }
  if verb == "GET" && path.strip_prefix("/v1/health/service/") is Some(rest) {
    let name = match rest.find("?") {
      Some(i) => rest[:i].to_owned()
      None => rest.to_owned()
    }
    let arr : Array[Json] = []
    for _id, inst in self.services {
      if inst.name == name && inst.healthy {
        let svc : Map[String, Json] = Map([
          ("Address", Json(inst.address)),
          ("Port", Json(inst.port)),
        ])
        let node : Map[String, Json] = Map([("Address", Json(inst.address))])
        arr.push(Json(Map([("Service", Json(svc)), ("Node", Json(node))])))
      }
    }
    return ConsulResponse::new(200, @utf8.encode(Json(arr).stringify()))
  }
  if verb == "GET" && path == "/v1/agent/services" {
    let obj : Map[String, Json] = Map([])
    for id, inst in self.services {
      obj[id] = Json(
        Map([
          ("ID", Json(id)),
          ("Service", Json(inst.name)),
          ("Address", Json(inst.address)),
          ("Port", Json(inst.port)),
        ]),
      )
    }
    return ConsulResponse::new(200, @utf8.encode(Json(obj).stringify()))
  }
  ConsulResponse::new(404, b"not found")
}

///|
test "consul discovery: register, pass check, resolve healthy, deregister" {
  let disc = ConsulDiscovery::new(ConsulClient::new(FakeConsul::new()))
  // register passes the TTL check, so both instances resolve as healthy.
  let _ = disc.register("greeter", Endpoint::new("10.0.0.1", 9090))
  let _ = disc.register("greeter", Endpoint::new("10.0.0.2", 9090))
  let eps = disc.resolve("greeter")
  assert_eq(eps.length(), 2)
  let addrs = eps.map(e => e.address())
  assert_eq(addrs.contains("10.0.0.1:9090"), true)
  assert_eq(addrs.contains("10.0.0.2:9090"), true)
  // An unregistered service resolves to nothing.
  assert_eq(disc.resolve("other").length(), 0)
  // A different service registered on the same agent does not bleed in.
  let _ = disc.register("greet", Endpoint::new("10.0.0.9", 7000))
  assert_eq(disc.resolve("greeter").length(), 2)
  assert_eq(disc.resolve("greet").length(), 1)
  // The Resolve interface value the balancer consumes sees the same set.
  assert_eq(disc.resolver()("greeter").length(), 2)
  // Deregister one instance, then the whole service.
  disc.deregister_instance("greeter", Endpoint::new("10.0.0.1", 9090))
  assert_eq(disc.resolve("greeter").length(), 1)
  disc.deregister("greeter")
  assert_eq(disc.resolve("greeter").length(), 0)
  // `greet` was untouched by clearing `greeter`.
  assert_eq(disc.resolve("greet").length(), 1)
}

///|
test "consul client: a critical (unpassed) instance is not resolved until its check passes" {
  let fake = FakeConsul::new()
  let client = ConsulClient::new(fake)
  // Registered but check never passed -> critical -> filtered out of the healthy set.
  client.register_service("x-1.2.3.4-5000", "x", "1.2.3.4", 5000, 10)
  assert_eq(client.health_service("x").length(), 0)
  // Passing the check makes it healthy.
  client.check_pass("x-1.2.3.4-5000")
  let eps = client.health_service("x")
  assert_eq(eps.length(), 1)
  assert_eq(eps[0].address(), "1.2.3.4:5000")
}
