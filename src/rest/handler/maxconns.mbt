// Bounding the number of concurrent in-flight requests (← go-zero's `MaxConns` /
// `handler.MaxConnsHandler`): a semaphore of `max` permits. Each admitted HTTP request holds a
// permit for its whole duration and returns it when it finishes; a request that finds no permit
// free is answered `503 Service Unavailable` without reaching the app. This caps the work in flight
// so a burst of connections cannot exhaust the server, complementing the rate limiter (which bounds
// the arrival rate) and the breaker (which sheds on downstream failure).

///|
/// Max-connections middleware (← go-zero's `MaxConns`): hold a permit for the wrapped app's
/// duration, or answer `503 Service Unavailable` when every permit is taken. Non-HTTP scopes
/// (lifespan, websocket) pass through untouched.
pub fn max_conns(
  limit : @limit.MaxConns,
  refusal~ : Refusal = unavailable,
) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(_) =>
          if limit.try_acquire() {
            // The permit has to come back on every path. As a trailing statement it
            // was skipped whenever the inner app raised or was cancelled, and the
            // limiter then wedged shut on 503 with permits it could never reclaim.
            defer limit.release()
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
