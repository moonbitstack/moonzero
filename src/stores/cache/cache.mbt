// Cache-aside over a store, with one load per key in flight.

///|
/// A cache in front of a store (← go-zero's `cache.Cache`): `take` answers from the
/// store when the value is there, and otherwise runs the loader once — not once per
/// waiting caller — and writes the answer back with a lifetime that is jittered so a
/// fleet warmed at the same moment does not expire together.
///
/// A value is stored as bytes: the cache is over the codec, so it works for a record
/// read out of SQL and for a counter read out of redis alike.
pub struct Cache[V] {
  store : &Store
  encode : (V) -> Bytes
  decode : (Bytes) -> V? raise
  flights : @syncx.Single[V?]
  ttl_ms : Int64
  jitter : (Int64) -> Int64
}

///|
/// A cache over `store`, reading and writing `V` through `encode` and `decode`, and
/// keeping a loader's answer for `ttl_ms` milliseconds.
///
/// `jitter` spreads an expiry over a window; the default answers a value between
/// a tenth below and a tenth above the lifetime, which is what keeps a fleet from
/// stampeding the database one second at a time.
pub fn[V] Cache::new(
  store : &Store,
  encode~ : (V) -> Bytes,
  decode~ : (Bytes) -> V? raise,
  ttl_ms~ : Int64 = 60_000L,
  jitter? : (Int64) -> Int64,
) -> Cache[V] {
  let state : Ref[UInt64] = { val: 0x9E3779B97F4A7C15UL, }
  let default : (Int64) -> Int64 = ttl => {
    if ttl <= 0L {
      ttl
    } else {
      state.val = state.val * 6364136223846793005UL + 1442695040888963407UL
      let spread = (state.val >> 33).reinterpret_as_int64() % (ttl / 5L + 1L)
      ttl - ttl / 10L + (if spread < 0L { -spread } else { spread })
    }
  }
  {
    store,
    encode,
    decode,
    flights: @syncx.Single::new(),
    ttl_ms,
    jitter: match jitter {
      Some(jitter) => jitter
      None => default
    },
  }
}

///|
/// The configured lifetime.
pub fn[V] Cache::ttl_ms(self : Cache[V]) -> Int64 {
  self.ttl_ms
}

///|
/// The value under `key`, loading and caching it when the store does not have it.
///
/// One loader runs per key however many callers arrive while it is working, and all
/// of them receive its answer. `None` from the loader is not cached: an absent row
/// may appear a moment later, and caching the absence is how a cache turns a
/// transient gap into a minute of wrong answers.
pub async fn[V] Cache::take(
  self : Cache[V],
  key : String,
  load : async () -> V?,
) -> V? {
  match self.store.get(key) {
    Some(bytes) => (self.decode)(bytes)
    None =>
      self.flights.run(key, () => {
        // The second read is the one that matters: another task may have filled the
        // entry between the miss above and this flight starting.
        match self.store.get(key) {
          Some(bytes) => (self.decode)(bytes)
          None =>
            match load() {
              Some(value) => {
                self.store.set(
                  key,
                  (self.encode)(value),
                  (self.jitter)(self.ttl_ms),
                )
                Some(value)
              }
              None => None
            }
        }
      })
  }
}

///|
/// Drop `key` from the store, so the next `take` loads it again.
pub async fn[V] Cache::evict(self : Cache[V], key : String) -> Unit {
  self.store.del(key)
}

///|
/// How many loads are in flight, which is also how many keys are being shared.
pub fn[V] Cache::inflight(self : Cache[V]) -> Int32 {
  self.flights.len()
}
