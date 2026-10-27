// Bounding the number of concurrent in-flight requests (← go-zero's `MaxConns` /
// `handler.MaxConnsHandler`): a semaphore of `max` permits. Each admitted HTTP request holds a
// permit for its whole duration and returns it when it finishes; a request that finds no permit
// free is answered `503 Service Unavailable` without reaching the app. This caps the work in flight
// so a burst of connections cannot exhaust the server, complementing the rate limiter (which bounds
// the arrival rate) and the breaker (which sheds on downstream failure).

///|
/// A permit pool of `max` concurrent slots (← go-zero's `syncx.Limit`), moonward's
/// `Gate` under go-zero's names. A `max` of zero or less admits everything, as
/// go-zero's server does when `MaxConns` is unset.
pub struct MaxConns {
  gate : @moonward.Gate
}

///|
/// A pool admitting at most `max` requests at once.
pub fn MaxConns::new(max : Int32) -> MaxConns {
  { gate: @moonward.Gate::new(max), }
}

///|
/// Take a permit if one is free (`TryBorrow`), returning whether it was taken.
pub fn MaxConns::try_acquire(self : MaxConns) -> Bool {
  self.gate.enter()
}

///|
/// Return a permit taken by `try_acquire` (`Return`).
pub fn MaxConns::release(self : MaxConns) -> Unit {
  self.gate.leave()
}

///|
/// The number of requests currently holding a permit.
pub fn MaxConns::in_flight(self : MaxConns) -> Int32 {
  self.gate.held()
}
