// The two benches of the lab page.
//
// Three instances answer in a, b and c milliseconds; the picker sends every call to
// two of them drawn at random and takes the lighter, and each finished call moves
// the numbers that load is computed from. The bucket admits `rate` a second with
// room for `burst` back to back. Both numbers the page draws come back from here.

///|
/// The instance a pick refers to, as an index: the endpoint carries its own port, so
/// the demo does not need a map from name to slot.
fn slot_of(endpoint : @moonsd.Endpoint) -> Int32 {
  endpoint.port - 12001
}

///|
/// The three instances, one port each, so a pick names its own slot.
let instances : Array[@moonsd.Endpoint] = [
  @moonsd.Endpoint::new("a", 12001),
  @moonsd.Endpoint::new("b", 12002),
  @moonsd.Endpoint::new("c", 12003),
]

///|
/// Picks per instance in the last run, and each instance's load at the end of it.
let picks : Array[Int32] = [0, 0, 0]

///|
/// Loads, in the picker's own units, for the readout under the bars.
let loads : Array[Int32] = [0, 0, 0]

///|
/// Run `calls` calls against three instances answering in `lat_a`, `lat_b` and
/// `lat_c` milliseconds, on a clock this function advances by the latency of each
/// call it places.
///
/// The generator is seeded from the four numbers, so the same sliders always draw
/// the same sequence — a page that reran with a fresh random seed on every input
/// event would look alive and show nothing.
pub fn mz_lab_p2c(
  lat_a : Int32,
  lat_b : Int32,
  lat_c : Int32,
  calls : Int32,
) -> Unit {
  let latencies : Array[Int32] = [lat_a, lat_b, lat_c]
  for i in 0..<3 {
    picks[i] = 0
    loads[i] = 0
  }
  let clock = @clock.ManualClock::new()
  let time = clock.as_clock()
  let seed = lat_a.reinterpret_as_uint() * 7919 +
    lat_b.reinterpret_as_uint() * 104_729 +
    lat_c.reinterpret_as_uint() * 1_299_709 +
    calls.reinterpret_as_uint() * 15_485_863 +
    1
  let state : Ref[UInt32] = { val: seed, }
  let random : (Int32) -> Int32 = n => {
    state.val = state.val * 1_103_515_245 + 12_345
    ((state.val >> 16) & 0x7FFF).reinterpret_as_int() % n
  }
  let picker = @balance.P2c::new(clock=time, random~)
  for _ in 0..<calls {
    match picker.pick(instances) {
      Some(endpoint) => {
        let slot = slot_of(endpoint)
        let started = time.now()
        clock.advance(latencies[slot].to_int64())
        picker.done(endpoint, started, true)
        picks[slot] = picks[slot] + 1
      }
      None => ()
    }
  }
  for i in 0..<3 {
    let (load, _, _) = picker.stats(instances[i])
    loads[i] = load.to_int()
  }
}

///|
/// How many calls the picker sent to instance `slot` in the last run.
pub fn mz_lab_p2c_picks(slot : Int32) -> Int32 {
  if slot < 0 || slot > 2 {
    0
  } else {
    picks[slot]
  }
}

///|
/// The load the picker ended the run with for instance `slot`.
pub fn mz_lab_p2c_load(slot : Int32) -> Int32 {
  if slot < 0 || slot > 2 {
    0
  } else {
    loads[slot]
  }
}

///|
/// What the bucket turned away in the last run.
let refused : Ref[Int32] = { val: 0, }

///|
/// Offer `demand` requests a second for five seconds to a bucket admitting `rate` a
/// second with room for `burst` at once, and answer how many got through.
///
/// Requests arrive on ten-millisecond ticks, which is the resolution the bucket's
/// own clock has; the count the function is asked for is kept as a fraction and
/// carried, so a demand of 80 a second is eight requests every hundred milliseconds
/// rather than a rounded burst once a second.
pub fn mz_lab_bucket(rate : Int32, burst : Int32, demand : Int32) -> Int32 {
  let bucket = @limit.TokenBucket::new(
    rate.to_double(),
    burst=burst.to_double(),
    now=0L,
  )
  let per_tick = demand.to_double() / 100.0
  let mut carry = 0.0
  let mut now = 0L
  let mut admitted = 0
  let mut turned_away = 0
  for _ in 0..<500 {
    now = now + 10L
    carry = carry + per_tick
    while carry >= 1.0 {
      carry = carry - 1.0
      if bucket.allow(now) {
        admitted = admitted + 1
      } else {
        turned_away = turned_away + 1
      }
    }
  }
  refused.val = turned_away
  admitted
}

///|
/// How many of the offered requests the last run turned away.
pub fn mz_lab_bucket_refused() -> Int32 {
  refused.val
}
