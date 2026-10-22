///|
/// Circuit-breaker middleware (← go-zero's `breaker` interceptor): gate each
/// HTTP request through a shared `Breaker`. An admitted request's outbound
/// `HttpResponseStart` status is observed — a `5xx` settles its promise as a
/// failure, anything else as a success, and that is what feeds the window. A
/// shed request is answered `503 Service Unavailable` without the wrapped app
/// running. Non-HTTP scopes pass through untouched.
///
/// The promise starts out a failure and only the observed status makes it a
/// success, on a `defer` — the same shape go-zero's `doReq` uses, so a handler
/// that raises or is cancelled before answering counts against the window
/// instead of quietly not counting at all.
pub fn breaker(
  b : @breaker.Breaker,
  refusal~ : Refusal = unavailable,
) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(_) =>
          match b.allow() {
            Some(p) => {
              let status : Ref[Int32] = { val: 500, }
              let observed : @moonasgi.Send = event => {
                match event {
                  HttpResponseStart(status=s, headers~, trailers~) => {
                    status.val = s
                    send(
                      @moonasgi.Event::HttpResponseStart(
                        status=s,
                        headers~,
                        trailers~,
                      ),
                    )
                  }
                  other => send(other)
                }
              }
              defer (if status.val >= 500 { p.reject() } else { p.accept() })
              inner(scope, receive, observed)
            }
            None =>
              for event in refusal.events() {
                send(event)
              }
          }
        _ => inner(scope, receive, send)
      }
    }
  }
}
