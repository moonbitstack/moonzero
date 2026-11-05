// The tracer a moonzero service runs on when nobody configured one.
//
// Ids come from the platform entropy source, spans go to a sink the caller names,
// and every request is sampled: the defaults a service needs to be instrumented
// before anyone has thought about instrumenting it.

///|
/// Entropy for trace and span ids: an `n`-octet slice of the platform entropy
/// source. The fallback inside `tracer` covers a refused source.
pub fn trace_random(n : Int32) -> Bytes raise @moonseed.Unavailable {
  @moonseed.bytes(n, @system.source)
}

///|
/// `trace_random`, as the shape `@trace.Tracer` takes: `n` fresh random octets, or
/// the fallback when the platform source refuses.
fn trace_random_fallback(n : Int32) -> Bytes {
  trace_random(n) catch {
    _ => deterministic_bytes(n)
  }
}

///|
/// A counter-mixed stand-in for real entropy, used only when the platform source
/// is unavailable. Ids stay unique within the process and look random; they are
/// not unpredictable, which is why they are the fallback.
fn deterministic_bytes(n : Int32) -> Bytes {
  let buf = Buffer()
  let mut state = 0x2545F4914F6CDD1DUL
  while buf.length() < n {
    state = state ^ (state << 13) ^ (state >> 7)
    state = state ^ (state << 17)
    let octet = (state >> 56).reinterpret_as_int64().to_int() & 0xFF
    buf.write_byte(octet.to_byte())
  }
  buf.to_bytes()
}

///|
/// A tracer over `sink` and `sampler`, drawing ids from the platform entropy
/// source.
pub fn tracer(
  sink~ : &@moontel.Sink = @moontel.discard,
  sampler~ : &@moontel.Sampler = @moontel.always,
  limits~ : @moontel.Limits = @moontel.trace_limits,
) -> @trace.Tracer {
  @trace.Tracer::new(rand=trace_random_fallback, sink~, sampler~, limits~)
}

///|
/// The clock the tracer is driven by, in nanoseconds: the platform millisecond
/// clock scaled up, which is the resolution every span in this framework is
/// measured at anyway.
pub fn trace_clock() -> () -> Int64 {
  let clock = @clock.Clock::system()
  () => clock.now() * 1_000_000L
}
