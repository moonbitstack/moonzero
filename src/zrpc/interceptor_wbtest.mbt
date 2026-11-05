///|
/// A logger nobody reads, so a test never touches the process logger.
fn quiet_logger(clock : @clock.Clock) -> @logx.Logger {
  @logx.Logger::new(clock, sink=@moonlog.Discard::new())
}

///|
/// A clock a test advances by hand.
fn ticker() -> (@clock.ManualClock, @clock.Clock) {
  let manual = @clock.ManualClock::new(start=1_000_000L)
  (manual, manual.as_clock())
}

///|
/// An invoker that answers `reply` and counts how often it ran.
fn ok_invoker(reply : Bytes, calls : Ref[Int32]) -> Invoker {
  _call => {
    calls.val = calls.val + 1
    Ok(reply)
  }
}

///|
fn failing_invoker(status : @moonrpc.Status, calls : Ref[Int32]) -> Invoker {
  _call => {
    calls.val = calls.val + 1
    Err(status)
  }
}

///|
test "a chain nests the first interceptor outermost" {
  let order : Ref[String] = { val: "", }
  let tag : (String) -> Interceptor = name => {
    inner => {
      call => {
        order.val = order.val + name
        let out = inner(call)
        order.val = order.val + name.to_upper()
        out
      }
    }
  }
  let calls : Ref[Int32] = { val: 0, }
  let invoker = chain([tag("a"), tag("b")], ok_invoker(b"x", calls))
  let result = invoker({ path: "/s/M", request: b"", parent: None, })
  assert_eq(result is Ok(_), true)
  assert_eq(order.val, "abBA")
  assert_eq(calls.val, 1)
}

///|
test "the breaker refuses without reaching the transport" {
  let (manual, clock) = ticker()
  // A fixed shed roll: every failure below drives the ratio to 1, so the decision
  // is the breaker's and not the generator's.
  let breaker = @breaker.Breaker::new(clock, rand=fn() { 0.0 })
  let calls : Ref[Int32] = { val: 0, }
  let invoker = chain(
    [client_breaker(breaker)],
    failing_invoker(Unknown, calls),
  )
  // Enough consecutive failures to open the window.
  for i = 0; i < 40; i = i + 1 {
    manual.advance(10L)
    let _ = invoker({ path: "/s/M", request: b"", parent: None, })
  }
  let before = calls.val
  manual.advance(10L)
  assert_eq(
    invoker({ path: "/s/M", request: b"", parent: None, }) is Err(Unavailable),
    true,
  )
  assert_eq(calls.val, before)
}

///|
test "an acceptable failure does not open the breaker" {
  let (manual, clock) = ticker()
  let breaker = @breaker.Breaker::new(clock, rand=fn() { 0.0 })
  let calls : Ref[Int32] = { val: 0, }
  let invoker = chain(
    [client_breaker(breaker)],
    failing_invoker(DeadlineExceeded, calls),
  )
  for i = 0; i < 60; i = i + 1 {
    manual.advance(10L)
    let _ = invoker({ path: "/s/M", request: b"", parent: None, })
  }
  assert_eq(calls.val, 60)
}

///|
test "a call past its budget is reported as a deadline" {
  let (manual, clock) = ticker()
  let slow : Invoker = _call => {
    manual.advance(5_000L)
    Ok(b"late")
  }
  let invoker = chain([client_timeout(1_000L, clock)], slow)
  assert_eq(
    invoker({ path: "/s/M", request: b"", parent: None, })
    is Err(DeadlineExceeded),
    true,
  )
  let quick : Invoker = _call => Ok(b"in time")
  let fast = chain([client_timeout(1_000L, clock)], quick)
  assert_eq(fast({ path: "/s/M", request: b"", parent: None, }) is Ok(_), true)
}

///|
test "the metric interceptor counts by method and status" {
  let (_, clock) = ticker()
  let metrics = RpcMetrics::new(kind="client") catch {
    _ => fail("the fixed metric names must register")
  }
  let invoker = chain(
    [client_prometheus(metrics, clock)],
    ok_invoker(b"x", { val: 0, }),
  )
  let _ = invoker({ path: "/s/M", request: b"", parent: None, })
  let _ = invoker({ path: "/s/M", request: b"", parent: None, })
  assert_eq(metrics.calls("/s/M", 0), 2.0)
  assert_eq(metrics.observations("/s/M"), 2L)
  let body = metrics.to_exposition()
  assert_eq(body.contains("rpc_client_requests_code_total"), true)
  assert_eq(body.contains("rpc_client_requests_duration_ms"), true)
}

