///|
/// Build a mock etcd server answering the KV / Lease / Watch methods the client uses.
fn mock_etcd_server() -> @zrpc.RpcServer {
  let server = @zrpc.RpcServer::new(@conf.RpcServerConf::new())
  let kv = server.group("etcdserverpb.KV")
  // Range echoes the requested key back in a single result, so the round-trip is
  // observable in both directions.
  kv.register("Range", req => {
    let rr = EtcdRangeRequest::decode(req) catch {
      _ => EtcdRangeRequest::{ key: b"", range_end: b"", limit: 0, }
    }
    EtcdRangeResponse::{
      kvs: [
        {
          ..EtcdKeyValue::empty(),
          key: rr.key,
          value: b"1.2.3.4",
          mod_revision: 5,
        },
      ],
      count: 1,
    }.encode()
  })
  kv.register("Put", _req => {
    EtcdPutResponse::{ prev_kv: EtcdKeyValue::empty(), }.encode()
  })
  kv.register("DeleteRange", _req => {
    EtcdDeleteRangeResponse::{ deleted: 1, prev_kvs: [], }.encode()
  })
  server
  .group("etcdserverpb.Lease")
  .register("LeaseGrant", _req => {
    EtcdLeaseGrantResponse::{ id: 99, ttl: 60, error: "", }.encode()
  })
  server
  .group("etcdserverpb.Watch")
  .register_server_streaming("Watch", _req => {
    [
      EtcdWatchResponse::{
        watch_id: 1,
        created: true,
        canceled: false,
        events: [],
      }.encode(),
      EtcdWatchResponse::{
        watch_id: 1,
        created: false,
        canceled: false,
        events: [
          {
            event_type: Put,
            kv: { ..EtcdKeyValue::empty(), key: b"svc/a", value: b"1.2.3.4", },
          },
        ],
      }.encode(),
    ]
  })
  server
}

///|
/// Byte-lexicographic `<` on two ASCII keys — etcd orders and ranges its keyspace by
/// byte, whereas MoonBit's `String::compare` is length-first (shortlex), so a mock
/// standing in for etcd's range must compare bytes to match a real server's scan.
fn etcd_key_lt(a : String, b : String) -> Bool {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i = 0; i < n; i = i + 1 {
    let ca = a[i].to_int()
    let cb = b[i].to_int()
    if ca != cb {
      return ca < cb
    }
  }
  a.length() < b.length()
}

///|
/// Whether `k` falls in etcd's `[start, end)` range: `end == ""` is a single-key get,
/// otherwise a half-open byte range (the shape a prefix scan produces).
fn etcd_in_range(k : String, start : String, end : String) -> Bool {
  !etcd_key_lt(k, start) && (end == "" || etcd_key_lt(k, end))
}

///|
/// A mock etcd server backing Put / Range / DeleteRange / LeaseGrant with a Map, so a
/// key put by one call is visible to a later Range — enough to exercise discovery.
fn stateful_etcd_server() -> @zrpc.RpcServer {
  let store : Map[String, String] = Map([])
  let next_lease = Ref(1000L)
  let server = @zrpc.RpcServer::new(@conf.RpcServerConf::new())
  let kv = server.group("etcdserverpb.KV")
  kv.register("Put", req => {
    try {
      let p = EtcdPutRequest::decode(req)
      store[@utf8.decode_lossy(p.key[:])] = @utf8.decode_lossy(p.value[:])
      EtcdPutResponse::{ prev_kv: EtcdKeyValue::empty(), }.encode()
    } catch {
      _ => b""
    }
  })
  kv.register("Range", req => {
    try {
      let rr = EtcdRangeRequest::decode(req)
      let start = @utf8.decode_lossy(rr.key[:])
      let end = @utf8.decode_lossy(rr.range_end[:])
      let kvs : Array[EtcdKeyValue] = []
      for k, v in store {
        if etcd_in_range(k, start, end) {
          kvs.push({
            ..EtcdKeyValue::empty(),
            key: @utf8.encode(k),
            value: @utf8.encode(v),
          })
        }
      }
      EtcdRangeResponse::{ kvs, count: kvs.length().to_int64(), }.encode()
    } catch {
      _ => b""
    }
  })
  kv.register("DeleteRange", req => {
    try {
      let dr = EtcdDeleteRangeRequest::decode(req)
      let start = @utf8.decode_lossy(dr.key[:])
      let end = @utf8.decode_lossy(dr.range_end[:])
      let to_del : Array[String] = []
      for k, _ in store {
        if etcd_in_range(k, start, end) {
          to_del.push(k)
        }
      }
      for k in to_del {
        store.remove(k)
      }
      EtcdDeleteRangeResponse::{
        deleted: to_del.length().to_int64(),
        prev_kvs: [],
      }.encode()
    } catch {
      _ => b""
    }
  })
  server
  .group("etcdserverpb.Lease")
  .register("LeaseGrant", req => {
    try {
      let g = EtcdLeaseGrantRequest::decode(req)
      let id = next_lease.val
      next_lease.val = next_lease.val + 1L
      EtcdLeaseGrantResponse::{ id, ttl: g.ttl, error: "", }.encode()
    } catch {
      _ => b""
    }
  })
  server
}

