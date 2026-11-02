///|
/// The instances of a service. It runs on every call, so it must answer without waiting: a program
/// passes `@moonsd.View::endpoints` here and runs `View::follow` in a task of its own.
pub type Resolve = (String) -> Array[@moonsd.Endpoint]

///|
/// How a load-balanced channel chooses: in turn, in proportion to `Endpoint::weight`, or always the
/// first (gRPC's `pick_first`). `Weighted` keeps its credit by `Endpoint::id`.
pub(all) enum Balancer {
  RoundRobin(@moonpool.RoundRobin)
  PickFirst
  Weighted(@moonpool.Weighted)
}

///|
/// Instances in turn, from the first.
pub fn Balancer::round_robin() -> Balancer {
  RoundRobin(@moonpool.RoundRobin::new())
}

///|
/// Instances by weight, with no credit yet.
pub fn Balancer::weighted() -> Balancer {
  Weighted(@moonpool.Weighted::new())
}

///|
/// One of `endpoints`, or `None` if there is nothing to choose.
pub fn Balancer::pick(
  self : Balancer,
  endpoints : Array[@moonsd.Endpoint],
) -> @moonsd.Endpoint? {
  let at = match self {
    RoundRobin(turns) => turns.pick(endpoints.length())
    PickFirst => if endpoints.is_empty() { -1 } else { 0 }
    Weighted(shares) => shares.pick(endpoints.map(e => (e.id, e.weight)))
  }
  endpoints.get(at)
}

///|
/// The in-process dial table: an endpoint address maps to the `RpcServer` listening
/// there. It stands in for DNS resolution plus a socket dial in the in-process h2c
/// transport — a real deployment opens a connection to the address instead of
/// looking the server up here, but the resolve→balance→call path above it is the
/// same.
pub struct RpcCluster {
  servers : Map[String, @zrpc.RpcServer]
}

///|
/// An empty cluster.
pub fn RpcCluster::new() -> RpcCluster {
  { servers: Map([]), }
}

///|
/// Bind the server reachable at `endpoint`'s address.
pub fn RpcCluster::add(
  self : RpcCluster,
  endpoint : @moonsd.Endpoint,
  server : @zrpc.RpcServer,
) -> Unit {
  self.servers[endpoint.address()] = server
}

///|
/// Open a channel to the server bound at `endpoint`, or `None` if nothing is
/// reachable there (a stale registry entry pointing at a gone instance).
pub fn RpcCluster::dial(
  self : RpcCluster,
  endpoint : @moonsd.Endpoint,
) -> @zrpc.RpcChannel? {
  match self.servers.get(endpoint.address()) {
    Some(server) =>
      Some(@zrpc.RpcChannel::connect(server, authority=endpoint.address()))
    None => None
  }
}

///|
/// A load-balanced zRPC client (← go-zero's `zrpc.Client` over a discovery target):
/// it resolves a service through `Resolve`, picks a live instance with the
/// `Balancer`, dials it on the `RpcCluster`, and makes the call. The whole
/// resolve→balance→dial→call path runs per call, so instances registering or
/// deregistering between calls take effect on the next one.
pub struct LoadBalancedChannel {
  resolve : Resolve
  cluster : RpcCluster
  balancer : Balancer
  service : String
}

///|
/// Build a load-balanced channel for `service` over a `Resolve` interface, dialing
/// through `cluster` with `balancer` (round-robin by default).
pub fn LoadBalancedChannel::new(
  resolve : Resolve,
  cluster : RpcCluster,
  service : String,
  balancer~ : Balancer = Balancer::round_robin(),
) -> LoadBalancedChannel {
  { resolve, cluster, balancer, service, }
}

///|
/// Resolve the service, pick a live instance, and dial it — the shared prelude of
/// every load-balanced call. `Unavailable` when the service has no instances or the
/// picked one is unreachable, matching the `grpc-status` a real client surfaces when
/// no subchannel is ready.
fn LoadBalancedChannel::pick_channel(
  self : LoadBalancedChannel,
) -> Result[@zrpc.RpcChannel, @moonrpc.Status] {
  let endpoints = (self.resolve)(self.service)
  match self.balancer.pick(endpoints) {
    None => Err(@moonrpc.Status::Unavailable)
    Some(endpoint) =>
      match self.cluster.dial(endpoint) {
        Some(channel) => Ok(channel)
        None => Err(@moonrpc.Status::Unavailable)
      }
  }
}

///|
/// Make a unary call to `path`, resolving and balancing to a live instance first.
pub fn LoadBalancedChannel::call(
  self : LoadBalancedChannel,
  path : String,
  request : Bytes,
) -> Result[Bytes, @moonrpc.Status] raise {
  match self.pick_channel() {
    Ok(channel) => channel.call(path, request)
    Err(status) => Err(status)
  }
}

///|
/// Make a server-streaming call to `path`, resolving and balancing to a live
/// instance first.
pub fn LoadBalancedChannel::call_server_streaming(
  self : LoadBalancedChannel,
  path : String,
  request : Bytes,
) -> Result[Array[Bytes], @moonrpc.Status] raise {
  match self.pick_channel() {
    Ok(channel) => channel.call_server_streaming(path, request)
    Err(status) => Err(status)
  }
}

///|
/// Make a bidirectional-streaming call to `path`, resolving and balancing to a
/// live instance first, then driving the whole `requests` exchange to completion.
pub fn LoadBalancedChannel::call_bidi_streaming(
  self : LoadBalancedChannel,
  path : String,
  requests : Array[Bytes],
) -> Result[Array[Bytes], @moonrpc.Status] raise {
  match self.pick_channel() {
    Ok(channel) => channel.call_bidi_streaming(path, requests)
    Err(status) => Err(status)
  }
}
