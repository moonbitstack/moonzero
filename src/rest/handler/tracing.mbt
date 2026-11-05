// Server-side tracing, as the OpenTelemetry ASGI layer the rest of the family
// already uses. The span, the sampling decision and the propagation headers are
// moontel's; what is here is the wiring a framework owes its users — a tracer
// that works without being configured, the `ignore_paths` blacklist, and the
// convenience `x-trace-id` header.

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

///|
/// The `traceparent` header name a trace id is read out of.
let traceparent_header : String = "traceparent"

///|
/// The trace id carried by a W3C `traceparent` value,
/// `00-<32 hex trace-id>-<16 hex span-id>-<2 hex flags>`, or `None` when the
/// value is not one.
pub fn trace_id_of(traceparent : String) -> String? {
  let parts = traceparent.split("-").collect()
  guard parts.length() == 4 else { None }
  guard parts[1].length() == 32 else { None }
  Some(parts[1].to_owned())
}

///|
/// Add `x-trace-id` next to the `traceparent` a tracing layer already wrote, so
/// a client that only wants the id does not have to parse the standard header.
/// Headers that already carry the convenience name keep their value.
fn with_trace_id_header(
  headers : Array[(String, String)],
  header : String,
) -> Array[(String, String)] {
  for pair in headers {
    if pair.0 == header {
      return headers
    }
    if pair.0 == traceparent_header {
      match trace_id_of(pair.1) {
        Some(id) => return [(header, id), ..headers]
        None => ()
      }
    }
  }
  headers
}

///|
/// Tracing middleware: join the trace the request arrived on, or start one, and
/// open a server span that reaches `sink` when the request finishes. Paths in
/// `ignore_paths` are left untraced. The span and the propagation headers come
/// from moontel's ASGI layer; this adds the convenience `x-trace-id` response
/// header on top.
///
/// The defaults — a discarding sink, always sampling, ids from the platform
/// entropy source — make `tracing()` a working layer with nothing configured; a
/// service that wants spans kept hands in a tracer over its own sink.
pub fn tracing(
  tracer~ : @trace.Tracer = tracer(),
  now~ : () -> Int64 = trace_clock(),
  header~ : String = "x-trace-id",
  ignore_paths~ : Array[String] = [],
) -> Middleware {
  let layer = @moontel.Tracing::new(tracer~, now~, ignore=ignore_paths)
  inner => {
    let traced = layer.wrap(inner)
    (scope, receive, send) => {
      traced(scope, receive, event => {
        let event = match event {
          HttpResponseStart(status~, headers~, trailers~) =>
            @moonasgi.Event::HttpResponseStart(
              status~,
              headers=with_trace_id_header(headers, header),
              trailers~,
            )
          other => other
        }
        send(event)
      })
    }
  }
}