///|
fn etcd_nib(c : Char) -> Int32 {
  if c >= '0' && c <= '9' {
    c.to_int() - '0'.to_int()
  } else if c >= 'a' && c <= 'f' {
    c.to_int() - 'a'.to_int() + 10
  } else {
    c.to_int() - 'A'.to_int() + 10
  }
}

///|
fn etcd_unhex(s : String) -> Bytes {
  let buf = Buffer()
  let chars = s.to_array()
  let mut i = 0
  while i + 1 < chars.length() {
    buf.write_byte(
      ((etcd_nib(chars[i]) << 4) | etcd_nib(chars[i + 1])).to_byte(),
    )
    i += 2
  }
  buf.to_bytes()
}

///|
test "etcd client: unary Range/Put/DeleteRange/LeaseGrant over a mock etcd gRPC server" {
  let client = EtcdClient::new(@zrpc.RpcChannel::connect(mock_etcd_server()))
  // Range: our key comes back in the response.
  let resp = client.range({ key: b"svc/a", range_end: b"", limit: 0, })
  assert_eq(resp.count, 1)
  assert_eq(resp.kvs[0].key == b"svc/a", true)
  assert_eq(resp.kvs[0].value == b"1.2.3.4", true)
  // LeaseGrant: the assigned lease id and ttl.
  let lease = client.lease_grant({ ttl: 60, id: 0, })
  assert_eq(lease.id, 99)
  assert_eq(lease.ttl, 60)
  // Put and DeleteRange complete the register/deregister pair.
  let _ = client.put({ key: b"svc/a", value: b"1.2.3.4", lease: 99, })
  let del = client.delete_range({
    key: b"svc/a",
    range_end: b"",
    prev_kv: false,
  })
  assert_eq(del.deleted, 1)
}

///|
test "etcd client: Watch streams the created response and change events" {
  let client = EtcdClient::new(@zrpc.RpcChannel::connect(mock_etcd_server()))
  let responses = client.watch(
    Create({ key: b"svc/", range_end: b"svc0", start_revision: 0, }),
  )
  assert_eq(responses.length(), 2)
  assert_eq(responses[0].created, true)
  assert_eq(responses[1].events.length(), 1)
  assert_eq(responses[1].events[0].kv.key == b"svc/a", true)
}

///|
test "etcd discovery: register two instances, resolve both, then deregister" {
  let disc = EtcdDiscovery::new(
    EtcdClient::new(@zrpc.RpcChannel::connect(stateful_etcd_server())),
  )
  // Two instances of one service register under distinct lease keys and coexist.
  let _ = disc.register("greeter", @registry.Endpoint::new("10.0.0.1", 9090))
  let _ = disc.register("greeter", @registry.Endpoint::new("10.0.0.2", 9090))
  let eps = disc.resolve("greeter")
  assert_eq(eps.length(), 2)
  let addrs = eps.map(e => e.address())
  assert_eq(addrs.contains("10.0.0.1:9090"), true)
  assert_eq(addrs.contains("10.0.0.2:9090"), true)
  // An unregistered service resolves to nothing.
  assert_eq(disc.resolve("other").length(), 0)
  // The Resolve interface value the balancer consumes sees the same set.
  assert_eq(disc.resolver()("greeter").length(), 2)
  // Deregistering the service clears its instances.
  disc.deregister("greeter")
  assert_eq(disc.resolve("greeter").length(), 0)
}

