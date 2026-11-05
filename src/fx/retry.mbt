///|
/// Call `body` until it stops raising, at most `attempts` times, and report the last
/// failure when every attempt raised.
///
/// `fatal` stops the ladder early for a failure that will not change — a malformed
/// request is not worth three attempts — and by default nothing is fatal.
pub fn[A] retry(
  body : () -> A raise,
  attempts~ : Int32 = 3,
  fatal~ : (Error) -> Bool = _error => false,
) -> A raise {
  let limit = if attempts < 1 { 1 } else { attempts }
  let mut left = limit
  while true {
    let outcome : Result[A, Error] = Ok(body()) catch { error => Err(error) }
    match outcome {
      Ok(value) => return value
      Err(error) => {
        left = left - 1
        if left <= 0 || fatal(error) {
          raise error
        }
      }
    }
  }
  abort("unreachable: retry returns or raises")
}

///|
/// `retry` with a backoff between attempts: `backoff` decides how long to wait, and
/// the nth wait is its nth delay. An attempt that raised the last time waits before
/// the next one, so the first call is never delayed.
pub async fn[A] retry_with_backoff(
  body : async () -> A,
  backoff~ : @moonward.Backoff = @moonward.backoff,
  fatal~ : (Error) -> Bool = _error => false,
) -> A {
  let delays = backoff.schedule()
  let mut at = 0
  while true {
    let outcome : Result[A, Error] = Ok(body()) catch { error => Err(error) }
    match outcome {
      Ok(value) => return value
      Err(error) => {
        if at >= delays.length() || fatal(error) {
          raise error
        }
        @async.sleep(delays[at].nanos.to_int())
        at = at + 1
      }
    }
  }
  abort("unreachable: retry_with_backoff returns or raises")
}