///|
test "a server-side deadline reports the overrun" {
  let (manual, clock) = ticker()
  let slow : Invoker = _call => {
    manual.advance(3_000L)
    Ok(b"late")
  }
  let invoker = chain([server_timeout(2_000L, clock)], slow)
  assert_eq(
    invoker({ path: "/s/M", request: b"", parent: None, })
    is Err(DeadlineExceeded),
    true,
  )
  // A per-method budget overrides the service's.
  let generous = chain(
    [
      server_timeout(2_000L, clock, methods=[
        { path: "/s/M", budget_ms: 10_000L, },
      ]),
    ],
    slow,
  )
  assert_eq(
    generous({ path: "/s/M", request: b"", parent: None, }) is Ok(_),
    true,
  )
}

///|
/// An authenticator that only accepts one token.
struct TokenCheck {
  token : String
}

///|
impl Authenticator for TokenCheck with fn authenticate(self, call) {
  let token = @utf8.decode(call.request[:]) catch { _ => "" }
  guard token == self.token else { raise Refused("bad token") }
}

///|
/// The one failure an in-test authenticator reports.
suberror Refused {
  Refused(String)
}

///|
test "authentication refuses a peer that cannot prove itself" {
  let checker : TokenCheck = { token: "good", }
  let calls : Ref[Int32] = { val: 0, }
  let invoker = chain([server_auth(checker)], ok_invoker(b"x", calls))
  assert_eq(
    invoker({ path: "/s/M", request: b"bad", parent: None, })
    is Err(Unauthenticated),
    true,
  )
  assert_eq(calls.val, 0)
  assert_eq(
    invoker({ path: "/s/M", request: b"good", parent: None, }) is Ok(_),
    true,
  )
  assert_eq(calls.val, 1)
}

///|
test "shedding refuses a call the machine cannot carry" {
  let (_, clock) = ticker()
  let usage : Ref[Int64] = { val: 1000L, }
  let shedder = @shedder.Shedder::new(clock, usage=() => usage.val)
  // A cold shedder admits: the CPU reading alone sheds nothing, because nothing is
  // queued yet. Three calls in flight with one finished is what makes it full.
  let open : Array[@shedder.Ticket] = []
  for i = 0; i < 8; i = i + 1 {
    open.push(shedder.allow().unwrap())
  }
  // Two of the eight finish, which drags the moving average of calls in flight up
  // past what the saturated machine can carry.
  open[0].pass()
  open[1].pass()
  let calls : Ref[Int32] = { val: 0, }
  let invoker = chain([server_shedding(shedder)], ok_invoker(b"x", calls))
  assert_eq(
    invoker({ path: "/s/M", request: b"", parent: None, })
    is Err(ResourceExhausted),
    true,
  )
  assert_eq(calls.val, 0)
}

///|
test "an error raised below is turned into Internal and logged" {
  let (_, clock) = ticker()
  let raising : Invoker = _call => raise Failure("boom")
  let invoker = chain([server_recover(logger=quiet_logger(clock))], raising)
  assert_eq(
    invoker({ path: "/s/M", request: b"", parent: None, }) is Err(Internal),
    true,
  )
}

///|
/// The one failure a raising invoker reports.
suberror Failure {
  Failure(String)
}

///|
test "every status code survives the trip to a number and back" {
  let codes : Array[(@moonrpc.Status, Int32)] = [
    (Ok, 0),
    (Cancelled, 1),
    (Unknown, 2),
    (InvalidArgument, 3),
    (DeadlineExceeded, 4),
    (NotFound, 5),
    (AlreadyExists, 6),
    (PermissionDenied, 7),
    (ResourceExhausted, 8),
    (FailedPrecondition, 9),
    (Aborted, 10),
    (OutOfRange, 11),
    (Unimplemented, 12),
    (Internal, 13),
    (Unavailable, 14),
    (DataLoss, 15),
    (Unauthenticated, 16),
  ]
  for pair in codes {
    assert_eq(status_code(pair.0), pair.1)
    assert_eq(status_of_code(pair.1) == pair.0, true)
    assert_eq(status_name(pair.0).length() > 0, true)
  }
}

///|
test "a server dispatch runs the chain and reaches the handler" {
  let (_, clock) = ticker()
  let metrics = RpcMetrics::new(kind="server") catch {
    _ => fail("the fixed metric names must register")
  }
  let server = RpcServer::new(@conf.RpcServerConf::new(name="greeter")).use_(
    server_prometheus(metrics, clock),
  )
  server.group("hello.Greeter").register("SayHello", req => b"hello " + req)
  let reply = server.invoke({
    path: "/hello.Greeter/SayHello",
    request: b"world",
    parent: None,
  })
  assert_eq(reply is Ok(_), true)
  assert_eq(metrics.calls("/hello.Greeter/SayHello", 0), 1.0)
  // An unregistered path still goes through the chain, and still counts.
  let missing = server.invoke({
    path: "/hello.Greeter/Missing",
    request: b"",
    parent: None,
  })
  assert_eq(missing is Err(Unimplemented), true)
  assert_eq(metrics.calls("/hello.Greeter/Missing", 12), 1.0)
}