///|
test "etcd RangeRequest encodes to the exact protobuf bytes protobuf produces" {
  let req : EtcdRangeRequest = { key: b"foo", range_end: b"fop", limit: 100, }
  // protobuf: RangeRequest(key="foo", range_end="fop", limit=100)
  assert_eq(req.encode() == etcd_unhex("0a03666f6f1203666f701864"), true)
  assert_eq(EtcdRangeRequest::decode(req.encode()) == req, true)
}

///|
test "etcd KeyValue encodes to the exact protobuf bytes and round-trips" {
  let kv : EtcdKeyValue = {
    key: b"k",
    create_revision: 2,
    mod_revision: 3,
    version: 1,
    value: b"v",
    lease: 7,
  }
  // protobuf: KeyValue(key="k", create_revision=2, mod_revision=3, version=1,
  // value="v", lease=7)
  assert_eq(kv.encode() == etcd_unhex("0a016b1002180320012a01763007"), true)
  assert_eq(EtcdKeyValue::decode(kv.encode()) == kv, true)
}

///|
test "etcd PutRequest encodes to the exact protobuf bytes and round-trips" {
  let put : EtcdPutRequest = { key: b"k", value: b"v", lease: 7, }
  // protobuf: PutRequest(key="k", value="v", lease=7)
  assert_eq(put.encode() == etcd_unhex("0a016b1201761807"), true)
  assert_eq(EtcdPutRequest::decode(put.encode()) == put, true)
}

///|
test "etcd RangeResponse carries nested KeyValues and a count through a round-trip" {
  let resp : EtcdRangeResponse = {
    kvs: [
      { ..EtcdKeyValue::empty(), key: b"a", value: b"1", mod_revision: 5, },
      { ..EtcdKeyValue::empty(), key: b"b", value: b"2", mod_revision: 6, },
    ],
    count: 2,
  }
  let decoded = EtcdRangeResponse::decode(resp.encode())
  assert_eq(decoded.count, 2)
  assert_eq(decoded.kvs.length(), 2)
  assert_eq(decoded.kvs[0].key == b"a", true)
  assert_eq(decoded.kvs[1].mod_revision, 6)
  assert_eq(decoded == resp, true)
}

///|
test "etcd default (empty/zero) fields are omitted, per proto3" {
  // A RangeRequest for a single key with no range_end or limit encodes only field 1.
  let req : EtcdRangeRequest = { key: b"x", range_end: b"", limit: 0, }
  assert_eq(req.encode() == etcd_unhex("0a0178"), true)
}

///|
test "etcd Lease messages encode to the exact protobuf bytes and round-trip" {
  let grant : EtcdLeaseGrantRequest = { ttl: 60, id: 1234, }
  assert_eq(grant.encode() == etcd_unhex("083c10d209"), true)
  assert_eq(EtcdLeaseGrantRequest::decode(grant.encode()) == grant, true)
  let granted : EtcdLeaseGrantResponse = { id: 1234, ttl: 60, error: "", }
  assert_eq(granted.encode() == etcd_unhex("10d209183c"), true)
  assert_eq(EtcdLeaseGrantResponse::decode(granted.encode()) == granted, true)
  let ka : EtcdLeaseKeepAliveRequest = { id: 1234, }
  assert_eq(ka.encode() == etcd_unhex("08d209"), true)
  assert_eq(EtcdLeaseKeepAliveRequest::decode(ka.encode()) == ka, true)
  let kar : EtcdLeaseKeepAliveResponse = { id: 1234, ttl: 59, }
  assert_eq(kar.encode() == etcd_unhex("10d209183b"), true)
  assert_eq(EtcdLeaseKeepAliveResponse::decode(kar.encode()) == kar, true)
}

