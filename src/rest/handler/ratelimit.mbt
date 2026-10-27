///|
/// Rate-limit middleware over the process-local bucket: admit each HTTP request
/// against a shared `TokenBucket` read at `clock.now()`, answering `429 Too Many
/// Requests` when the bucket is empty and otherwise delegating to the wrapped app.
/// The bucket is captured once per assembly, so its state is shared across every
/// request this layer serves — but only within this process; use
/// `redis_rate_limit` to share it across replicas. Non-HTTP scopes (lifespan,
/// websocket) pass through untouched.
pub fn rate_limit(
  bucket : @limit.TokenBucket,
  clock : @clock.Clock,
  refusal~ : Refusal = too_many,
) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(_) =>
          if bucket.allow(clock.now()) {
            inner(scope, receive, send)
          } else {
            for event in refusal.events() {
              send(event)
            }
          }
        _ => inner(scope, receive, send)
      }
    }
  }
}

///|
/// Rate-limit middleware over a shared redis: `rate_limit` with the bucket in redis, so
/// replicas behind one redis spend from one bucket. A redis that cannot be reached
/// leaves the limiter running on its local bucket, so the layer keeps limiting either
/// way. Non-HTTP scopes pass through untouched.
pub fn redis_rate_limit(
  limiter : @limit.RedisTokenLimit,
  clock : @clock.Clock,
  refusal~ : Refusal = too_many,
) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(_) =>
          if limiter.allow(clock.now()) {
            inner(scope, receive, send)
          } else {
            for event in refusal.events() {
              send(event)
            }
          }
        _ => inner(scope, receive, send)
      }
    }
  }
}
