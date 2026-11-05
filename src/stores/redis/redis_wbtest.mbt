// A redis in a map: the keyspace, the expiries, and the byte strings exactly as
// they arrived on the wire. The commands are the ones the store issues, so a test
// observes the store's protocol — what it sends — rather than its intentions.

///|
/// A redis keyspace with expiries against a clock the test advances by hand.
struct FakeConn {
  values : Map[String, Bytes]
  expiry : Map[String, Int64]
  mut now : Int64
  mut down : Bool
}

///|
fn FakeConn::new() -> FakeConn {
  { values: Map([]), expiry: Map([]), now: 0L, down: false, }
}

///|
/// Move the server's clock on and drop whatever has fallen due.
fn FakeConn::advance(self : FakeConn, ms : Int64) -> Unit {
  self.now = self.now + ms
  let dead : Array[String] = []
  for key, at in self.expiry {
    if at <= self.now {
      dead.push(key)
    }
  }
  for key in dead {
    self.values.remove(key)
    self.expiry.remove(key)
  }
}

///|
pub impl @moonredis.RedisConn for FakeConn with fn execute(
  self : FakeConn,
  args : Array[Bytes],
) -> @resp.RespValue raise {
  guard !self.down else { raise @moonredis.Connection("gone") }
  guard args.length() > 0 else { return Error("empty command") }
  match as_text(args[0]) {
    "SET" => {
      let key = as_text(args[1])
      self.values[key] = args[2]
      if args.length() >= 5 {
        let at = self.now + as_int(args[4])
        match as_text(args[3]) {
          "PX" => self.expiry[key] = at
          "EX" => self.expiry[key] = self.now + as_int(args[4]) * 1000L
          _ => ()
        }
      }
      SimpleString("OK")
    }
    "GET" =>
      match self.values.get(as_text(args[1])) {
        Some(value) => BulkString(value)
        None => Null
      }
    "DEL" => {
      let mut gone = 0L
      for i = 1; i < args.length(); i = i + 1 {
        let key = as_text(args[i])
        if self.values.contains(key) {
          self.values.remove(key)
          self.expiry.remove(key)
          gone = gone + 1L
        }
      }
      Integer(gone)
    }
    "PTTL" => {
      let key = as_text(args[1])
      if !self.values.contains(key) {
        Integer(-2L)
      } else {
        match self.expiry.get(key) {
          Some(at) => Integer(at - self.now)
          None => Integer(-1L)
        }
      }
    }
    "INCRBY" => {
      let key = as_text(args[1])
      let base = match self.values.get(key) {
        Some(value) => as_int(value)
        None => 0L
      }
      let next = base + as_int(args[2])
      self.values[key] = @utf8.encode(next.to_string())
      Integer(next)
    }
    "KEYS" => {
      let pattern = as_text(args[1])
      let prefix = if pattern.has_suffix("*") {
        pattern[0:pattern.length() - 1].to_owned()
      } else {
        pattern
      }
      let keys : Array[@resp.RespValue] = []
      for key, _ in self.values {
        if key.has_prefix(prefix) {
          keys.push(BulkString(@utf8.encode(key)))
        }
      }
      Array(keys)
    }
    "EXPIRE" => {
      let key = as_text(args[1])
      if self.values.contains(key) {
        self.expiry[key] = self.now + as_int(args[2]) * 1000L
        Integer(1L)
      } else {
        Integer(0L)
      }
    }
    other => Error("unknown command " + other)
  }
}

///|
pub extend FakeConn with @moonredis.RedisConn::{execute, execute_all}

///|
/// A command argument as text. Every argument in these tests is either a key, a
/// command name or a number, so a byte that is not UTF-8 is a test bug.
fn as_text(bytes : Bytes) -> String {
  @utf8.decode(bytes) catch {
    _ => abort("a test argument must be text")
  }
}

///|
/// A decimal argument.
fn as_int(bytes : Bytes) -> Int64 {
  let text = as_text(bytes)
  let mut acc = 0L
  let mut at = 0
  let negative = text.length() > 0 && text[0] == '-'
  if negative {
    at = 1
  }
  while at < text.length() {
    acc = acc * 10L + (text[at].to_int() - '0'.to_int()).to_int64()
    at = at + 1
  }
  if negative {
    -acc
  } else {
    acc
  }
}

