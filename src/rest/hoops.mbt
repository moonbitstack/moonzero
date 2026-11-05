// The route-level checks, as moonapi hoops.
//
// One hoop per option that can refuse a request, in the order the options were
// asked for. A hoop sees the whole context — params, headers and the buffered
// body — so none of them needs a second read of the stream.

///|
/// The reply a refused route sends.
fn refusal_reply(
  status : Int32,
  headers : Array[(String, String)],
  text : String,
) -> @route.Reply {
  @route.Reply::Buffered(
    @http.Response::new(status, headers, @utf8.encode(text)),
  )
}

///|
/// `401 Unauthorized` with the `WWW-Authenticate` challenge RFC 7235 requires for
/// a bearer-protected resource.
fn unauthorized_reply() -> @route.Reply {
  refusal_reply(
    401,
    [
      ("content-type", "text/plain; charset=utf-8"),
      ("www-authenticate", "Bearer"),
    ],
    "401 Unauthorized",
  )
}

///|
/// `403 Forbidden`.
fn forbidden_reply() -> @route.Reply {
  refusal_reply(
    403,
    [("content-type", "text/plain; charset=utf-8")],
    "403 Forbidden",
  )
}

///|
/// `413 Payload Too Large`.
fn too_large_reply() -> @route.Reply {
  refusal_reply(
    413,
    [("content-type", "text/plain; charset=utf-8")],
    "413 Payload Too Large",
  )
}

///|
/// `503 Service Unavailable`, the answer a deadline or an open breaker gives.
fn unavailable_reply(body : String) -> @route.Reply {
  refusal_reply(503, [("content-type", "text/plain; charset=utf-8")], body)
}

///|
/// Whether `token` verifies against the route's current secret, or against the
/// one a rotation is retiring, at `now_secs`.
pub fn jwt_accepts(
  setting : JwtRoute,
  token : String?,
  now_secs : Int64,
) -> Bool {
  guard setting.enabled else { true }
  match token {
    Some(token) =>
      if @handler.jwt_authorized(Some(token), setting.secret, now_secs) {
        true
      } else {
        match setting.prev_secret {
          Some(previous) =>
            @handler.jwt_authorized(Some(token), previous, now_secs)
          None => false
        }
      }
    None => false
  }
}

///|
/// The JWT hoop: refuse the route unless the bearer token verifies.
pub fn jwt_hoop(setting : JwtRoute, clock : @clock.Clock) -> @route.Hoop {
  (ctx, inner) => {
    if jwt_accepts(setting, ctx.bearer_token(), clock.now() / 1000L) {
      inner(ctx)
    } else {
      unauthorized_reply()
    }
  }
}

///|
/// The timeout hoop: run the rest of the chain under a budget, and answer `503`
/// when it runs out. The deadline is enforced here rather than on the response
/// path, so a handler that never returns is abandoned instead of hanging the
/// request forever.
pub fn timeout_hoop(budget_ms : Int64) -> @route.Hoop {
  (ctx, inner) => {
    let budget = budget_ms.to_int()
    match @async.with_timeout_opt(budget, () => inner(ctx)) {
      Some(reply) => reply
      None => unavailable_reply("service timeout")
    }
  }
}

///|
/// The max-bytes hoop: refuse a body whose declared length exceeds `limit`.
pub fn max_bytes_hoop(limit : Int32) -> @route.Hoop {
  (ctx, inner) => {
    match ctx.request.header("content-length") {
      Some(value) =>
        match @handler.parse_i64(value) {
          Some(declared) =>
            if declared > limit.to_int64() {
              too_large_reply()
            } else {
              inner(ctx)
            }
          None => inner(ctx)
        }
      None => inner(ctx)
    }
  }
}

///|
/// The signature hoop: verify the `X-Content-Security` MAC and timestamp on this
/// route. A payload the envelope declares encrypted is *not* decrypted here — a
/// hoop cannot rewrite the request — so a route that takes encrypted bodies wants
/// the service-level `content_security` layer, which can.
pub fn signature_hoop(
  verifier : @handler.SignatureVerifier,
  clock : @clock.Clock,
) -> @route.Hoop {
  (ctx, inner) => {
    let input : @handler.SignatureInput = {
      verb: ctx.request.http_method,
      path: ctx.request.path,
      query: @utf8.decode(ctx.request.query_string[:]),
      header: ctx.request.header("x-content-security"),
      body: ctx.request.body,
      signed_uri: ctx.request.header("x-request-uri"),
    }
    let accepted = try {
      let _ = @handler.verify_signature(verifier, input, clock.now())
      true
    } catch {
      _ => false
    }
    if accepted || !verifier.strict() {
      inner(ctx)
    } else {
      forbidden_reply()
    }
  }
}

///|
/// The SSE hoop: stamp the event-stream media type, no caching and a kept-alive
/// connection onto a buffered response. A streamed reply declares its own headers
/// and is left alone.
pub fn sse_hoop() -> @route.Hoop {
  (ctx, inner) => {
    match inner(ctx) {
      @route.Reply::Buffered(resp) =>
        @route.Reply::Buffered(
          @http.Response::new(
            resp.status,
            [
              ("content-type", "text/event-stream"),
              ("cache-control", "no-cache"),
              ("connection", "keep-alive"),
              ..resp.headers,
            ],
            resp.body,
          ),
        )
      other => other
    }
  }
}

///|
/// The priority hoop: draw this route from `shedder`. A refused call answers
/// `503`, the status go-zero's shedding interceptor uses.
pub fn priority_hoop(shedder : @shedder.Shedder) -> @route.Hoop {
  (ctx, inner) => {
    match shedder.allow() {
      Some(ticket) => {
        let reply = inner(ctx)
        ticket.pass()
        reply
      }
      None => unavailable_reply("503 Service Unavailable")
    }
  }
}

///|
/// The hoops `options` asks for, outermost first: signature, JWT, body cap,
/// deadline, priority shedding, then the SSE stamp. Checks that refuse come
/// before the ones that only measure, so a refused request costs nothing.
pub fn hoops_of(options : RouteOptions) -> Array[@route.Hoop] {
  let out : Array[@route.Hoop] = []
  match options.signature {
    Some(verifier) => out.push(signature_hoop(verifier, options.clock))
    None => ()
  }
  if options.jwt.enabled {
    out.push(jwt_hoop(options.jwt, options.clock))
  }
  if options.max_bytes > 0 {
    out.push(max_bytes_hoop(options.max_bytes))
  }
  if options.timeout_ms > 0L {
    out.push(timeout_hoop(options.timeout_ms))
  }
  match options.priority_shedder {
    Some(shedder) => out.push(priority_hoop(shedder))
    None => ()
  }
  if options.sse {
    out.push(sse_hoop())
  }
  out
}
