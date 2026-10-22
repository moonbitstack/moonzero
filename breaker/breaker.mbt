// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Google SRE's client-side throttling breaker (← go-zero's `googleBreaker`).
///
/// The algorithm is moonward's `Breaker`; this binds it to a `Clock` and a
/// source of draws, the shape go-zero's breaker has, so a call site asks with
/// no arguments. go-zero's constants are moonward's preset `sre`.
pub struct Breaker {
  core : @moonward.Breaker
  clock : @clock.Clock
  roll : () -> Double
}

///|
/// A breaker over a `buckets` × `bucket_ms` window (go-zero's ten seconds in
/// forty slices by default) reading time from `clock`. `rand` supplies the shed
/// roll as a draw from `[0, 1)`; without it the breaker draws from a
/// system-seeded generator.
pub fn Breaker::new(
  clock : @clock.Clock,
  rand? : () -> Double,
  buckets~ : Int32 = 40,
  bucket_ms~ : Int64 = 250L,
) -> Breaker {
  let roll = match rand {
    Some(f) => f
    None => {
      let src = @random.Rand()
      () => src.double()
    }
  }
  let sre = {
    ..@moonward.sre,
    size: buckets,
    window: @moondate.Span::new(millis=bucket_ms * buckets.to_int64()),
  }
  { core: @moonward.Breaker::new(sre~, now=nanos(clock)), clock, roll, }
}

///|
fn nanos(clock : @clock.Clock) -> Int64 {
  clock.now() * 1_000_000L
}

///|
/// The fraction of new calls the breaker is shedding now, zero while healthy.
pub fn Breaker::drop_ratio(self : Breaker) -> Double {
  self.core.ratio(nanos(self.clock))
}

///|
/// Ask to make one call. `Some` promise means it may proceed and the caller
/// settles the promise when it finishes; `None` means the throttle shed it.
pub fn Breaker::allow(self : Breaker) -> Promise? {
  self.core
  .allow(nanos(self.clock), (self.roll)())
  .map(inner => { inner, clock: self.clock, })
}

///|
/// The receipt for an admitted call (← go-zero's `breaker.Promise`).
pub struct Promise {
  inner : @moonward.Promise
  clock : @clock.Clock
}

///|
pub fn Promise::accept(self : Promise) -> Unit {
  self.inner.pass(nanos(self.clock))
}

///|
pub fn Promise::reject(self : Promise) -> Unit {
  self.inner.fail(nanos(self.clock))
}

///|
/// Raised by `Breaker::run` for a call the throttle shed (← go-zero's
/// `ErrServiceUnavailable`).
pub suberror Unavailable

///|
/// Run `req` under the breaker (← go-zero's `Breaker.Do`): a shed call raises
/// `Unavailable` and `req` never runs; a raise from `req` counts as a failure.
pub fn[T] Breaker::run(self : Breaker, req : () -> T raise) -> T raise {
  guard self.allow() is Some(p) else { raise Unavailable }
  errdefer p.reject()
  let out = req()
  p.accept()
  out
}
