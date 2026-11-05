///|
/// A token-bucket rate limiter kept in this process: the bucket holds up to
/// `burst` tokens and refills continuously at `rate` a second, and each admitted
/// request spends one. Every decision is a function of the state and `now`, so the
/// limiter is testable without a real clock.
///
/// The bucket is local, so N replicas admit N times the rate. `RedisTokenLimit` is
/// the same limiter with its bucket in redis and is what a fleet should run; this
/// one serves a single process, and is what `RedisTokenLimit` itself falls back to
/// when redis is unreachable (← go-zero's `rescueLimiter`).
pub struct TokenBucket {
  bucket : @moonward.Bucket
}

///|
/// Build a bucket admitting `rate` requests per second on average with room for a
/// `burst` of that many back-to-back (default `burst = rate`). It starts full at
/// time `now`, in milliseconds.
///
/// The bucket is moonward's; this keeps go-zero's shape and its millisecond clock.
/// A capacity below one token is raised to one, because a bucket that can never hold
/// a whole token admits nothing at all — which is what a fractional `rate` with no
/// `burst` used to give.
pub fn TokenBucket::new(
  rate : Double,
  burst~ : Double = -1.0,
  now~ : Int64 = 0,
) -> TokenBucket {
  {
    bucket: @moonward.Bucket::new(
      rate,
      burst=if burst <= 0.0 { 0.0 } else { burst },
      now=nanos(now),
    ),
  }
}

///|
/// Try to admit one request at time `now`. Returns `true` when admitted, `false`
/// when the bucket is empty.
pub fn TokenBucket::allow(self : TokenBucket, now : Int64) -> Bool {
  self.allow_n(1.0, now)
}

///|
/// Try to admit a request costing `n` tokens at time `now`. Returns `false`
/// (spending nothing) when fewer than `n` tokens are available.
pub fn TokenBucket::allow_n(
  self : TokenBucket,
  n : Double,
  now : Int64,
) -> Bool {
  self.bucket.take(nanos(now), n~)
}

///|
/// The (fractional) number of tokens currently available at `now`. Useful for
/// metrics and tests.
pub fn TokenBucket::available(self : TokenBucket, now : Int64) -> Double {
  self.bucket.tokens(nanos(now))
}

///|
/// A millisecond reading as the nanoseconds moonward's clock is read in.
fn nanos(ms : Int64) -> Int64 {
  ms * 1_000_000L
}

///|
/// go-zero's `core/limit/tokenscript.lua`, verbatim: read the bucket and the second it
/// was last touched, refill by the elapsed seconds capped at `capacity`, spend
/// `requested` if that many are there, and write both back under a TTL of two fill
/// times. Public so a caller can pre-load it, and so a redis double can evaluate the
/// very text the limiter ships.
pub let token_script : String =
  #|-- to be compatible with aliyun redis, we cannot use `local key = KEYS[1]` to reuse the key
  #|-- KEYS[1] as tokens_key
  #|-- KEYS[2] as timestamp_key
  #|local rate = tonumber(ARGV[1])
  #|local capacity = tonumber(ARGV[2])
  #|local now = tonumber(ARGV[3])
  #|local requested = tonumber(ARGV[4])
  #|local fill_time = capacity/rate
  #|local ttl = math.floor(fill_time*2)
  #|local last_tokens = tonumber(redis.call("get", KEYS[1]))
  #|if last_tokens == nil then
  #|    last_tokens = capacity
  #|end
  #|
  #|local last_refreshed = tonumber(redis.call("get", KEYS[2]))
  #|if last_refreshed == nil then
  #|    last_refreshed = 0
  #|end
  #|
  #|local delta = math.max(0, now-last_refreshed)
  #|local filled_tokens = math.min(capacity, last_tokens+(delta*rate))
  #|local allowed = filled_tokens >= requested
  #|local new_tokens = filled_tokens
  #|if allowed then
  #|    new_tokens = filled_tokens - requested
  #|end
  #|
  #|redis.call("setex", KEYS[1], ttl, new_tokens)
  #|redis.call("setex", KEYS[2], ttl, now)
  #|
  #|return allowed

///|
/// A token-bucket rate limiter whose bucket lives in redis (← go-zero's
/// `limit.TokenLimiter`). The token count and the second it was last refilled sit under
/// `{key}.tokens` and `{key}.ts`, so every replica pointed at the same redis and key
/// spends from one bucket. When redis cannot be reached the limiter keeps limiting from
/// `rescue`, its process-local `TokenBucket`, the way go-zero drops to its in-process
/// `rescueLimiter` rather than letting an outage open the gate.
pub struct RedisTokenLimit {
  client : @moonredis.Client
  script : @moonredis.Script
  rate : Int32
  burst : Int32
  token_key : String
  ts_key : String
  rescue : TokenBucket
  /// Whether redis is answering. A limiter that has lost redis keeps limiting from
  /// its local bucket instead of opening the gate, and returns to the shared bucket
  /// once the probe finds redis again.
  mut alive : Bool
  mut probing : Bool
}

