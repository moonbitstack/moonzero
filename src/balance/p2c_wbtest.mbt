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
