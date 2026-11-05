// A key-value store with a lifetime per entry, and the cache-aside layer over it.

///|
/// A store failure: a backend that is down, a value that will not decode.
pub(all) suberror Refused {
  Refused(String)
}

///|
/// Where cached values live: a key, the value's bytes, and how long the value stays
/// valid. Values cross this seam as bytes so one store serves any type — the codec
/// belongs to the cache above it, not to the store.
///
/// Everything a cache does (the single flight, the jitter, the ordering of reads and
/// writes) sits above this trait, so a process-local map and a remote redis are
/// interchangeable behind it.
pub(open) trait Store {
  /// The value under `key`, or `None` when it is absent or expired.
  async fn get(Self, String) -> Bytes? raise Refused
  /// Keep `value` under `key` for `ttl_ms` milliseconds; `0` means until it is
  /// dropped.
  async fn set(Self, String, Bytes, Int64) -> Unit raise Refused
  /// Drop `key`.
  async fn del(Self, String) -> Unit raise Refused
}

///|
/// A store in this process, over the bounded LRU cache: an entry lives until its
/// lifetime is up or the cache needs its room.
pub struct Memory {
  entries : @collection.Cache[String, Bytes]
}

///|
/// A memory store holding at most `limit` entries.
pub fn Memory::new(
  limit~ : Int32 = 1024,
  clock~ : @clock.Clock = @clock.Clock::system(),
) -> Memory {
  { entries: @collection.Cache::new(limit~, ttl_ms=0L, clock~), }
}

///|
pub impl Store for Memory with fn get(self : Memory, key : String) -> Bytes? raise Refused {
  self.entries.get(key)
}

///|
pub impl Store for Memory with fn set(
  self : Memory,
  key : String,
  value : Bytes,
  ttl_ms : Int64,
) -> Unit raise Refused {
  self.entries.set_until(key, value, ttl_ms)
}

///|
pub impl Store for Memory with fn del(self : Memory, key : String) -> Unit raise Refused {
  self.entries.remove(key)
}

///|
pub extend Memory with Store::{get, set, del}
