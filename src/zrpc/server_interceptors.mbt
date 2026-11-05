// The eight server interceptors: tracing, recovery, the stat log, the Prometheus
// families, the breaker, load shedding, the deadline and authentication — the
// same eight the reference implementation installs, minus the internal stat sink
// that the Prometheus families replace.

///|
/// What a peer must prove before its call runs. The framework owns the seam and
/// not the scheme: a token check over redis, a signed request, an mTLS peer
/// identity — each is an implementation of this trait, so the interceptor never
/// grows a branch per mechanism.
pub(open) trait Authenticator {
  fn authenticate(Self, Call) -> Unit raise
}

///|
/// The server tracing interceptor: open a server span for the call, as a child of
/// the context the client sent, and record the resulting status on it.
pub fn server_tracing(
  tracer : @trace.Tracer,
  now~ : () -> Int64 = @telemetry.trace_clock(),
) -> Interceptor {
  inner => {
    call => {
      let started = now()
      let span = start_server_span(tracer, call, started) catch {
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
/// Open the server span for `call`, continuing the caller's trace when it sent
/// one.
fn start_server_span(
  tracer : @trace.Tracer,
  call : Call,
  at : Int64,
) -> @trace.Span raise {
  let name = "rpc " + call.name()
  match call.parent {
    Some(parent) => tracer.start(name, parent~, kind=Server, at~)
    None => tracer.start(name, kind=Server, at~)
  }
}

///|
/// The recovery interceptor: an error raised anywhere below is reported as
/// `Internal` instead of reaching the transport, and logged with its method so the
/// reason is not lost. A handler itself cannot raise — the transport hands it a
/// request and takes back bytes — but a layer added below can.
pub fn server_recover(logger? : @logx.Logger) -> Interceptor {
  let lg = logger.unwrap_or(@logx.logx)
  inner => {
    call => {
      let result : Result[Result[Bytes, @moonrpc.Status], Error] = Ok(
        inner(call),
      ) catch {
        error => Err(error)
      }
      match result {
        Ok(reply) => reply
        Err(error) => {
          lg.error("panic - " + call.path + " - \{error}")
          Err(@moonrpc.Status::Internal)
        }
      }
    }
  }
}

///|
/// What the stat interceptor logs: the slow-call threshold, and the methods whose
/// payload must not reach a log line.
pub(all) struct StatConf {
  slow_ms : Int64
  ignore_content_methods : Array[String]
}

///|
/// The default stat policy: half a second counts as slow, and every payload is
/// logged.
pub fn StatConf::new(
  slow_ms~ : Int64 = 500L,
  ignore_content_methods~ : Array[String] = [],
) -> StatConf {
  { slow_ms, ignore_content_methods, }
}

///|
/// The stat interceptor: every call is timed, and a slow one is logged with its
/// method. A method in `ignore_content_methods` is logged without the payload
/// size, so a credential never reaches a log file.
pub fn server_stat(
  clock : @clock.Clock,
  conf~ : StatConf = StatConf::new(),
  logger? : @logx.Logger,
) -> Interceptor {
  let lg = logger.unwrap_or(@logx.logx)
  inner => {
    call => {
      let started = clock.now()
      let result = inner(call)
      let elapsed = clock.now() - started
      if elapsed > conf.slow_ms {
        let note = if conf.ignore_content_methods.contains(call.path) {
          ""
        } else {
          " - " + call.request.length().to_string() + "B"
        }
        lg.with_duration(elapsed).info("[RPC] slowcall - " + call.path + note)
      }
      result
    }
  }
}

///|
/// The server Prometheus interceptor: time the call and count it under its method
/// and status code.
pub fn server_prometheus(
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
/// The server breaker interceptor: a shed call never reaches the handler and
/// answers `Unavailable`. A deadline or a shed on the way in says nothing about
/// this service, so it does not count as a failure.
pub fn server_breaker(breaker : @breaker.Breaker) -> Interceptor {
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
/// The shedding interceptor: a call is admitted against the adaptive shedder, and
/// refused with `ResourceExhausted` when the machine is past its threshold. A
/// refused call is reported to the shedder as a drop; an admitted one is reported
/// by how it ended.
pub fn server_shedding(shedder : @shedder.Shedder) -> Interceptor {
  inner => {
    call => {
      guard shedder.allow() is Some(ticket) else {
        return Err(@moonrpc.Status::ResourceExhausted)
      }
      let result = inner(call)
      match result {
        Err(DeadlineExceeded) => ticket.fail()
        _ => ticket.pass()
      }
      result
    }
  }
}

///|
/// A per-method deadline: `path` gets `budget_ms` instead of the service's.
pub(all) struct MethodTimeout {
  path : String
  budget_ms : Int64
}

///|
/// The timeout interceptor: a call that ran past its budget is reported as
/// `DeadlineExceeded`. `methods` overrides the service budget for named paths.
///
/// The deadline is checked when the handler returns, not raced against a timer:
/// this transport runs the peer in the caller's task, so there is no frame to
/// abandon. A socket-backed server hands the same budget to its read deadline,
/// which does preempt.
pub fn server_timeout(
  budget_ms : Int64,
  clock : @clock.Clock,
  methods~ : Array[MethodTimeout] = [],
) -> Interceptor {
  guard budget_ms > 0L || methods.length() > 0 else { inner => inner }
  let budgets : Map[String, Int64] = Map([])
  for m in methods {
    budgets[m.path] = m.budget_ms
  }
  inner => {
    call => {
      let budget = budgets.get(call.path).unwrap_or(budget_ms)
      let started = clock.now()
      let result = inner(call)
      if budget > 0L && clock.now() - started > budget {
        Err(@moonrpc.Status::DeadlineExceeded)
      } else {
        result
      }
    }
  }
}

///|
/// The authentication interceptor: a peer that cannot prove itself is refused with
/// `Unauthenticated` and its call never reaches the handler.
///
/// It runs outermost, ahead of the breaker and the metric families, so a stream of
/// unauthenticated calls cannot push the breaker open or fill the counters with
/// traffic the service never served.
pub fn server_auth(authenticator : &Authenticator) -> Interceptor {
  inner => {
    call => {
      let refused = try {
        authenticator.authenticate(call)
        None
      } catch {
        error => Some(error)
      }
      match refused {
        Some(_) => Err(@moonrpc.Status::Unauthenticated)
        None => inner(call)
      }
    }
  }
}

///|
/// Everything the server chain needs that is not a flag.
pub(all) struct ServerDeps {
  clock : @clock.Clock
  tracer : @trace.Tracer
  breaker : @breaker.Breaker
  shedder : @shedder.Shedder
  metrics : RpcMetrics
  authenticator : &Authenticator?
  now : () -> Int64
  timeout_ms : Int64
  stat : StatConf
}

///|
/// The dependencies for a server config, with every seam at its default: a system
/// clock, a discarding tracer, a fresh breaker and shedder, and no authenticator —
/// a server that does not say who may call it accepts anybody, which is what
/// `Auth: false` means.
pub fn ServerDeps::new(
  clock~ : @clock.Clock = @clock.Clock::system(),
  tracer? : @trace.Tracer,
  breaker? : @breaker.Breaker,
  shedder? : @shedder.Shedder,
  metrics? : RpcMetrics,
  authenticator? : &Authenticator,
  now? : () -> Int64,
  timeout_ms~ : Int64 = 2000L,
  stat~ : StatConf = StatConf::new(),
) -> ServerDeps raise @metric.Refused {
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
    shedder: match shedder {
      Some(shedder) => shedder
      None => @shedder.Shedder::new(clock)
    },
    metrics: match metrics {
      Some(metrics) => metrics
      None => RpcMetrics::new(kind="server")
    },
    authenticator,
    now: match now {
      Some(now) => now
      None => () => clock.now() * 1_000_000L
    },
    timeout_ms,
    stat,
  }
}

///|
/// The server chain `conf` asks for, outermost first: authentication, tracing,
/// recovery, the stat log, the metric families, the breaker, shedding and the
/// deadline.
pub fn server_interceptors(
  conf : @conf.RpcServerMiddlewaresConf,
  deps : ServerDeps,
) -> Array[Interceptor] {
  let out : Array[Interceptor] = []
  if conf.auth {
    match deps.authenticator {
      Some(authenticator) => out.push(server_auth(authenticator))
      None => ()
    }
  }
  if conf.trace {
    out.push(server_tracing(deps.tracer, now=deps.now))
  }
  if conf.recover {
    out.push(server_recover())
  }
  if conf.stat {
    out.push(server_stat(deps.clock, conf=deps.stat))
  }
  if conf.prometheus {
    out.push(server_prometheus(deps.metrics, deps.clock))
  }
  if conf.breaker {
    out.push(server_breaker(deps.breaker))
  }
  if conf.shedding {
    out.push(server_shedding(deps.shedder))
  }
  if conf.timeout && deps.timeout_ms > 0L {
    out.push(server_timeout(deps.timeout_ms, deps.clock))
  }
  out
}
