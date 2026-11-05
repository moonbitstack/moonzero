///|
/// A clock a test advances by hand.
fn ticker() -> (@clock.ManualClock, @clock.Clock) {
  let manual = @clock.ManualClock::new(start=1_000_000L)
  (manual, manual.as_clock())
}

///|
fn node(id : String) -> @moonsd.Endpoint {
  @moonsd.Endpoint::new("10.0.0.1", 9090, id~)
}

///|
fn three_nodes() -> Array[@moonsd.Endpoint] {
  [
    @moonsd.Endpoint::new("10.0.0.1", 9090, id="a"),
    @moonsd.Endpoint::new("10.0.0.2", 9090, id="b"),
    @moonsd.Endpoint::new("10.0.0.3", 9090, id="c"),
  ]
}

///|
test "p2c keeps in-flight counts and hands them back on done" {
  let (manual, clock) = ticker()
  let endpoints = three_nodes()
  let picker = P2c::new(clock~, random=fn(_n) { 0 })
  let chosen = picker.pick(endpoints).unwrap()
  assert_eq(picker.stats(chosen).1, 1L)
  manual.advance(10L)
  picker.done(chosen, clock.now(), true)
  assert_eq(picker.stats(chosen).1, 0L)
  assert_eq(picker.stats(chosen).2, 1L)
}

///|
/// Pick twice so both of the pair the fixed generator draws have a pick time of
/// now: the first call stamps the second, the second call stamps the first.
///
/// Each pick is completed as well, so the in-flight counts are back at zero and the
/// load comparison is about latency alone.
fn stamp(picker : P2c, endpoints : Array[@moonsd.Endpoint]) -> Unit {
  let mut turns = 2
  while turns > 0 {
    let picked = picker.pick(endpoints).unwrap()
    picker.done(picked, picker.clock.now(), true)
    turns = turns - 1
  }
}

///|
/// A picker whose force window is long enough that load decides.
fn patient_picker(clock : @clock.Clock) -> P2c {
  P2c::new(clock~, conf={ ..p2c_default, force_pick_ms: 100_000L, }, random=fn(
    _n,
  ) {
    0
  })
}

///|
test "p2c avoids the slower of the two it compared" {
  let (manual, clock) = ticker()
  let endpoints = three_nodes()
  let picker = patient_picker(clock)
  stamp(picker, endpoints)
  manual.advance(2_000L)
  // A 500ms call on the second instance, recorded ten seconds after it was first
  // seen so the moving average has nothing to blend the first sample with.
  picker.done(endpoints[1], clock.now() - 500L, true)
  let chosen = picker.pick(endpoints).unwrap()
  assert_eq(chosen.id, "a")
  let (slow, _, _) = picker.stats(endpoints[1])
  let (fast, _, _) = picker.stats(endpoints[0])
  assert_eq(slow > fast, true)
}

///|
test "p2c forces an instance nobody has picked for a second" {
  let (manual, clock) = ticker()
  let endpoints = three_nodes()
  let picker = P2c::new(clock~, random=fn(_n) { 0 })
  stamp(picker, endpoints)
  manual.advance(2_000L)
  picker.done(endpoints[1], clock.now() - 500L, true)
  // The loaded instance is the one that has not been picked for longer than the
  // force window, so it is drawn again rather than starved.
  let chosen = picker.pick(endpoints).unwrap()
  assert_eq(chosen.id, "b")
}

///|
test "p2c treats a failed call as a load penalty" {
  let (manual, clock) = ticker()
  let endpoints = three_nodes()
  let picker = patient_picker(clock)
  stamp(picker, endpoints)
  manual.advance(2_000L)
  picker.done(endpoints[1], clock.now(), false)
  let chosen = picker.pick(endpoints).unwrap()
  assert_eq(chosen.id, "a")
}

///|
test "p2c with one instance answers that instance" {
  let (_, clock) = ticker()
  let picker = P2c::new(clock~)
  let endpoints = [node("only")]
  assert_eq(picker.pick(endpoints).unwrap().id, "only")
  assert_eq(picker.pick([]) is None, true)
}

///|
test "sqrt agrees with the squares it is checked against" {
  for pair in [(1.0, 1.0), (4.0, 2.0), (100.0, 10.0), (2.0, 1.4142135623730951)] {
    let got = sqrt(pair.0)
    assert_eq((got - pair.1).abs() < 0.000000000001, true)
  }
  assert_eq(sqrt(0.0), 0.0)
}

