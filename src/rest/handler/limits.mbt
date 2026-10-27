///|
/// Timeout middleware (← go-zero's `TimeoutHandler`): start a moonward `Deadline`
/// of `budget_ms` at `clock.now()` for each request to the wrapped app.
///
/// **Async boundary (faithful model).** *Preemptively* aborting an in-flight
/// handler the instant its deadline fires requires racing the handler against a
/// timer and cancelling the loser — in MoonBit that is `@async.any([handler,
/// timer])` with structured cancellation, which only runs under the native async
/// runtime and cannot be driven synchronously. What this middleware does
/// portably: it installs the deadline and enforces it on the response path — if
/// the handler blows its budget before emitting its first event, the client
/// receives a `503` timeout (from `timeout_events`) and the late response is
/// suppressed. The remaining gap (a handler that hangs and never emits) is closed
/// by the race/cancel wired at the async server edge. A `budget_ms <= 0` disables
/// the timeout, passing straight through.
pub fn timeout(
  budget_ms : Int64,
  clock : @clock.Clock,
  refusal~ : Refusal = timed_out,
) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(_) => {
          let deadline = @moonward.Deadline::start(
            @moondate.Span::new(millis=budget_ms),
            clock.now() * 1_000_000L,
          )
          let done : Ref[Bool] = { val: false, }
          let guarded : @moonasgi.Send = event => {
            if done.val {
              // deadline already answered — drop the handler's late output
              ()
            } else if deadline.expired(clock.now() * 1_000_000L) {
              done.val = true
              for e in refusal.events() {
                send(e)
              }
            } else {
              send(event)
            }
          }
          inner(scope, receive, guarded)
        }
        _ => inner(scope, receive, send)
      }
    }
  }
}

///|
/// Parse a non-negative decimal string to `Int`, returning `None` for an empty
/// string or any non-digit character. Used to read `Content-Length`; core has no
/// portable integer parser, so it is hand-written.
fn parse_uint(s : String) -> Int32? {
  if s.length() == 0 {
    return None
  }
  let mut acc = 0
  for i in 0..<s.length() {
    let c = s[i].to_int()
    if c < '0'.to_int() || c > '9'.to_int() {
      return None
    }
    acc = acc * 10 + (c - '0'.to_int())
  }
  Some(acc)
}

///|
/// Whether an HTTP scope's declared `Content-Length` exceeds `limit` bytes. A
/// missing or unparseable length is treated as *not* exceeding (go-zero's
/// `MaxBytesHandler` likewise enforces on the declared/streamed size). The header
/// name is matched case-insensitively.
fn content_length_exceeds(scope : @moonasgi.Scope, limit : Int32) -> Bool {
  match scope {
    Http(hs) => {
      for pair in hs.headers {
        if pair.0.to_lower() == "content-length" {
          match parse_uint(pair.1) {
            Some(n) => return n > limit
            None => return false
          }
        }
      }
      false
    }
    _ => false
  }
}

///|
/// Max-bytes middleware (← go-zero's `MaxBytesHandler`): reject any HTTP request
/// whose declared `Content-Length` exceeds `limit` bytes with `413 Payload Too
/// Large`, before the wrapped app runs. A `limit <= 0` disables the check. Non-
/// HTTP scopes pass through untouched.
pub fn maxbytes(limit : Int32, refusal~ : Refusal = too_large) -> Middleware {
  inner => {
    (scope, receive, send) => {
      if limit > 0 && content_length_exceeds(scope, limit) {
        for event in refusal.events() {
          send(event)
        }
      } else {
        inner(scope, receive, send)
      }
    }
  }
}
