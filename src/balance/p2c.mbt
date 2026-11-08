// Power-of-two-choices with exponentially weighted moving averages: pick two
// instances at random, take the less loaded one, and let every finished call move
// the two numbers the load is computed from.
//
// The load of a node is `sqrt(lag + 1) * (inflight + 1)`, where `lag` is the
// request latency in milliseconds under an EWMA that decays with a ten-second time
// constant, and `inflight` is how many calls have not finished. A node's
// `success` count decays the same way and starts at a thousand; below half of that
// it is treated as unhealthy and skipped in favour of another pair. A node that has
// not been picked for a second is forced — otherwise one slow node would be
// avoided forever and never be seen to recover.

///|
/// The constants the picker runs on. The defaults are the reference
/// implementation's: a ten-second decay, a one-second forced pick, a thousand
/// starting successes, and three attempts at finding a healthy pair.
pub(all) struct P2cConf {
  decay_ms : Int64
  force_pick_ms : Int64
  init_success : Double
  pick_times : Int32
}

///|
/// The defaults.
pub let p2c_default : P2cConf = {
  decay_ms: 10_000L,
  force_pick_ms: 1_000L,
  init_success: 1000.0,
  pick_times: 3,
}

///|
/// The load a node reports when its computed one is zero: the largest 32-bit value,
/// so it loses every comparison. Named rather than written where it is used because
/// it is a decision, not an arithmetic detail.
pub let p2c_penalty : Int64 = 0x7FFFFFFFL

///|
/// One instance's numbers.
pub struct P2cNode {
  mut lag : Double
  mut success : Double
  mut inflight : Int64
  mut requests : Int64
  mut last : Int64
  mut pick : Int64
}

///|
/// The picker: one `P2cNode` per instance, keyed by `Endpoint::id`.
pub struct P2c {
  conf : P2cConf
  clock : @clock.Clock
  nodes : Map[String, P2cNode]
  random : (Int32) -> Int32
}

///|
/// A picker on `clock`. `random` answers an index in `[0, n)` and defaults to a
/// counter-mixed generator, so a replay with a fixed clock and a fixed generator
/// makes exactly the decisions the reference implementation makes.
pub fn P2c::new(
  clock~ : @clock.Clock = @clock.Clock::system(),
  conf~ : P2cConf = p2c_default,
  random? : (Int32) -> Int32,
) -> P2c {
  // A 64-bit linear congruential generator, mixed down to the width an index
  // needs. It is not cryptographic and does not need to be: two instances are drawn
  // to compare, not to defend anything.
  let state : Ref[UInt64] = { val: 0x9E3779B97F4A7C15UL, }
  let generated : (Int32) -> Int32 = n => {
    state.val = state.val * 6364136223846793005UL + 1442695040888963407UL
    let mixed = state.val ^ (state.val >> 33)
    (mixed.reinterpret_as_int64().to_int() & 0x7FFFFFFF) % n
  }
  {
    conf,
    clock,
    nodes: Map([]),
    random: match random {
      Some(random) => random
      None => generated
    },
  }
}

///|
/// The node for `endpoint`, created at its initial success count on first sight.
fn P2c::node(self : P2c, endpoint : @moonsd.Endpoint, now : Int64) -> P2cNode {
  match self.nodes.get(endpoint.id) {
    Some(node) => node
    None => {
      let node : P2cNode = {
        lag: 0.0,
        success: self.conf.init_success,
        inflight: 0,
        requests: 0,
        last: now,
        pick: 0L,
      }
      self.nodes[endpoint.id] = node
      node
    }
  }
}

///|
/// An index in `[0, n)`, from the injected generator.
fn P2c::below(self : P2c, n : Int32) -> Int32 {
  if n <= 1 {
    return 0
  }
  let drawn = (self.random)(n)
  if drawn < 0 || drawn >= n {
    drawn % n
  } else {
    drawn
  }
}

///|
/// Whether the node is above the throttling line: fewer than half its starting
/// successes means recent calls failed.
fn P2cNode::healthy(self : P2cNode, conf : P2cConf) -> Bool {
  self.success > conf.init_success / 2.0
}

///|
/// The node's load: the square root of its lag, truncated to a whole number, times
/// its in-flight count plus one.
///
/// The truncation is part of the algorithm, not a shortcut: two nodes whose
/// square roots differ by less than one are a tie, and the first of the pair wins.
/// The lag is kept in milliseconds here and in nanoseconds in the reference
/// implementation, so the scale is applied inside the square root — with the `+ 1`
/// under it, a one-millisecond lag is a thousand-fold difference in nanoseconds and
/// one-and-a-half-fold in milliseconds, and the two units would choose different
/// nodes for the same pair.
fn P2cNode::load(self : P2cNode) -> Int64 {
  let lag = sqrt(self.lag * 1_000_000.0 + 1.0).to_int64()
  let load = lag * (self.inflight + 1)
  if load == 0 {
    // Never reached with a non-negative in-flight count; kept because the
    // reference keeps it, and a zero load would otherwise win every comparison.
    p2c_penalty
  } else {
    load
  }
}

