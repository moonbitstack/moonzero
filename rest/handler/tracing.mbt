///|
/// Trace-id propagation middleware (← go-zero's `trace` handler): continue the
/// inbound `traceparent` trace or start a new one, mint a child span, and stamp
/// both `traceparent` and a convenience `x-trace-id` onto the response so the id
/// flows to the client and downstream calls. The per-assembly seed counter keeps
/// span ids distinct across the requests this layer serves. Requests whose path
/// is listed in `ignore_paths` are left untraced (← `WithTraceIgnorePaths`, the
/// blacklist that keeps health checks out of the trace store), as are non-HTTP
/// scopes.
pub fn tracing(
  header~ : String = "x-trace-id",
  ignore_paths~ : Array[String] = [],
) -> Middleware {
  let counter : Ref[Int64] = { val: 0L, }
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(hs) if !ignore_paths.contains(hs.path) => {
          counter.val = counter.val + 1L
          let inbound = scope_header(scope, "traceparent")
          let ctx = @trace.next_trace_context(inbound, counter.val)
          let wrapped : @moonasgi.Send = event => {
            match event {
              HttpResponseStart(status~, headers~, trailers~) =>
                send(
                  @moonasgi.Event::HttpResponseStart(
                    status~,
                    headers=[
                      (header, ctx.trace_id),
                      ("traceparent", ctx.to_traceparent()),
                      ..headers,
                    ],
                    trailers~,
                  ),
                )
              other => send(other)
            }
          }
          inner(scope, receive, wrapped)
        }
        _ => inner(scope, receive, send)
      }
    }
  }
}
