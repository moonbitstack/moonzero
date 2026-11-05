// The five client interceptors, in the order the reference implementation chains
// them: tracing outermost, then the duration log, the Prometheus families, the
// breaker, and the timeout innermost.

///|
/// The tracing interceptor: open a client span for the call, run it as a child of
/// whatever context the caller carried, and record the resulting status code on
/// the span.
pub fn client_tracing(
  tracer : @trace.Tracer,
  now~ : () -> Int64 = @telemetry.trace_clock(),
) -> Interceptor {
  inner => {
    call => {
      let started = now()
      let span = start_client_span(tracer, call, started) catch {
        _ => return inner(call)
      }
      span.set_attribute("rpc.system", @trace.Str("grpc"))
      span.set_attribute("rpc.method", @trace.Str(call.path))
      let result = inner({
        path: call.path,
        request: call.request,
        parent: Some(span.context()),
      })
      match result {
        Ok(_) => span.set_status(@trace.Ok)
        Err(status) => {
          span.set_attribute(
            "rpc.grpc.status_code",
            @trace.Int(status_code(status).to_int64()),
          )
          span.set_status(@trace.Error(status_name(status)))
        }
      }
      span.finish(at=now())
      result
    }
  }
}

///|
/// Open the client span for `call`, as a child of the context the caller carried
/// when there is one.
fn start_client_span(
  tracer : @trace.Tracer,
  call : Call,
  at : Int64,
) -> @trace.Span raise {
  let name = "rpc " + call.name()
  match call.parent {
    Some(parent) => tracer.start(name, parent~, kind=Client, at~)
    None => tracer.start(name, kind=Client, at~)
  }
}

///|
/// The numeric `grpc-status` of a status, the value that goes on the wire.
pub fn status_code(status : @moonrpc.Status) -> Int32 {
  match status {
    Ok => 0
    Cancelled => 1
    Unknown => 2
    InvalidArgument => 3
    DeadlineExceeded => 4
    NotFound => 5
    AlreadyExists => 6
    PermissionDenied => 7
    ResourceExhausted => 8
    FailedPrecondition => 9
    Aborted => 10
    OutOfRange => 11
    Unimplemented => 12
    Internal => 13
    Unavailable => 14
    DataLoss => 15
    Unauthenticated => 16
  }
}

///|
/// The `grpc-status` name of a status, for a log line or a span attribute.
pub fn status_name(status : @moonrpc.Status) -> String {
  match status {
    Ok => "OK"
    Cancelled => "Cancelled"
    Unknown => "Unknown"
    InvalidArgument => "InvalidArgument"
    DeadlineExceeded => "DeadlineExceeded"
    NotFound => "NotFound"
    AlreadyExists => "AlreadyExists"
    PermissionDenied => "PermissionDenied"
    ResourceExhausted => "ResourceExhausted"
    FailedPrecondition => "FailedPrecondition"
    Aborted => "Aborted"
    OutOfRange => "OutOfRange"
    Unimplemented => "Unimplemented"
    Internal => "Internal"
    Unavailable => "Unavailable"
    DataLoss => "DataLoss"
    Unauthenticated => "Unauthenticated"
  }
}

///|
/// The duration interceptor: a failed call is logged at `error` with how long it
/// took, and a successful one slower than `slow_ms` is logged as a slow call. A
/// method listed in `mute` is logged without its request body, the way a login or
/// a payment call is.
pub fn client_duration(
  clock : @clock.Clock,
  logger? : @logx.Logger,
  slow_ms~ : Int64 = 500L,
  mute~ : Array[String] = [],
) -> Interceptor {
  let lg = logger.unwrap_or(@logx.logx)
  inner => {
    call => {
      let started = clock.now()
      let result = inner(call)
      let elapsed = clock.now() - started
      match result {
        Err(status) =>
          lg
          .with_duration(elapsed)
          .error(
            "fail - " +
            call.path +
            " - " +
            status_name(status) +
            mute_note(mute, call),
          )
        Ok(_) =>
          if elapsed > slow_ms {
            lg.with_duration(elapsed).info("[RPC] ok - slowcall - " + call.path)
          }
      }
      result
    }
  }
}

///|
/// The suffix a muted method's log line carries instead of the request size.
fn mute_note(mute : Array[String], call : Call) -> String {
  if mute.contains(call.path) {
    ""
  } else {
    " - " + call.request.length().to_string() + "B"
  }
}