///|
test "the balancer routes p2c picks and reports through the picker" {
  let (_, clock) = ticker()
  let endpoints = three_nodes()
  let balancer = Balancer::p2c(clock~, conf={ ..p2c_default, pick_times: 1, })
  let chosen = balancer.pick(endpoints).unwrap()
  balancer.report(chosen, clock.now(), true)
  // A round-robin balancer has nothing to report, and says so by doing nothing.
  let round = Balancer::round_robin()
  round.report(chosen, clock.now(), false)
  assert_eq(round.pick(endpoints) is Some(_), true)
}

///|
/// Drive `calls` picks through `picker` and report how often each instance was
/// chosen.
///
/// A call starts at the clock's now and finishes after the clock has moved on by
/// that instance's latency, which is the shape a real client has: the load the
/// picker compares on is the time the call actually took, not a number handed to
/// it.
fn drive(
  picker : P2c,
  clock : @clock.Clock,
  manual : @clock.ManualClock,
  endpoints : Array[@moonsd.Endpoint],
  calls : Int32,
  latency_of : (String) -> Int64,
) -> Map[String, Int32] {
  let counts : Map[String, Int32] = Map([])
  let mut left = calls
  while left > 0 {
    let started = clock.now()
    let chosen = picker.pick(endpoints).unwrap()
    manual.advance(latency_of(chosen.id))
    picker.done(chosen, started, true)
    counts[chosen.id] = counts.get(chosen.id).unwrap_or(0) + 1
    left = left - 1
  }
  counts
}

///|
test "p2c keeps a slow instance out of the rotation" {
  let (manual, clock) = ticker()
  let picker = P2c::new(clock~)
  let endpoints = three_nodes()
  // One instance answers in 200ms, the other two in 2ms. Three hundred calls is
  // under a second of simulated time, so the force window never fires and every
  // pick here is the load comparison's.
  let counts = drive(picker, clock, manual, endpoints, 300, id => {
    if id == "c" {
      200L
    } else {
      2L
    }
  })
  let slow = counts.get("c").unwrap_or(0)
  // Measured: 143 / 156 / 1. The threshold is the property, the numbers are the
  // evidence that the property is not accidental.
  assert_eq(slow <= 10, true)
  assert_eq(counts.get("a").unwrap_or(0) >= 100, true)
  assert_eq(counts.get("b").unwrap_or(0) >= 100, true)
  let (slow_load, _, _) = picker.stats(endpoints[2])
  let (fast_load, _, _) = picker.stats(endpoints[0])
  assert_eq(slow_load > fast_load * 4L, true)
}

///|
test "p2c still probes an instance it has been avoiding" {
  let (manual, clock) = ticker()
  let picker = P2c::new(clock~)
  let endpoints = three_nodes()
  // The same three instances over three thousand calls — about six seconds of
  // simulated time, so the one-second force window fires several times.
  let counts = drive(picker, clock, manual, endpoints, 3_000, id => {
    if id == "c" {
      200L
    } else {
      2L
    }
  })
  let slow = counts.get("c").unwrap_or(0)
  // Measured: 1453 / 1539 / 8 — roughly one probe per second, which is what keeps a
  // struggling instance from being avoided out of the pool forever.
  assert_eq(slow > 0, true)
  assert_eq(slow <= 40, true)
}

///|
test "p2c keeps the in-flight factor for a call that has not finished" {
  let (manual, clock) = ticker()
  // The fixed generator draws the same pair every time: the first two instances.
  let picker = P2c::new(clock~, random=fn(_n) { 0 })
  let endpoints = three_nodes()
  // Neither has ever been picked, so the force window takes the second one first.
  let first = picker.pick(endpoints).unwrap()
  assert_eq(first.id, "b")
  assert_eq(picker.stats(first).1, 1L)
  // Now the pair's loads are one against two, because the first pick is still in
  // flight: the other instance wins before any latency has been reported at all.
  let second = picker.pick(endpoints).unwrap()
  assert_eq(second.id, "a")
  assert_eq(picker.stats(second).1, 1L)
  // A finished call takes its count back down.
  manual.advance(5L)
  picker.done(first, clock.now() - 5L, true)
  assert_eq(picker.stats(first).1, 0L)
}
