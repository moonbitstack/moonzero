///|
/// A value as its decimal text, so the test speaks the store's bytes without
/// pulling in a serialiser.
fn encode(i : Int32) -> Bytes {
  @utf8.encode(i.to_string())
}

///|
/// The inverse of `encode`.
fn decode(bytes : Bytes) -> Int32? raise {
  let text = @utf8.decode(bytes) catch { _ => raise Refused("not utf-8") }
  guard text.length() > 0 else { raise Refused("empty") }
  let mut acc = 0
  for i = 0; i < text.length(); i = i + 1 {
    let digit = text[i].to_int() - '0'.to_int()
    guard digit >= 0 && digit <= 9 else { raise Refused("not a number") }
    acc = acc * 10 + digit
  }
  Some(acc)
}

///|
async test "a miss loads once and the next call is served from the store" {
  let store = Memory::new()
  let cache : Cache[Int32] = Cache::new(store, encode~, decode~, ttl_ms=60_000L)
  let loads : Ref[Int32] = { val: 0, }
  assert_eq(
    cache.take("answer", () => {
      loads.val = loads.val + 1
      Some(42)
    }),
    Some(42),
  )
  assert_eq(
    cache.take("answer", () => {
      loads.val = loads.val + 1
      Some(42)
    }),
    Some(42),
  )
  assert_eq(loads.val, 1)
}

///|
async test "concurrent misses share one load" {
  let store = Memory::new()
  let cache : Cache[Int32] = Cache::new(store, encode~, decode~, ttl_ms=60_000L)
  let loads : Ref[Int32] = { val: 0, }
  let load : async () -> Int32? = () => {
    loads.val = loads.val + 1
    @async.sleep(20)
    Some(7)
  }
  let callers : Array[async () -> Int32?] = [
    () => cache.take("k", load),
    () => cache.take("k", load),
    () => cache.take("k", load),
  ]
  let answers = @async.all(callers)
  assert_eq(answers, [Some(7), Some(7), Some(7)])
  assert_eq(loads.val, 1)
}

///|
async test "an absent value is not cached" {
  let store = Memory::new()
  let cache : Cache[Int32] = Cache::new(store, encode~, decode~, ttl_ms=60_000L)
  let loads : Ref[Int32] = { val: 0, }
  let load : async () -> Int32? = () => {
    loads.val = loads.val + 1
    None
  }
  assert_eq(cache.take("missing", load), None)
  assert_eq(cache.take("missing", load), None)
  assert_eq(loads.val, 2)
}

///|
async test "evicting a key sends the next read back to the loader" {
  let store = Memory::new()
  let cache : Cache[Int32] = Cache::new(store, encode~, decode~, ttl_ms=60_000L)
  let loads : Ref[Int32] = { val: 0, }
  let load : async () -> Int32? = () => {
    loads.val = loads.val + 1
    Some(loads.val)
  }
  assert_eq(cache.take("k", load), Some(1))
  cache.evict("k")
  assert_eq(cache.take("k", load), Some(2))
  assert_eq(loads.val, 2)
}

///|
test "the default jitter keeps an expiry within a fifth of the lifetime" {
  let store = Memory::new()
  let cache : Cache[Int32] = Cache::new(store, encode~, decode~, ttl_ms=1_000L)
  let mut turns = 20
  while turns > 0 {
    let ttl = (cache.jitter)(cache.ttl_ms())
    assert_eq(ttl >= 900L && ttl <= 1_100L, true)
    turns = turns - 1
  }
}