///|
/// The Prometheus interceptor: time the call and count it under its method and
/// status code.
pub fn client_prometheus(
  metrics : RpcMetrics,
  clock : @clock.Clock,
) -> Interceptor {
  inner => {
    call => {
      let started = clock.now()
      let result = inner(call)
      let code = match result {
        Ok(_) => 0
        Err(status) => status_code(status)
      }
      metrics.observe(call.path, code, (clock.now() - started).to_double())
      result
    }
  }
}

///|
/// Whether a failure says something about the peer. A cancelled or expired call
/// says nothing about the backend, so it does not push the breaker towards open —
/// the same split the reference implementation draws.
pub fn acceptable(status : @moonrpc.Status) -> Bool {
  match status {
    Cancelled | DeadlineExceeded | Unavailable => false
    _ => true
  }
}

///|
/// The breaker interceptor: a call the throttle sheds never reaches the transport,
/// and answers `Unavailable`; a failure the peer caused is counted against it.
pub fn client_breaker(breaker : @breaker.Breaker) -> Interceptor {
  inner => {
    call => {
      guard breaker.allow() is Some(promise) else {
        return Err(@moonrpc.Status::Unavailable)
      }
      let result = inner(call)
      match result {
        Ok(_) => promise.accept()
        Err(status) =>
          if acceptable(status) {
            promise.reject()
          } else {
            promise.accept()
          }
      }
      result
    }
  }
}

///|
/// The timeout interceptor: a call that ran past `budget_ms` is reported as
/// `DeadlineExceeded`.
///
/// The deadline is checked when the call returns rather than enforced against a
/// timer: this transport runs the peer in the caller's own task, so there is no
/// frame to abandon. A socket-backed client hands the budget to the transport,
/// which does preempt; the decision this records is the same either way.
pub fn client_timeout(budget_ms : Int64, clock : @clock.Clock) -> Interceptor {
  guard budget_ms > 0L else { inner => inner }
  inner => {
    call => {
      let started = clock.now()
      let result = inner(call)
      if clock.now() - started > budget_ms {
        Err(@moonrpc.Status::DeadlineExceeded)
      } else {
        result
      }
    }
  }
}

///|
/// The client chain `conf` asks for, outermost first.
pub fn client_interceptors(
  conf : @conf.RpcClientMiddlewaresConf,
  deps : ClientDeps,
) -> Array[Interceptor] {
  let out : Array[Interceptor] = []
  if conf.trace {
    out.push(client_tracing(deps.tracer, now=deps.now))
  }
  if conf.log {
    out.push(client_duration(deps.clock, slow_ms=deps.slow_ms, mute=deps.mute))
  }
  if conf.prometheus {
    out.push(client_prometheus(deps.metrics, deps.clock))
  }
  if conf.breaker {
    out.push(client_breaker(deps.breaker))
  }
  if conf.timeout && deps.timeout_ms > 0L {
    out.push(client_timeout(deps.timeout_ms, deps.clock))
  }
  out
}

///|
/// Everything the client chain needs that is not a flag: the seam values a
/// framework injects rather than looks up.
pub(all) struct ClientDeps {
  clock : @clock.Clock
  tracer : @trace.Tracer
  breaker : @breaker.Breaker
  metrics : RpcMetrics
  now : () -> Int64
  timeout_ms : Int64
  slow_ms : Int64
  mute : Array[String]
}

///|
/// The dependencies for a client config, with every seam at its default: a system
/// clock, a discarding tracer, a fresh breaker and a fresh metric registry.
pub fn ClientDeps::new(
  clock~ : @clock.Clock = @clock.Clock::system(),
  tracer? : @trace.Tracer,
  breaker? : @breaker.Breaker,
  metrics? : RpcMetrics,
  now? : () -> Int64,
  timeout_ms~ : Int64 = 2000L,
  slow_ms~ : Int64 = 500L,
  mute~ : Array[String] = [],
) -> ClientDeps raise @metric.Refused {
  let clock = clock
  {
    clock,
    tracer: match tracer {
      Some(tracer) => tracer
      None => @telemetry.tracer()
    },
    breaker: match breaker {
      Some(breaker) => breaker
      None => @breaker.Breaker::new(clock)
    },
    metrics: match metrics {
      Some(metrics) => metrics
      None => RpcMetrics::new(kind="client")
    },
    now: match now {
      Some(now) => now
      None => () => clock.now() * 1_000_000L
    },
    timeout_ms,
    slow_ms,
    mute,
  }
}
