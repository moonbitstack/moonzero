///|
test "a ring keeps the newest samples" {
  let ring : Ring[Int32] = Ring::new(3)
  for i = 1; i <= 5; i = i + 1 {
    ring.push(i)
  }
  assert_eq(ring.len(), 3)
  assert_eq(ring.to_array(), [3, 4, 5])
  assert_eq(ring.last(), Some(5))
  assert_eq(ring.get(0), Some(3))
  assert_eq(ring.get(9), None)
  // the capacity is never exceeded, whatever is pushed
  assert_eq(ring.capacity(), 3)
}

///|
test "a cache evicts the least recently used entry" {
  let manual = @clock.ManualClock::new()
  let cache : Cache[String, Int32] = Cache::new(
    limit=2,
    clock=manual.as_clock(),
  )
  cache.set("a", 1)
  cache.set("b", 2)
  // reading `a` makes `b` the least recently used
  assert_eq(cache.get("a"), Some(1))
  cache.set("c", 3)
  assert_eq(cache.get("b"), None)
  assert_eq(cache.get("a"), Some(1))
  assert_eq(cache.get("c"), Some(3))
  assert_eq(cache.len(), 2)
}

///|
test "a cache forgets an entry whose time is up" {
  let manual = @clock.ManualClock::new()
  let cache : Cache[String, Int32] = Cache::new(
    limit=4,
    ttl_ms=1_000L,
    clock=manual.as_clock(),
  )
  cache.set("a", 1)
  assert_eq(cache.get("a"), Some(1))
  manual.advance(1_001L)
  assert_eq(cache.get("a"), None)
  assert_eq(cache.contains("a"), false)
  assert_eq(cache.len(), 0)
}

///|
test "keys come out most recent first" {
  let manual = @clock.ManualClock::new()
  let cache : Cache[String, Int32] = Cache::new(
    limit=4,
    clock=manual.as_clock(),
  )
  cache.set("a", 1)
  cache.set("b", 2)
  cache.set("c", 3)
  assert_eq(cache.keys(), ["c", "b", "a"])
  let _ = cache.get("a")
  assert_eq(cache.keys(), ["a", "c", "b"])
  cache.remove("c")
  assert_eq(cache.keys(), ["a", "b"])
}
