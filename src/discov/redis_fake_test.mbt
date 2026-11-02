// An in-memory redis, complete enough to be a limiter's server: a keyspace that really
// expires, the commands the client issues, and an evaluator for the two Lua scripts
// moonzero ships. The evaluators run through the same command dispatch as everything
// else, over the same keys, so two limiters pointed at one key are sharing real stored
// state rather than a counter the double keeps on the side. It lives here rather than
// beside the root package because `RedisConn` is async now, and only `discov` can run
// an async test.

///|
/// A redis keyspace in a `Map`, with expiry against a clock the test advances by hand.
/// `fails` cuts the connection; `evals` and `evalshas` count how each script call went
/// out, which is how the `SCRIPT LOAD` / `EVALSHA` caching is observed.
struct FakeRedis {
  store : Map[String, Bytes]
  expiry : Map[String, Int64]
  scripts : Map[String, String]
  mut now : Int64
  mut fails : Bool
  mut evals : Int32
  mut evalshas : Int32
}

///|
fn FakeRedis::new() -> FakeRedis {
  {
    store: Map([]),
    expiry: Map([]),
    scripts: Map([]),
    now: 0L,
    fails: false,
    evals: 0,
    evalshas: 0,
  }
}

///|
/// Move the server's clock on by `secs`, expiring whatever has fallen due.
fn FakeRedis::advance(self : FakeRedis, secs : Int64) -> Unit {
  self.now = self.now + secs
  let dead : Array[String] = []
  for key, at in self.expiry {
    if at <= self.now {
      dead.push(key)
    }
  }
  for key in dead {
    self.store.remove(key)
    self.expiry.remove(key)
  }
}

///|
impl @moonredis.RedisConn for FakeRedis with fn execute(self, args) {
  guard !self.fails else { raise @moonredis.Connection("gone") }
  self.run(args) catch {
    e => raise @moonredis.Protocol("\{e}")
  }
}

///|
/// Dispatch one command against the keyspace.
fn FakeRedis::run(
  self : FakeRedis,
  args : Array[Bytes],
) -> @resp.RespValue raise {
  guard args.length() > 0 else { return Error("empty command") }
  match text(args[0]) {
    "PING" => SimpleString("PONG")
    "SET" => {
      self.store[text(args[1])] = args[2]
      if args.length() >= 5 && text(args[3]) == "EX" {
        self.expiry[text(args[1])] = self.now + int_of(args[4])
      }
      SimpleString("OK")
    }
    "SETEX" => {
      self.store[text(args[1])] = args[3]
      self.expiry[text(args[1])] = self.now + int_of(args[2])
      SimpleString("OK")
    }
    "GET" =>
      match self.store.get(text(args[1])) {
        Some(v) => BulkString(v)
        None => Null
      }
    "INCRBY" => {
      let key = text(args[1])
      let base = match self.store.get(key) {
        Some(v) => int_of(v)
        None => 0L
      }
      let next = base + int_of(args[2])
      self.store[key] = @utf8.encode(next.to_string())
      Integer(next)
    }
    "EXPIRE" => {
      let key = text(args[1])
      if self.store.contains(key) {
        self.expiry[key] = self.now + int_of(args[2])
        Integer(1)
      } else {
        Integer(0)
      }
    }
    "TTL" => {
      let key = text(args[1])
      if !self.store.contains(key) {
        Integer(-2)
      } else {
        match self.expiry.get(key) {
          Some(at) => Integer(at - self.now)
          None => Integer(-1)
        }
      }
    }
    "DEL" => {
      let mut gone = 0L
      for i = 1; i < args.length(); i = i + 1 {
        let key = text(args[i])
        if self.store.contains(key) {
          self.store.remove(key)
          self.expiry.remove(key)
          gone += 1L
        }
      }
      Integer(gone)
    }
    "SCAN" => {
      let pattern = text(args[3])
      let keys : Array[@resp.RespValue] = []
      for k, _ in self.store {
        if glob_match(pattern, k) {
          keys.push(BulkString(@utf8.encode(k)))
        }
      }
      Array([BulkString(b"0"), Array(keys)])
    }
    "SCRIPT" =>
      if text(args[1]) == "LOAD" {
        let source = text(args[2])
        let sha = digest(source)
        self.scripts[sha] = source
        BulkString(@utf8.encode(sha))
      } else {
        Error("ERR unsupported SCRIPT subcommand")
      }
    "EVAL" => {
      self.evals = self.evals + 1
      let (keys, argv) = split_script_args(args)
      self.eval(text(args[1]), keys, argv)
    }
    "EVALSHA" => {
      self.evalshas = self.evalshas + 1
      match self.scripts.get(text(args[1])) {
        Some(source) => {
          let (keys, argv) = split_script_args(args)
          self.eval(source, keys, argv)
        }
        None => Error("NOSCRIPT No matching script. Please use EVAL.")
      }
    }
    other => Error("unknown command " + other)
  }
}

