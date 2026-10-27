// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Load shedding under pressure (← go-zero's `load.AdaptiveShedder`, wired from
/// `RestConf.CpuThreshold`).
///
/// A request is refused only when the server is hot, its CPU at or over
/// `threshold` per-mille or recently so, and full, with more requests in flight
/// than it has shown it can finish. The algorithm is moonward's `Shedder`; this
/// binds it to a `Clock` and to `usage`, the CPU meter. Without a meter usage
/// reads zero and nothing is shed, since no MoonBit backend can read one alone.
pub struct Shedder {
  core : @moonward.Shedder
  clock : @clock.Clock
  usage : () -> Int64
}

///|
pub fn Shedder::new(
  clock : @clock.Clock,
  threshold~ : Int64 = 900L,
  usage? : () -> Int64,
) -> Shedder {
  let shed = { ..@moonward.shed, cpu: threshold.to_int(), }
  {
    core: @moonward.Shedder::new(shed~, now=clock.now() * 1_000_000L),
    clock,
    usage: usage.unwrap_or(() => 0L),
  }
}

///|
/// Ask to admit one request. `Some` ticket means go ahead, and the caller
/// settles it when the request finishes; `None` means shed it.
pub fn Shedder::allow(self : Shedder) -> Ticket? {
  self.core
  .allow(self.clock.now() * 1_000_000L, (self.usage)().to_int())
  .map(inner => { inner, clock: self.clock, })
}

///|
/// The CPU usage the shedder is reading, per mille.
pub fn Shedder::usage(self : Shedder) -> Int64 {
  (self.usage)()
}

///|
/// An admitted request (← go-zero's `load.Promise`).
pub struct Ticket {
  inner : @moonward.Ticket
  clock : @clock.Clock
}

///|
/// The request succeeded; its duration counts towards the server's capacity.
pub fn Ticket::pass(self : Ticket) -> Unit {
  self.inner.pass(self.clock.now() * 1_000_000L)
}

///|
pub fn Ticket::fail(self : Ticket) -> Unit {
  self.inner.fail()
}
