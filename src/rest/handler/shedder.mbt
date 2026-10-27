///|
/// Shedding middleware (← go-zero's `SheddingHandler`): answer `503 Service
/// Unavailable` without running the app while the shedder is refusing, and pass
/// everything else through. Non-HTTP scopes are never shed.
///
/// An admitted request whose app answers 503 is settled as failed, any other as
/// passed, which is the one status go-zero tells its shedder apart.
pub fn shedding(
  s : @shedder.Shedder,
  refusal~ : Refusal = unavailable,
) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(_) =>
          match s.allow() {
            Some(ticket) => {
              let status : Ref[Int32] = { val: 200, }
              let observed : @moonasgi.Send = event => {
                if event is HttpResponseStart(status=code, ..) {
                  status.val = code
                }
                send(event)
              }
              defer (if status.val == 503 {
                ticket.fail()
              } else {
                ticket.pass()
              })
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