///|
/// Run one of the two scripts moonzero ships, matched on the source text it sent, so a
/// limiter that alters its script or its argument order stops being understood here.
fn FakeRedis::eval(
  self : FakeRedis,
  source : String,
  keys : Array[Bytes],
  argv : Array[Bytes],
) -> @resp.RespValue raise {
  if source == @moonzero.period_script {
    self.eval_period(keys, argv)
  } else if source == @moonzero.token_script {
    self.eval_token(keys, argv)
  } else {
    Error("ERR this fake only evaluates moonzero's two limiter scripts")
  }
}

///|
/// `periodscript.lua`: INCRBY the key, hang the window on it the first time round, and
/// report 1 below quota / 2 at it / 0 past it.
fn FakeRedis::eval_period(
  self : FakeRedis,
  keys : Array[Bytes],
  argv : Array[Bytes],
) -> @resp.RespValue raise {
  let limit = int_of(argv[0])
  let window = argv[1]
  let current = match self.run([b"INCRBY", keys[0], b"1"]) {
    Integer(n) => n
    _ => 0L
  }
  if current == 1L {
    let _ = self.run([b"EXPIRE", keys[0], window])
  }
  if current < limit {
    Integer(1)
  } else if current == limit {
    Integer(2)
  } else {
    Integer(0)
  }
}

///|
/// `tokenscript.lua`: refill by the seconds elapsed, capped at capacity, spend the
/// request if the tokens are there, and write the bucket and its timestamp back under a
/// TTL of two fill times. Lua's `false` leaves redis as a null reply, its `true` as `1`.
fn FakeRedis::eval_token(
  self : FakeRedis,
  keys : Array[Bytes],
  argv : Array[Bytes],
) -> @resp.RespValue raise {
  let rate = num_of(argv[0])
  let capacity = num_of(argv[1])
  let now = num_of(argv[2])
  let requested = num_of(argv[3])
  let ttl = @utf8.encode((capacity / rate * 2.0).to_int().to_string())
  let last_tokens = match self.run([b"GET", keys[0]]) {
    BulkString(v) => num_of(v)
    _ => capacity
  }
  let last_refreshed = match self.run([b"GET", keys[1]]) {
    BulkString(v) => num_of(v)
    _ => 0.0
  }
  let delta = if now - last_refreshed > 0.0 {
    now - last_refreshed
  } else {
    0.0
  }
  let filled_raw = last_tokens + delta * rate
  let filled = if filled_raw < capacity { filled_raw } else { capacity }
  let allowed = filled >= requested
  let new_tokens = if allowed { filled - requested } else { filled }
  let _ = self.run([
    b"SETEX",
    keys[0],
    ttl,
    @utf8.encode(new_tokens.to_string()),
  ])
  let _ = self.run([b"SETEX", keys[1], ttl, @utf8.encode(now.to_string())])
  if allowed {
    Integer(1)
  } else {
    Null
  }
}

///|
/// Split an `EVAL`/`EVALSHA` argument vector into its `KEYS` and its `ARGV`, reading the
/// key count off the wire the way redis does.
fn split_script_args(args : Array[Bytes]) -> (Array[Bytes], Array[Bytes]) {
  let n = int_of(args[2]).to_int()
  let keys : Array[Bytes] = []
  let argv : Array[Bytes] = []
  for i = 3; i < args.length(); i = i + 1 {
    if i < 3 + n {
      keys.push(args[i])
    } else {
      argv.push(args[i])
    }
  }
  (keys, argv)
}

///|
/// A stable 40-hex-character digest standing in for the SHA1 redis addresses a script
/// by; the shape is what matters, not the algorithm.
fn digest(source : String) -> String {
  @base16.encode(@sha2.hash(@utf8.encode(source)[:])[0:20])
}

///|
fn text(b : Bytes) -> String {
  @utf8.decode_lossy(b[:])
}

///|
/// A stored or argument number as an integer; a value that is not one reads as zero,
/// which is what `tonumber` folding to `nil` amounts to at these call sites.
fn int_of(b : Bytes) -> Int64 {
  @string.parse_int64(text(b)) catch {
    _ => 0L
  }
}

///|
fn num_of(b : Bytes) -> Double {
  @string.parse_double(text(b)) catch {
    _ => 0.0
  }
}

///|
/// Redis glob match supporting `*` (any run) and `?` (one char) — the discovery driver
/// only ever scans with a trailing `*`, but a real matcher keeps the fake honest.
fn glob_match(pattern : String, s : String) -> Bool {
  let np = pattern.length()
  let ns = s.length()
  // Backtracking match: `star` remembers the last `*`, `mark` the input position to
  // resume from if the tail fails.
  let mut pi = 0
  let mut si = 0
  let mut star = -1
  let mut mark = 0
  while si < ns {
    if pi < np && (pattern[pi] == s[si] || pattern[pi] == '?') {
      pi += 1
      si += 1
    } else if pi < np && pattern[pi] == '*' {
      star = pi
      mark = si
      pi += 1
    } else if star >= 0 {
      pi = star + 1
      mark += 1
      si = mark
    } else {
      return false
    }
  }
  while pi < np && pattern[pi] == '*' {
    pi += 1
  }
  pi == np
}
