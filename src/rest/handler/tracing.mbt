// Server-side tracing, as the OpenTelemetry ASGI layer the rest of the family
// already uses. The span, the sampling decision and the propagation headers are
// moontel's; what is here is the wiring a framework owes its users — the
// `ignore_paths` blacklist and the convenience `x-trace-id` header.

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
  tracer~ : @trace.Tracer = @telemetry.tracer(),
  now~ : () -> Int64 = @telemetry.trace_clock(),
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