///|
/// The square root of a non-negative number, by Newton's iteration.
///
/// The standard library ships `exp` and the trigonometric functions but no square
/// root for `Double`, and rounding a load to an integer to avoid one would change
/// which of two instances is chosen.
pub fn sqrt(x : Double) -> Double {
  guard x > 0.0 else { return 0.0 }
  let mut guess = x
  let mut left = 24
  while left > 0 {
    guess = (guess + x / guess) / 2.0
    left = left - 1
  }
  guess
}

///|
/// Pick an instance, or `None` when there is nothing to pick. The chosen node's
/// in-flight count goes up, and `done` is what brings it back down.
pub fn P2c::pick(
  self : P2c,
  endpoints : Array[@moonsd.Endpoint],
) -> @moonsd.Endpoint? {
  let now = self.clock.now()
  let chosen = match endpoints.length() {
    0 => return None
    1 => {
      let node = self.node(endpoints[0], now)
      self.choose_one(node, endpoints[0], now)
    }
    2 => {
      let first = self.node(endpoints[0], now)
      let second = self.node(endpoints[1], now)
      self.choose_pair(first, endpoints[0], second, endpoints[1], now)
    }
    _ => {
      let mut a = 0
      let mut b = 1
      let mut attempts = self.conf.pick_times
      while attempts > 0 {
        a = self.below(endpoints.length())
        b = self.below(endpoints.length() - 1)
        if b >= a {
          b = b + 1
        }
        let node_a = self.node(endpoints[a], now)
        let node_b = self.node(endpoints[b], now)
        if node_a.healthy(self.conf) && node_b.healthy(self.conf) {
          attempts = 0
        } else {
          attempts = attempts - 1
        }
      }
      let first = self.node(endpoints[a], now)
      let second = self.node(endpoints[b], now)
      self.choose_pair(first, endpoints[a], second, endpoints[b], now)
    }
  }
  let id = chosen.id
  let node = self.nodes.get(id).unwrap()
  node.inflight = node.inflight + 1
  node.requests = node.requests + 1
  Some(chosen)
}

///|
/// Choose the only node there is, and stamp its pick time.
fn P2c::choose_one(
  self : P2c,
  node : P2cNode,
  endpoint : @moonsd.Endpoint,
  now : Int64,
) -> @moonsd.Endpoint {
  let _ = self
  node.pick = now
  endpoint
}

///|
/// Choose the less loaded of two nodes. A node that has not been picked for longer
/// than `force_pick_ms` wins regardless, so a struggling instance is not avoided
/// out of the pool forever.
fn P2c::choose_pair(
  self : P2c,
  first : P2cNode,
  first_endpoint : @moonsd.Endpoint,
  second : P2cNode,
  second_endpoint : @moonsd.Endpoint,
  now : Int64,
) -> @moonsd.Endpoint {
  let (low, low_endpoint, high, high_endpoint) = if first.load() > second.load() {
    (second, second_endpoint, first, first_endpoint)
  } else {
    (first, first_endpoint, second, second_endpoint)
  }
  if now - high.pick > self.conf.force_pick_ms {
    high.pick = now
    return high_endpoint
  }
  low.pick = now
  low_endpoint
}

///|
/// Record a finished call on `endpoint`: its in-flight count comes back down, and
/// its lag and success count move towards this call by the weight the time since
/// the previous update earns.
pub fn P2c::done(
  self : P2c,
  endpoint : @moonsd.Endpoint,
  started_ms : Int64,
  ok : Bool,
) -> Unit {
  let now = self.clock.now()
  let node = self.node(endpoint, now)
  node.inflight = if node.inflight > 0 { node.inflight - 1 } else { 0 }
  let previous = node.last
  node.last = now
  let mut td = now - previous
  if td < 0L {
    td = 0L
  }
  // As the time since the previous update grows, this call's weight in the moving
  // average shrinks; with no history at all it replaces the average outright.
  let mut weight = @math.exp(-td.to_double() / self.conf.decay_ms.to_double())
  let mut lag = now - started_ms
  if lag < 0L {
    lag = 0L
  }
  if node.lag == 0.0 {
    weight = 0.0
  }
  node.lag = node.lag * weight + lag.to_double() * (1.0 - weight)
  let success = if ok { self.conf.init_success } else { 0.0 }
  node.success = node.success * weight + success * (1.0 - weight)
}

///|
/// The node's numbers, for a test or a status endpoint.
pub fn P2c::stats(
  self : P2c,
  endpoint : @moonsd.Endpoint,
) -> (Int64, Int64, Int64) {
  match self.nodes.get(endpoint.id) {
    Some(node) => (node.load(), node.inflight, node.requests)
    None => (0L, 0L, 0L)
  }
}
