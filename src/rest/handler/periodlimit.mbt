///|
/// Fixed-window rate-limit middleware over the process-local limiter: account for each
/// HTTP request under `key` and answer `429 Too Many Requests` once the key is over
/// quota for the current window, otherwise delegating to the wrapped app. The limiter
/// is captured once per assembly, so its windows are shared across every request this
/// layer serves — but only within this process; use `redis_period_limit` to share them
/// across replicas. Non-HTTP scopes pass through untouched.
pub fn period_limit(
  limiter : @limit.PeriodLimit,
  clock : @clock.Clock,
  key~ : String = "global",
  refusal~ : Refusal = too_many,
) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(_) =>
          match limiter.take(key, clock.now()) {
            PeriodOverQuota =>
              for event in refusal.events() {
                send(event)
              }
            _ => inner(scope, receive, send)
          }
        _ => inner(scope, receive, send)
      }
    }
  }
}

///|
/// Fixed-window rate-limit middleware over a shared redis: `period_limit` with the
/// window in redis, so replicas behind one redis spend one quota between them. A redis
/// that cannot be reached admits the request — the limiter is a guard on the
/// service, not a dependency that should be able to close it.
pub fn redis_period_limit(
  limiter : @limit.RedisPeriodLimit,
  key~ : String = "global",
  refusal~ : Refusal = too_many,
) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(_) => {
          let outcome = limiter.take(key) catch {
            RedisError(_) => PeriodAllowed
          }
          match outcome {
            PeriodOverQuota =>
              for event in refusal.events() {
                send(event)
              }
            _ => inner(scope, receive, send)
          }
        }
        _ => inner(scope, receive, send)
      }
    }
  }
}
