///|
/// A cache with a size limit and an optional expiry: reads move an entry to the
/// front, and the least recently used entry is the one evicted when the limit is
/// reached.
///
/// The recency order is a doubly linked list threaded through `links`, so a hit
/// costs a constant number of map operations whatever the cache holds. An entry
/// whose time is up is dropped on the next read rather than by a background
/// sweep — a cache here is a performance device, not a store, so there is nothing
/// to reclaim on a timer.
pub struct Cache[K, V] {
  limit : Int32
  ttl_ms : Int64
  clock : @clock.Clock
  entries : Map[K, Entry[V]]
  links : Map[K, Link[K]]
  mut head : K?
  mut tail : K?
}

///|
/// One cached value and when it stops being valid; `expires_at` is `0` for an
/// entry that never expires.
struct Entry[V] {
  mut value : V
  mut expires_at : Int64
}

///|
/// One key's place in the recency list.
struct Link[K] {
  mut prev : K?
  mut next : K?
}

///|
/// A cache holding at most `limit` entries, each valid for `ttl_ms` milliseconds
/// (`0` for no expiry), reading time from `clock`.
///
/// # Parameters
/// - `limit` : entries kept before the least recently used is evicted
/// - `ttl_ms` : how long an entry stays valid, `0` for forever
/// - `clock` : the time source an expiry is measured against
pub fn[K : Hash + Eq, V] Cache::new(
  limit~ : Int32 = 1024,
  ttl_ms~ : Int64 = 0L,
  clock~ : @clock.Clock = @clock.Clock::system(),
) -> Cache[K, V] {
  {
    limit: if limit < 1 {
      1
    } else {
      limit
    },
    ttl_ms,
    clock,
    entries: Map([]),
    links: Map([]),
    head: None,
    tail: None,
  }
}

///|
/// How many entries are held, expired ones included until they are read.
pub fn[K, V] Cache::len(self : Cache[K, V]) -> Int32 {
  self.entries.length()
}

///|
/// The configured limit.
pub fn[K, V] Cache::limit(self : Cache[K, V]) -> Int32 {
  self.limit
}

///|
/// Move `key` to the front of the recency list.
fn[K : Hash + Eq, V] Cache::touch(self : Cache[K, V], key : K) -> Unit {
  guard self.head is Some(head) else { return }
  if head == key {
    return
  }
  // Unlink from where it is.
  match self.links.get(key) {
    Some(link) => {
      match link.prev {
        Some(prev) =>
          match self.links.get(prev) {
            Some(before) => before.next = link.next
            None => ()
          }
        None => ()
      }
      match link.next {
        Some(next) =>
          match self.links.get(next) {
            Some(after) => after.prev = link.prev
            None => ()
          }
        None =>
          match self.links.get(key) {
            Some(_) => self.tail = link.prev
            None => ()
          }
      }
      link.prev = None
      link.next = Some(head)
      match self.links.get(head) {
        Some(before) => before.prev = Some(key)
        None => ()
      }
      self.head = Some(key)
    }
    None => ()
  }
}

///|
/// Remove `key` from both the entries and the recency list.
pub fn[K : Hash + Eq, V] Cache::remove(self : Cache[K, V], key : K) -> Unit {
  match self.links.get(key) {
    Some(link) => {
      match link.prev {
        Some(prev) =>
          match self.links.get(prev) {
            Some(before) => before.next = link.next
            None => ()
          }
        None => self.head = link.next
      }
      match link.next {
        Some(next) =>
          match self.links.get(next) {
            Some(after) => after.prev = link.prev
            None => ()
          }
        None => self.tail = link.prev
      }
      self.links.remove(key)
    }
    None => ()
  }
  self.entries.remove(key)
}

///|
/// Whether an entry is past its time at `now`.
fn[V] Entry::expired(self : Entry[V], now : Int64) -> Bool {
  self.expires_at != 0L && self.expires_at <= now
}

///|
/// Store `value` under `key`, evicting the least recently used entry when the
/// cache is full. Storing an existing key refreshes its value, its expiry and its
/// place in the recency list.
pub fn[K : Hash + Eq, V] Cache::set(
  self : Cache[K, V],
  key : K,
  value : V,
) -> Unit {
  self.set_until(key, value, self.ttl_ms)
}

///|
/// Store `value` under `key` with its own lifetime in milliseconds; `0` means it
/// never expires.
pub fn[K : Hash + Eq, V] Cache::set_until(
  self : Cache[K, V],
  key : K,
  value : V,
  ttl_ms : Int64,
) -> Unit {
  let now = self.clock.now()
  let expires_at = if ttl_ms <= 0L { 0L } else { now + ttl_ms }
  match self.entries.get(key) {
    Some(entry) => {
      entry.value = value
      entry.expires_at = expires_at
      self.touch(key)
      return
    }
    None => ()
  }
  if self.entries.length() >= self.limit {
    match self.tail {
      Some(oldest) => self.remove(oldest)
      None => ()
    }
  }
  self.entries[key] = { value, expires_at, }
  self.links[key] = { prev: None, next: self.head, }
  match self.head {
    Some(head) =>
      match self.links.get(head) {
        Some(link) => link.prev = Some(key)
        None => ()
      }
    None => self.tail = Some(key)
  }
  self.head = Some(key)
}

///|
/// The value under `key` if it is there and still valid. Reading moves the entry
/// to the front of the recency list; an expired one is dropped.
pub fn[K : Hash + Eq, V] Cache::get(self : Cache[K, V], key : K) -> V? {
  let now = self.clock.now()
  let found = self.entries.get(key)
  match found {
    None => None
    Some(entry) =>
      if entry.expired(now) {
        self.remove(key)
        None
      } else {
        self.touch(key)
        Some(entry.value)
      }
  }
}

///|
/// Whether a valid value is under `key`, without changing the recency order.
pub fn[K : Hash + Eq, V] Cache::contains(self : Cache[K, V], key : K) -> Bool {
  let now = self.clock.now()
  match self.entries.get(key) {
    Some(entry) => !entry.expired(now)
    None => false
  }
}

///|
/// The keys in recency order, most recent first, expired ones excluded.
pub fn[K : Hash + Eq, V] Cache::keys(self : Cache[K, V]) -> Array[K] {
  let out : Array[K] = []
  let now = self.clock.now()
  let mut at = self.head
  while true {
    match at {
      Some(key) => {
        match self.entries.get(key) {
          Some(entry) => if !entry.expired(now) { out.push(key) }
          None => ()
        }
        at = match self.links.get(key) {
          Some(link) => link.next
          None => None
        }
      }
      None => break
    }
  }
  out
}
