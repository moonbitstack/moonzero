///|
/// Shedding middleware (← go-zero's `SheddingHandler`): answer `503 Service
/// Unavailable` without running the app while the shedder is refusing, and pass
/// everything else through. Non-HTTP scopes are never shed.
pub fn shedding(
  s : @shedder.Shedder,
  refusal~ : Refusal = unavailable,
) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(_) =>
          if s.allow() {
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
