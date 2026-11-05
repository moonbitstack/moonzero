///|
/// One call in flight per key: a second caller asking for the same key while the
/// first is still running waits for that answer instead of issuing a second call,
/// and every one of them receives the same result — or the same failure.
///
/// This is the primitive a cache-aside store is built on: a miss under load must
/// put one query on the database, not one per request.
pub struct Single[T] {
  inflight : Map[String, Inflight[T]]
}

///|
/// One key's call: the waiters' condition, and the answer once it is known.
struct Inflight[T] {
  cond : @cond_var.Cond
  mut done : Bool
  mut outcome : Result[T, Error]?
}

///|
/// An empty group: no call in flight.
pub fn[T] Single::new() -> Single[T] {
  { inflight: Map([]), }
}

///|
/// The number of calls in flight, which is also the number of keys being shared.
pub fn[T] Single::len(self : Single[T]) -> Int32 {
  self.inflight.length()
}

///|
/// Run `body` for `key`, or wait for the call already running for it.
///
/// The caller that runs the body is the one that answers everyone; a body that
/// raises answers them all with the same error, so a failing lookup is not
/// retried once per waiter.
pub async fn[T] Single::run(
  self : Single[T],
  key : String,
  body : async () -> T,
) -> T {
  match self.inflight.get(key) {
    Some(entry) => {
      while !entry.done {
        entry.cond.wait()
      }
      match entry.outcome {
        Some(Ok(value)) => value
        Some(Err(error)) => raise error
        None => abort("singleflight entry finished without an outcome")
      }
    }
    None => {
      let entry : Inflight[T] = {
        cond: @cond_var.Cond::Cond(),
        done: false,
        outcome: None,
      }
      self.inflight[key] = entry
      // The entry has to leave the table on every path, including a cancellation
      // of this task: a stale entry would make every later caller for the key wait
      // for an answer that is never coming.
      let outcome : Result[T, Error] = Ok(body()) catch { error => Err(error) }
      self.inflight.remove(key)
      entry.outcome = Some(outcome)
      entry.done = true
      entry.cond.broadcast()
      match outcome {
        Ok(value) => value
        Err(error) => raise error
      }
    }
  }
}
