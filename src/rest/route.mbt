// Per-route options: the settings go-zero's `RouteOption`s attach to a route
// rather than to the whole service.
//
// A moonzero route carries them as `hoops` — moonapi's per-route middleware — so
// the check runs before the handler and short-circuits with the status the option
// promises. Nothing here depends on the engine: the options are applied where the
// route is registered, which is the same place go-zero's `AddRoute` applies them.

///|
/// JWT settings attached to a route: the current secret and, during a rotation,
/// the previous one.
pub(all) struct JwtRoute {
  enabled : Bool
  secret : String
  prev_secret : String?
}

///|
/// JWT settings that authenticate nothing.
pub let no_jwt : JwtRoute = { enabled: false, secret: "", prev_secret: None, }

///|
/// The per-route settings. Every one of them defaults to "inherit": no timeout, no
/// body cap, no JWT, no signature, ordinary priority, no SSE.
pub(all) struct RouteOptions {
  /// A path prefix joined onto the group's own, so one registration can nest.
  prefix : String
  jwt : JwtRoute
  signature : @handler.SignatureVerifier?
  /// A per-route deadline in milliseconds; `0` inherits the service timeout.
  timeout_ms : Int64
  /// A per-route `Content-Length` cap; `0` inherits `RestConf.MaxBytes`.
  max_bytes : Int32
  /// The shedder this route draws on instead of the ordinary one, when the
  /// service runs a second, higher CPU threshold for priority traffic.
  priority_shedder : @shedder.Shedder?
  /// Stamp `text/event-stream` on the response.
  sse : Bool
  clock : @clock.Clock
}

///|
/// Options that change nothing: no prefix, no auth, no deadline, no cap.
pub fn RouteOptions::new(
  clock~ : @clock.Clock = @clock.Clock::system(),
) -> RouteOptions {
  {
    prefix: "",
    jwt: no_jwt,
    signature: None,
    timeout_ms: 0L,
    max_bytes: 0,
    priority_shedder: None,
    sse: false,
    clock,
  }
}

///|
/// Join `group` onto this option set's prefix, so a sub-group inherits the parent
/// prefix as well as its own.
pub fn RouteOptions::under(
  self : RouteOptions,
  prefix : String,
) -> RouteOptions {
  {
    prefix: join_prefix(self.prefix, prefix),
    jwt: self.jwt,
    signature: self.signature,
    timeout_ms: self.timeout_ms,
    max_bytes: self.max_bytes,
    priority_shedder: self.priority_shedder,
    sse: self.sse,
    clock: self.clock,
  }
}

///|
/// Require a valid `Authorization: Bearer <jwt>` on this route. `prev_secret` is
/// the secret a rotation is retiring: a token signed with it is still accepted
/// until the rotation window closes, which is what lets clients refresh without a
/// coordinated deploy.
pub fn RouteOptions::jwt(
  self : RouteOptions,
  secret~ : String,
  prev_secret? : String,
) -> RouteOptions {
  {
    prefix: self.prefix,
    jwt: { enabled: true, secret, prev_secret, },
    signature: self.signature,
    timeout_ms: self.timeout_ms,
    max_bytes: self.max_bytes,
    priority_shedder: self.priority_shedder,
    sse: self.sse,
    clock: self.clock,
  }
}

///|
/// Require a verified `X-Content-Security` signature on this route.
pub fn RouteOptions::signature(
  self : RouteOptions,
  verifier : @handler.SignatureVerifier,
) -> RouteOptions {
  {
    prefix: self.prefix,
    jwt: self.jwt,
    signature: Some(verifier),
    timeout_ms: self.timeout_ms,
    max_bytes: self.max_bytes,
    priority_shedder: self.priority_shedder,
    sse: self.sse,
    clock: self.clock,
  }
}

///|
/// Give this route its own deadline in milliseconds.
pub fn RouteOptions::timeout(self : RouteOptions, ms : Int64) -> RouteOptions {
  {
    prefix: self.prefix,
    jwt: self.jwt,
    signature: self.signature,
    timeout_ms: ms,
    max_bytes: self.max_bytes,
    priority_shedder: self.priority_shedder,
    sse: self.sse,
    clock: self.clock,
  }
}

///|
/// Give this route its own `Content-Length` cap in bytes.
pub fn RouteOptions::max_bytes(
  self : RouteOptions,
  bytes : Int32,
) -> RouteOptions {
  {
    prefix: self.prefix,
    jwt: self.jwt,
    signature: self.signature,
    timeout_ms: self.timeout_ms,
    max_bytes: bytes,
    priority_shedder: self.priority_shedder,
    sse: self.sse,
    clock: self.clock,
  }
}

///|
/// Draw this route from the priority shedder, so a CPU spike sheds ordinary
/// traffic before it touches these calls.
pub fn RouteOptions::priority(
  self : RouteOptions,
  shedder : @shedder.Shedder,
) -> RouteOptions {
  {
    prefix: self.prefix,
    jwt: self.jwt,
    signature: self.signature,
    timeout_ms: self.timeout_ms,
    max_bytes: self.max_bytes,
    priority_shedder: Some(shedder),
    sse: self.sse,
    clock: self.clock,
  }
}

///|
/// Mark this route as a server-sent-event stream: the response carries the SSE
/// media type, no caching, and a keep-alive connection.
pub fn RouteOptions::sse(self : RouteOptions) -> RouteOptions {
  {
    prefix: self.prefix,
    jwt: self.jwt,
    signature: self.signature,
    timeout_ms: self.timeout_ms,
    max_bytes: self.max_bytes,
    priority_shedder: self.priority_shedder,
    sse: true,
    clock: self.clock,
  }
}

///|
/// Join a prefix with a path into a single, normalised path: at most one slash
/// between the two, a guaranteed leading slash, and `"/"` for the empty result.
pub fn join_path(prefix : String, path : String) -> String {
  let mut end = prefix.length()
  while end > 0 && prefix[end - 1] == '/' {
    end = end - 1
  }
  let base = prefix[0:end].to_owned()
  let head = if base.length() == 0 || base[0] == '/' {
    base
  } else {
    "/" + base
  }
  if path.length() == 0 {
    return if head.length() == 0 { "/" } else { head }
  }
  let tail = if path[0] == '/' { path } else { "/" + path }
  head + tail
}

///|
/// `join_path` for a prefix that may be absent: two empty prefixes stay empty
/// rather than collapsing to the root path, so a group with no prefix of its own
/// adds nothing to a route.
pub fn join_prefix(prefix : String, path : String) -> String {
  match join_path(prefix, path) {
    "/" => ""
    other => other
  }
}
