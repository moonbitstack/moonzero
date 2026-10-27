// The etcd-backed discovery driver: go-zero's `discov` flow expressed over a real
// `EtcdClient`. A service registers its endpoint under a per-service key prefix, held
// alive by a lease; a client resolves the prefix with a Range to get every live
// endpoint. This is the `Resolve` the abstraction in `discovery.mbt` was left open for
// — the same balancer and load-balanced channel now run against a real etcd store.

///|
/// An etcd-backed service registry / resolver. Instances of one service live under
/// `<prefix><service>/`, so a Range over that prefix returns them all.
pub struct EtcdDiscovery {
  client : EtcdClient
  prefix : String
}

///|
/// An etcd discovery bound to `client`; keys live under `prefix` (default
/// `"moonzero/"`, mirroring go-zero's configurable discovery key root).
pub fn EtcdDiscovery::new(
  client : EtcdClient,
  prefix~ : String = "moonzero/",
) -> EtcdDiscovery {
  { client, prefix, }
}

///|
/// The key prefix a service's instances live under: `<prefix><service>/`. Exposed so
/// the native gRPC-socket path builds the exact same keys as the in-process driver.
pub fn etcd_service_prefix(prefix : String, service : String) -> String {
  prefix + service + "/"
}

///|
/// The key prefix a service's instances live under: `<prefix><service>/`.
fn EtcdDiscovery::service_prefix(
  self : EtcdDiscovery,
  service : String,
) -> String {
  etcd_service_prefix(self.prefix, service)
}

///|
/// The etcd range-end for a prefix scan: the prefix with its last byte incremented,
/// which is the smallest key greater than every key sharing the prefix (etcd's
/// `getPrefix`). An all-`0xff` tail scans to the end of the keyspace (`\x00`).
pub fn etcd_prefix_end(prefix : Bytes) -> Bytes {
  let out = Buffer()
  out.write_bytes(prefix)
  let bytes = out.to_bytes()
  let buf = Buffer()
  let mut cut = -1
  for i = bytes.length() - 1; i >= 0; i = i - 1 {
    if bytes[i].to_int() < 0xff {
      cut = i
      break
    }
  }
  if cut < 0 {
    return b"\x00"
  }
  for i = 0; i < cut; i = i + 1 {
    buf.write_byte(bytes[i])
  }
  buf.write_byte((bytes[cut].to_int() + 1).to_byte())
  buf.to_bytes()
}

///|
/// Register `endpoint` for `service` under a fresh lease living `ttl` seconds, and
/// return the granted lease id (renew it with the client's keep-alive to stay
/// registered). The instance key is `<prefix><service>/<lease-id>` and its value is
/// the `host:port` dial string, so a resolver reads the endpoints straight back.
pub fn EtcdDiscovery::register(
  self : EtcdDiscovery,
  service : String,
  endpoint : @registry.Endpoint,
  ttl~ : Int64 = 10,
) -> Int64 raise {
  let lease = self.client.lease_grant({ ttl, id: 0, })
  let key = self.service_prefix(service) + lease.id.to_string()
  let _ = self.client.put({
    key: @utf8.encode(key),
    value: @utf8.encode(endpoint.address()),
    lease: lease.id,
  })
  lease.id
}

///|
/// Remove every instance of `service` (deregister the whole service prefix).
pub fn EtcdDiscovery::deregister(
  self : EtcdDiscovery,
  service : String,
) -> Unit raise {
  let prefix = @utf8.encode(self.service_prefix(service))
  let _ = self.client.delete_range({
    key: prefix,
    range_end: etcd_prefix_end(prefix),
    prev_kv: false,
  })
}

///|
/// Resolve `service` to its live endpoints: Range the service prefix and parse each
/// value as a `host:port` endpoint. Malformed values are skipped.
pub fn EtcdDiscovery::resolve(
  self : EtcdDiscovery,
  service : String,
) -> Array[@registry.Endpoint] raise {
  let prefix = @utf8.encode(self.service_prefix(service))
  let resp = self.client.range({
    key: prefix,
    range_end: etcd_prefix_end(prefix),
    limit: 0,
  })
  let out : Array[@registry.Endpoint] = []
  for kv in resp.kvs {
    match @registry.Endpoint::parse(@utf8.decode_lossy(kv.value[:])) {
      Some(ep) => out.push(ep)
      None => ()
    }
  }
  out
}

///|
/// This etcd discovery as a `Resolve` interface value, so the balancer and the
/// load-balanced channel written against `Resolve` run against real etcd unchanged.
/// A resolve error surfaces as an empty endpoint set (the balancer's no-instance
/// case), matching how the in-memory resolver behaves for an unknown service.
pub fn EtcdDiscovery::resolver(self : EtcdDiscovery) -> @registry.Resolve {
  service => self.resolve(service) catch { _ => [] }
}