///|
/// A limiter admitting `rate` requests per second with room for a `burst` of that many
/// back-to-back, over the bucket `key` names in `client`'s redis.
pub fn RedisTokenLimit::new(
  client : @moonredis.Client,
  rate~ : Int32,
  burst~ : Int32,
  key~ : String,
) -> RedisTokenLimit {
  {
    client,
    script: @moonredis.Script::new(token_script),
    rate,
    burst,
    token_key: "{" + key + "}.tokens",
    ts_key: "{" + key + "}.ts",
    rescue: TokenBucket::new(rate.to_double(), burst=burst.to_double()),
    alive: true,
    probing: false,
  }
}

///|
/// The process-local bucket this limiter falls back to, so a caller can inspect it.
pub fn RedisTokenLimit::rescue(self : RedisTokenLimit) -> TokenBucket {
  self.rescue
}

///|
/// Try to admit one request at `now_ms`.
pub async fn RedisTokenLimit::allow(
  self : RedisTokenLimit,
  now_ms : Int64,
) -> Bool {
  self.allow_n(1, now_ms)
}

///|
/// Try to admit a request costing `n` tokens at `now_ms`. The script is handed whole
/// seconds because go-zero hands it `now.Unix()`: the shared bucket refills at
/// one-second granularity however finely the clock is read. Lua's `false` arrives as a
/// null reply and its `true` as `1`; anything else, and any redis failure, is served by
/// the local bucket instead.
pub async fn RedisTokenLimit::allow_n(
  self : RedisTokenLimit,
  n : Int32,
  now_ms : Int64,
) -> Bool {
  // A read of a plain flag, so the fast path costs nothing once redis is known to be
  // down: every call goes straight to the local bucket until the probe says
  // otherwise.
  if !self.alive {
    return self.rescue.allow_n(n.to_double(), now_ms)
  }
  let reply = self.script.run(self.client, [self.token_key, self.ts_key], [
    self.rate.to_string(),
    self.burst.to_string(),
    (now_ms / 1000L).to_string(),
    n.to_string(),
  ]) catch {
    _ => {
      self.alive = false
      return self.rescue.allow_n(n.to_double(), now_ms)
    }
  }
  match reply {
    Integer(code) => code == 1L
    Null => false
    _ => {
      self.alive = false
      self.rescue.allow_n(n.to_double(), now_ms)
    }
  }
}

///|
/// Whether this limiter is drawing on the shared bucket. `false` means it is on its
/// local one, waiting for the probe to find redis again.
pub fn RedisTokenLimit::is_alive(self : RedisTokenLimit) -> Bool {
  self.alive
}

///|
/// Mark redis as unreachable without waiting for a call to fail — what a liveness
/// probe does when it sees the connection drop.
pub fn RedisTokenLimit::mark_down(self : RedisTokenLimit) -> Unit {
  self.alive = false
}

///|
/// Mark redis as answering again. The shared bucket still holds whatever the last
/// replica left in it, so the limiter picks up the fleet's quota rather than a fresh
/// one.
pub fn RedisTokenLimit::mark_alive(self : RedisTokenLimit) -> Unit {
  self.alive = true
}

///|
/// Whether a background probe is running.
pub fn RedisTokenLimit::probing(self : RedisTokenLimit) -> Bool {
  self.probing
}

///|
/// Ping redis once and switch the limiter back to the shared bucket when it answers.
/// The reading is the caller's: an unreachable redis is not an error here, it is the
/// reason the local bucket exists.
pub async fn RedisTokenLimit::probe(self : RedisTokenLimit) -> Bool {
  let answered = try {
    let _ = self.client.ping()
    true
  } catch {
    _ => false
  }
  if answered {
    self.alive = true
  } else {
    self.alive = false
  }
  answered
}

///|
/// Probe every `interval_ms` until cancelled, and hand each reading to `report`.
///
/// This is the background half of the liveness model: the limiter marks itself down
/// the moment a call fails, and this loop is what brings it back. It is a function
/// rather than a task the limiter starts for itself, so where the task belongs —
/// which group, which lifetime — stays the caller's decision.
pub async fn RedisTokenLimit::probe_forever(
  self : RedisTokenLimit,
  interval_ms~ : Int32 = 100,
  report~ : (Bool) -> Unit = _alive => (),
) -> Unit {
  self.probing = true
  while true {
    let alive = self.probe()
    report(alive)
    @async.sleep(interval_ms)
  }
}
