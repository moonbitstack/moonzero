// The route-level checks: what each option refuses, what it stamps, and the order
// the options are applied in.

///|
/// A request as a hoop sees it: the verb, path, headers and buffered body.
fn hoop_request(
  verb : String,
  path : String,
  headers~ : Array[(String, String)] = [],
  body~ : Bytes = b"",
) -> @http.Request {
  { http_method: verb, path, query_string: b"", headers, body, }
}

///|
/// A context a hoop can be run against.
fn hoop_ctx(
  verb : String,
  path : String,
  headers~ : Array[(String, String)] = [],
  body~ : Bytes = b"",
) -> @ctx.Context {
  @ctx.Context::new(hoop_request(verb, path, headers~, body~))
}

///|
/// The buffered reply a hoop produced.
fn buffered(reply : @route.Reply) -> @http.Response {
  match reply {
    @route.Reply::Buffered(response) => response
    @route.Reply::Streamed(_) =>
      abort("a route hoop answers with a buffered reply")
  }
}

///|
/// The status a hoop answered with.
fn status_of(reply : @route.Reply) -> Int32 {
  buffered(reply).status
}

///|
/// The value of one header on a buffered reply, or `""`.
fn header_of(reply : @route.Reply, name : String) -> String {
  for pair in buffered(reply).headers {
    if pair.0 == name {
      return pair.1
    }
  }
  ""
}

///|
/// A handler that answers 200 with the body `ok`, as a registered route would.
fn handler() -> async (@ctx.Context) -> @route.Reply {
  _ctx => {
    @route.Reply::Buffered(
      @http.Response::new(200, [("content-type", "text/plain")], b"ok"),
    )
  }
}

///|
/// A shedder that has already decided to shed everything, the state a hot and full
/// machine reaches.
fn saturated_shedder(clock : @clock.Clock) -> @shedder.Shedder {
  let usage : Ref[Int64] = { val: 1000L, }
  let shed = @shedder.Shedder::new(clock, usage=() => usage.val)
  let open : Array[@shedder.Ticket] = []
  for i = 0; i < 8; i = i + 1 {
    open.push(shed.allow().unwrap())
  }
  open[0].pass()
  open[1].pass()
  shed
}

///|
test "options that ask for nothing install no checks" {
  assert_eq(hoops_of(RouteOptions::new()).length(), 0)
}

///|
/// Run `hoops` around `handler`, outermost first, and answer the reply.
async fn run_hoops(
  hoops : Array[@route.Hoop],
  ctx : @ctx.Context,
) -> @route.Reply {
  let mut chain : async (@ctx.Context) -> @route.Reply = handler()
  for i = hoops.length() - 1; i >= 0; i = i - 1 {
    let hoop = hoops[i]
    let inner = chain
    chain = c => hoop(c, inner)
  }
  chain(ctx)
}

///|
async test "every option that is set becomes a hoop, the refusals first" {
  let clock = @clock.ManualClock::new().as_clock()
  let options : RouteOptions = {
    ..RouteOptions::new(clock~),
    jwt: { enabled: true, secret: "s", prev_secret: None, },
    signature: Some(@handler.SignatureVerifier::new(keys=[], strict=true)),
    max_bytes: 1_024,
    timeout_ms: 500L,
    priority_shedder: Some(saturated_shedder(clock)),
    sse: true,
  }
  // Six checks, and the ones that can refuse come before the one that only stamps.
  assert_eq(hoops_of(options).length(), 6)
  // A request that fails all three refusing checks is answered by the outermost
  // one: the signature, not the token and not the body cap.
  let reply = run_hoops(
    hoops_of(options),
    hoop_ctx("POST", "/x", headers=[("content-length", "9999")]),
  )
  assert_eq(status_of(reply), 403)
}

///|
async test "a body over the route's cap is refused before the handler" {
  let hoop = max_bytes_hoop(1_024)
  // A declared length past the cap, whether or not a byte was sent.
  assert_eq(
    status_of(
      hoop(
        hoop_ctx("POST", "/x", headers=[("content-length", "2048")]),
        handler(),
      ),
    ),
    413,
  )
  // Exactly at the cap, under it, and undeclared all go through.
  assert_eq(
    status_of(
      hoop(
        hoop_ctx("POST", "/x", headers=[("content-length", "1024")]),
        handler(),
      ),
    ),
    200,
  )
  assert_eq(
    status_of(
      hoop(
        hoop_ctx("POST", "/x", headers=[("content-length", "12")]),
        handler(),
      ),
    ),
    200,
  )
  assert_eq(status_of(hoop(hoop_ctx("POST", "/x"), handler())), 200)
}