///|
/// A store over a fresh fake, and the fake it writes through.
fn fixture(prefix~ : String = "") -> (FakeConn, RedisStore) {
  let conn = FakeConn::new()
  (conn, RedisStore::new(@moonredis.Client::new(conn), prefix~))
}

///|
async test "a value comes back byte for byte" {
  let (_, store) = fixture()
  // Every octet that a UTF-8 encoder would rewrite, plus the two it would drop.
  let value : Bytes = b"\x00\x01\x7f\x80\xc3\xff"
  store.set("blob", value, 0L)
  assert_eq(store.get("blob"), Some(value))
}

///|
async test "a lifetime is sent as PX when there is one" {
  let (conn, store) = fixture()
  store.set("short", b"v", 5_000L)
  assert_eq(conn.expiry.get("short"), Some(5_000L))
  conn.advance(5_000L)
  assert_eq(store.get("short"), None)
  // No lifetime means no expiry at all, not a zero-second one.
  store.set("forever", b"v", 0L)
  assert_eq(conn.expiry.contains("forever"), false)
}

///|
async test "every key carries the store's prefix" {
  let (conn, store) = fixture(prefix="orders:")
  assert_eq(store.key_of("42"), "orders:42")
  store.set("42", b"v", 0L)
  assert_eq(conn.values.contains("orders:42"), true)
  assert_eq(conn.values.contains("42"), false)
  assert_eq(store.get("42"), Some(b"v"))
}

///|
async test "deleting a key sends the next read back to redis" {
  let (conn, store) = fixture()
  store.set("k", b"v", 0L)
  store.del("k")
  assert_eq(store.get("k"), None)
  assert_eq(conn.values.length(), 0)
}

///|
async test "a counter is one number for every replica" {
  let (_, store) = fixture(prefix="hits:")
  assert_eq(store.add("page", 1L), 1L)
  assert_eq(store.add("page", 4L), 5L)
  assert_eq(store.get("page"), Some(@utf8.encode("5")))
}

///|
async test "a ttl is reported in milliseconds, and its absence as redis reports it" {
  let (conn, store) = fixture()
  store.set("k", b"v", 2_000L)
  assert_eq(store.ttl_ms("k"), 2_000L)
  conn.advance(500L)
  assert_eq(store.ttl_ms("k"), 1_500L)
  assert_eq(store.ttl_ms("missing"), -2L)
  store.set("forever", b"v", 0L)
  assert_eq(store.ttl_ms("forever"), -1L)
}

///|
async test "re-expiring moves every key under the prefix" {
  let (conn, store) = fixture(prefix="session:")
  store.set("a", b"v", 1_000L)
  store.set("b", b"v", 0L)
  // Two keys under the prefix, and one outside it that must not move.
  conn.values["other"] = b"v"
  assert_eq(store.re_expire(60_000L), 2)
  assert_eq(conn.expiry.get("session:a"), Some(60_000L))
  assert_eq(conn.expiry.get("session:b"), Some(60_000L))
  assert_eq(conn.expiry.contains("other"), false)
}

///|
async test "a redis that is down is reported, not passed off as a miss" {
  let (conn, store) = fixture()
  store.set("k", b"v", 0L)
  conn.down = true
  let outcome = try {
    let _ = store.get("k")
    Ok(0)
  } catch {
    @cache.Refused(_) => Err(1)
  }
  assert_eq(outcome, Err(1))
}

///|
async test "a cache over redis hands back exactly what its loader produced" {
  let (_, store) = fixture(prefix="c:")
  let cache : @cache.Cache[Bytes] = @cache.Cache::new(
    store,
    encode=fn(value) { value },
    decode=fn(bytes) { Some(bytes) },
    ttl_ms=1_000L,
  )
  // A round trip through the cache is the whole path: the loader's bytes, the
  // store's write, the store's read, and the codec back.
  let value : Bytes = b"\x00\x80\xfe\xff"
  assert_eq(cache.take("k", () => Some(value)), Some(value))
  assert_eq(cache.take("k", () => Some(b"a different answer")), Some(value))
  // The lifetime is the cache's, jittered by a tenth either way.
  let ttl = store.ttl_ms("k")
  assert_eq(ttl >= 900L && ttl <= 1_100L, true)
}