///|
test "etcd watch Event encodes to the exact protobuf bytes, PUT vs DELETE" {
  // A PUT event carries the full key/value; type PUT (0) is the proto3 default so it
  // is omitted from the wire.
  let put : EtcdEvent = {
    event_type: Put,
    kv: {
      ..EtcdKeyValue::empty(),
      key: b"svc/a",
      value: b"1.2.3.4",
      mod_revision: 9,
    },
  }
  assert_eq(
    put.encode() == etcd_unhex("12120a057376632f6118092a07312e322e332e34"),
    true,
  )
  assert_eq(EtcdEvent::decode(put.encode()) == put, true)
  // A DELETE event writes the type explicitly and just the key.
  let del : EtcdEvent = {
    event_type: Delete,
    kv: { ..EtcdKeyValue::empty(), key: b"svc/a", },
  }
  assert_eq(del.encode() == etcd_unhex("080112070a057376632f61"), true)
  let decoded = EtcdEvent::decode(del.encode())
  assert_eq(decoded.event_type == Delete, true)
  assert_eq(decoded.kv.key == b"svc/a", true)
}

///|
test "etcd Watch create/cancel requests encode to the exact protobuf bytes" {
  let wc : EtcdWatchCreateRequest = {
    key: b"svc/",
    range_end: b"svc0",
    start_revision: 5,
  }
  assert_eq(wc.encode() == etcd_unhex("0a047376632f1204737663301805"), true)
  assert_eq(EtcdWatchCreateRequest::decode(wc.encode()) == wc, true)
  // wrapped in the oneof WatchRequest as create_request (field 1)
  let create_req : EtcdWatchRequest = Create(wc)
  assert_eq(
    create_req.encode() == etcd_unhex("0a0e0a047376632f1204737663301805"),
    true,
  )
  assert_eq(EtcdWatchRequest::decode(create_req.encode()) == create_req, true)
  // cancel_request (field 2)
  let cancel_req : EtcdWatchRequest = Cancel({ watch_id: 42, })
  assert_eq(cancel_req.encode() == etcd_unhex("1202082a"), true)
  assert_eq(EtcdWatchRequest::decode(cancel_req.encode()) == cancel_req, true)
}

///|
test "etcd WatchResponse carries lifecycle flags and events through a round-trip" {
  let resp : EtcdWatchResponse = {
    watch_id: 7,
    created: true,
    canceled: false,
    events: [
      {
        event_type: Put,
        kv: { ..EtcdKeyValue::empty(), key: b"svc/a", value: b"h1", },
      },
    ],
  }
  // protobuf: WatchResponse(watch_id=7, created=true, events=[PUT svc/a=h1])
  assert_eq(
    resp.encode() == etcd_unhex("100718015a0d120b0a057376632f612a026831"),
    true,
  )
  let decoded = EtcdWatchResponse::decode(resp.encode())
  assert_eq(decoded.watch_id, 7)
  assert_eq(decoded.created, true)
  assert_eq(decoded.events.length(), 1)
  assert_eq(decoded.events[0].kv.key == b"svc/a", true)
  assert_eq(decoded == resp, true)
}

///|
test "etcd DeleteRange and PutResponse encode to the exact protobuf bytes" {
  let del : EtcdDeleteRangeRequest = {
    key: b"svc/a",
    range_end: b"",
    prev_kv: true,
  }
  assert_eq(del.encode() == etcd_unhex("0a057376632f611801"), true)
  assert_eq(EtcdDeleteRangeRequest::decode(del.encode()) == del, true)
  let del_range : EtcdDeleteRangeRequest = {
    key: b"svc/",
    range_end: b"svc0",
    prev_kv: false,
  }
  assert_eq(del_range.encode() == etcd_unhex("0a047376632f120473766330"), true)
  let deleted : EtcdDeleteRangeResponse = { deleted: 1, prev_kvs: [], }
  assert_eq(deleted.encode() == etcd_unhex("1001"), true)
  assert_eq(EtcdDeleteRangeResponse::decode(deleted.encode()) == deleted, true)
  let put_resp : EtcdPutResponse = {
    prev_kv: { ..EtcdKeyValue::empty(), key: b"svc/a", value: b"old", },
  }
  assert_eq(
    put_resp.encode() == etcd_unhex("120c0a057376632f612a036f6c64"),
    true,
  )
  assert_eq(EtcdPutResponse::decode(put_resp.encode()) == put_resp, true)
}