///|
async test "a handler past the route's deadline is abandoned" {
  let slow : async (@ctx.Context) -> @route.Reply = _ctx => {
    @async.sleep(500)
    @route.Reply::Buffered(@http.Response::new(200, [], b"late"))
  }
  let hoop = timeout_hoop(20L)
  let reply = hoop(hoop_ctx("GET", "/x"), slow)
  assert_eq(status_of(reply), 503)
  assert_eq(buffered(reply).body, b"service timeout")
  // A handler inside its budget is answered as it is.
  let quick = hoop(hoop_ctx("GET", "/x"), handler())
  assert_eq(status_of(quick), 200)
}

///|
test "a JWT route takes the current secret and the one a rotation is retiring" {
  let now_secs = 1_700_000_000L
  let token = @handler.jwt_sign(
    { "sub": "u1", "exp": now_secs + 60L },
    "new-secret",
  )
  let current : JwtRoute = {
    enabled: true,
    secret: "new-secret",
    prev_secret: Some("old-secret"),
  }
  assert_eq(jwt_accepts(current, Some(token), now_secs), true)
  // The previous secret is what makes a rotation possible: a client that has not
  // picked up the new one yet keeps working while it does.
  let old = @handler.jwt_sign(
    { "sub": "u1", "exp": now_secs + 60L },
    "old-secret",
  )
  assert_eq(jwt_accepts(current, Some(old), now_secs), true)
  // Once the rotation is over the old token is nobody's.
  let retired : JwtRoute = { ..current, prev_secret: None, }
  assert_eq(jwt_accepts(retired, Some(old), now_secs), false)
  // A token signed with neither is refused, and so is a route with no token.
  let stranger = @handler.jwt_sign(
    { "sub": "u1", "exp": now_secs + 60L },
    "other",
  )
  assert_eq(jwt_accepts(current, Some(stranger), now_secs), false)
  assert_eq(jwt_accepts(current, None, now_secs), false)
  // A route that does not ask for a token does not check for one.
  assert_eq(jwt_accepts(no_jwt, None, now_secs), true)
}

///|
async test "the JWT hoop refuses without a token and passes one through" {
  let clock = @clock.ManualClock::new(start=1_700_000_000_000L).as_clock()
  let setting : JwtRoute = {
    enabled: true,
    secret: "s3cret",
    prev_secret: None,
  }
  let hoop = jwt_hoop(setting, clock)
  let refused = hoop(hoop_ctx("GET", "/x"), handler())
  assert_eq(status_of(refused), 401)
  // RFC 7235 wants the challenge on a 401.
  assert_eq(header_of(refused, "www-authenticate"), "Bearer")
  let token = @handler.jwt_sign(
    { "sub": "u1", "exp": clock.now() / 1000L + 60L },
    "s3cret",
  )
  let allowed = hoop(
    hoop_ctx("GET", "/x", headers=[("authorization", "Bearer " + token)]),
    handler(),
  )
  assert_eq(status_of(allowed), 200)
}

///|
async test "the signature hoop refuses a strict route and passes a lenient one" {
  let clock = @clock.ManualClock::new(start=1_700_000_000_000L).as_clock()
  let strict = signature_hoop(
    @handler.SignatureVerifier::new(keys=[], strict=true),
    clock,
  )
  assert_eq(status_of(strict(hoop_ctx("POST", "/x"), handler())), 403)
  let lenient = signature_hoop(
    @handler.SignatureVerifier::new(keys=[], strict=false),
    clock,
  )
  assert_eq(status_of(lenient(hoop_ctx("POST", "/x"), handler())), 200)
}

///|
async test "the SSE hoop stamps the stream headers and leaves a streamed reply alone" {
  let hoop = sse_hoop()
  let stamped = hoop(hoop_ctx("GET", "/events"), handler())
  assert_eq(header_of(stamped, "content-type"), "text/event-stream")
  assert_eq(header_of(stamped, "cache-control"), "no-cache")
  assert_eq(header_of(stamped, "connection"), "keep-alive")
}

///|
async test "the priority hoop answers 503 when the shedder has no ticket" {
  let clock = @clock.ManualClock::new().as_clock()
  let hoop = priority_hoop(saturated_shedder(clock))
  assert_eq(status_of(hoop(hoop_ctx("GET", "/x"), handler())), 503)
  // A shedder with room lets the request through.
  let roomy = @shedder.Shedder::new(clock, usage=() => 0L)
  assert_eq(
    status_of(priority_hoop(roomy)(hoop_ctx("GET", "/x"), handler())),
    200,
  )
}
