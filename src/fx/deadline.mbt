///|
/// Run `body` with a deadline of `ms` milliseconds. `None` means it ran out; a body
/// that fails still raises, so a caller can tell a slow answer from a wrong one.
pub async fn[A] timeout(ms : Int32, body : async () -> A) -> A? {
  guard ms > 0 else { return Some(body()) }
  let outcome : Result[A?, Error] = Ok(@async.with_timeout_opt(ms, body)) catch {
    error => Err(error)
  }
  match outcome {
    Ok(value) => value
    Err(error) => raise error
  }
}
