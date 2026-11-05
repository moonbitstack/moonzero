// The middlewares that have no configuration of their own: recovery, CORS,
// request ids and access logging.
//
// A middleware here is an ASGI application transformer. Layers that already
// exist elsewhere in the family arrive as moonasgi's `mid.Layer` and are adapted
// by `layer` rather than reimplemented: one concept, one home.

///|
/// Adapt a moonasgi `mid.Layer` into a moonzero `Middleware`. The two shapes are
/// the same ASGI transformer, so this is the whole bridge — a layer written for
/// moonasgi (`cors`, `gzip`, `body_limit`, `server_errors`, `trusted_hosts`,
/// `sessions`, or a user's own) drops into a moonzero chain unchanged.
pub fn layer(l : &@mid.Layer) -> Middleware {
  inner => l.wrap(inner)
}

///|
/// The event stream recovery emits in place of a failed request: a `500` start
/// followed by a short plain-text body.
fn internal_error_events() -> Array[@moonasgi.Event] {
  [
    @moonasgi.Event::HttpResponseStart(
      status=500,
      headers=[("content-type", "text/plain; charset=utf-8")],
      trailers=false,
    ),
    @moonasgi.Event::HttpResponseBody(
      body=b"Internal Server Error",
      more_body=false,
    ),
  ]
}

///|
/// Recovery middleware: run the wrapped application inside a `try`, and if it
/// raises before any part of the response has gone out, emit a `500 Internal
/// Server Error` instead of letting the failure escape to the server.
///
/// Once the response has started, a `500` can no longer be written — the status
/// line is already on the wire — so the error is re-raised for the server to
/// close the connection on. Answering late would append a second status to a
/// response the client is already reading.
pub fn recovery(inner : @moonasgi.AsgiApp) -> @moonasgi.AsgiApp {
  (scope, receive, send) => {
    let started : Ref[Bool] = { val: false, }
    let observed : @moonasgi.Send = event => {
      match event {
        HttpResponseStart(_) => started.val = true
        _ => ()
      }
      send(event)
    }
    inner(scope, receive, observed) catch {
      error => {
        if started.val {
          raise error
        }
        for event in internal_error_events() {
          send(event)
        }
      }
    }
  }
}

///|
/// CORS configuration: which origins may call the service, and what a preflight
/// is told about the rest of the policy.
pub(all) struct CorsConf {
  /// Origins allowed to call. `["*"]` — the default — allows any, and an entry
  /// also matches its own subdomains, so `example.com` allows
  /// `api.example.com`.
  origins : Array[String]
  methods : String
  headers : String
  expose : String
  max_age : Int32
}

///|
/// The method set go-zero advertises.
pub let cors_methods : String = "GET, HEAD, POST, PATCH, PUT, DELETE"

///|
/// The request headers go-zero lets through a preflight.
pub let cors_headers : String = "Content-Type, Origin, X-CSRF-Token, Authorization, AccessToken, Token, Range"

///|
/// The response headers go-zero exposes to script.
pub let cors_expose : String = "Content-Length, Access-Control-Allow-Origin, Access-Control-Allow-Headers"

///|
/// A permissive CORS config: any origin, go-zero's method and header sets, and a
/// one-day preflight cache.
pub fn CorsConf::new(
  origins~ : Array[String] = ["*"],
  methods~ : String = cors_methods,
  headers~ : String = cors_headers,
  expose~ : String = cors_expose,
  max_age~ : Int32 = 86400,
) -> CorsConf {
  { origins, methods, headers, expose, max_age, }
}

///|
/// Whether `origin` is allowed by `allows`: an exact match, a subdomain of an
/// allowed origin, or a wildcard. Matching is case-insensitive on both sides, as
/// the origin comparison in the Fetch standard is.
pub fn cors_allows(allows : Array[String], origin : String) -> Bool {
  let origin = origin.to_lower()
  for allow in allows {
    if allow == "*" {
      return true
    }
    let allow = allow.to_lower()
    if origin == allow || origin.has_suffix("." + allow) {
      return true
    }
  }
  false
}

///|
/// The headers a CORS response carries for `origin`: the echoed origin (or `*`),
/// the method/header sets, the exposed headers and the preflight cache age.
/// Credentials are advertised only for an echoed origin, because `*` and
/// credentials are mutually exclusive in the Fetch standard.
fn cors_response_headers(
  conf : CorsConf,
  origin : String?,
) -> Array[(String, String)] {
  // A wildcard policy answers "*" literally: echoing the request's origin would
  // then also permit credentials, and `*` with credentials is forbidden.
  let wildcard = conf.origins.length() == 0 || conf.origins.contains("*")
  let allow_origin = if wildcard {
    "*"
  } else {
    match origin {
      Some(origin) =>
        if cors_allows(conf.origins, origin) {
          origin
        } else {
          ""
        }
      None => ""
    }
  }
  if allow_origin == "" {
    return []
  }
  let out : Array[(String, String)] = [
    ("access-control-allow-origin", allow_origin),
    ("access-control-allow-methods", conf.methods),
    ("access-control-allow-headers", conf.headers),
    ("access-control-expose-headers", conf.expose),
    ("access-control-max-age", conf.max_age.to_string()),
  ]
  if allow_origin != "*" {
    out.push(("access-control-allow-credentials", "true"))
  }
  out
}

///|
/// The `Vary` values a CORS response must carry so a shared cache does not hand
/// one origin's answer to another.
fn cors_vary(preflight : Bool) -> Array[(String, String)] {
  let value = if preflight {
    "Origin, Access-Control-Request-Method, Access-Control-Request-Headers"
  } else {
    "Origin"
  }
  [("vary", value)]
}

///|
/// CORS middleware: answer a preflight `OPTIONS` with `204 No Content` and the
/// policy headers, and stamp the same headers onto every other response.
///
/// A request from an origin the policy does not allow is served without the
/// `Access-Control-*` headers rather than refused — the browser is the one that
/// enforces the policy, and a server-side refusal would break non-browser
/// clients that never asked for CORS at all.
pub fn cors(conf : CorsConf) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(hs) => {
          let origin = scope_header(scope, "origin")
          let preflight = hs.http_method == "OPTIONS"
          let policy = [
            ..cors_vary(preflight),
            ..cors_response_headers(conf, origin),
          ]
          if preflight {
            send(
              @moonasgi.Event::HttpResponseStart(
                status=204,
                headers=policy,
                trailers=false,
              ),
            )
            send(@moonasgi.Event::HttpResponseBody(body=b"", more_body=false))
          } else {
            let wrapped : @moonasgi.Send = event => {
              match event {
                HttpResponseStart(status~, headers=own, trailers~) =>
                  send(
                    @moonasgi.Event::HttpResponseStart(
                      status~,
                      headers=[..policy, ..own],
                      trailers~,
                    ),
                  )
                other => send(other)
              }
            }
            inner(scope, receive, wrapped)
          }
        }
        _ => inner(scope, receive, send)
      }
    }
  }
}

///|
/// Read a header from an HTTP scope (lowercased-name convention); `None` for
/// non-HTTP scopes or a missing header.
pub fn scope_header(scope : @moonasgi.Scope, name : String) -> String? {
  match scope {
    Http(hs) => {
      for pair in hs.headers {
        if pair.0 == name {
          return Some(pair.1)
        }
      }
      None
    }
    _ => None
  }
}

///|
/// Resolve the id for a request: reuse an inbound one verbatim, otherwise mint the
/// next monotonic `req-N` from the shared counter.
fn resolve_request_id(inbound : String?, counter : Ref[Int32]) -> String {
  match inbound {
    Some(existing) => existing
    None => {
      counter.val = counter.val + 1
      "req-" + counter.val.to_string()
    }
  }
}

///|
/// Request-ID middleware: reuse an inbound `x-request-id` if the client sent one,
/// otherwise mint a fresh monotonic id, and stamp it onto every response's
/// `HttpResponseStart`. The counter is captured once per assembly, so ids stay
/// unique across the requests this layer serves.
pub fn request_id(header~ : String = "x-request-id") -> Middleware {
  let counter : Ref[Int32] = { val: 0, }
  inner => {
    (scope, receive, send) => {
      let id = resolve_request_id(scope_header(scope, header), counter)
      let wrapped : @moonasgi.Send = event => {
        match event {
          HttpResponseStart(status~, headers~, trailers~) =>
            send(
              @moonasgi.Event::HttpResponseStart(
                status~,
                headers=[(header, id), ..headers],
                trailers~,
              ),
            )
          other => send(other)
        }
      }
      inner(scope, receive, wrapped)
    }
  }
}

///|
/// An AsgiApp transformer — one layer of the middleware onion.
pub type Middleware = (@moonasgi.AsgiApp) -> @moonasgi.AsgiApp

///|
/// A receive channel that hands the application `body` once and then reports the
/// connection closed — the shape an ASGI application sees for a body a layer has
/// already buffered.
pub fn buffered_body(body : Bytes) -> @moonasgi.Receive {
  let served : Ref[Bool] = { val: false, }
  () => {
    if served.val {
      @moonasgi.Event::HttpDisconnect
    } else {
      served.val = true
      @moonasgi.Event::HttpRequest(body~, more_body=false)
    }
  }
}

///|
/// Drain a receive channel into one body. Used by the layers that have to read
/// the whole payload before they can decide anything.
pub async fn read_body(receive : @moonasgi.Receive) -> Bytes {
  let body = Buffer()
  let mut more = true
  while more {
    match receive() {
      HttpRequest(body=chunk, more_body=next) => {
        body.write_bytes(chunk)
        more = next
      }
      _ => more = false
    }
  }
  body.to_bytes()
}

///|
/// A request-logging middleware: writes `METHOD path` through the process `logx`
/// at `info` for each HTTP request, then delegates to the wrapped application.
/// It logs on the way in and knows nothing of the response; `structured_logging`
/// is the layer that times the request and records its status.
pub fn logging(inner : @moonasgi.AsgiApp) -> @moonasgi.AsgiApp {
  (scope, receive, send) => {
    match scope {
      Http(hs) => @logx.logx.info(hs.http_method + " " + hs.path)
      _ => ()
    }
    inner(scope, receive, send)
  }
}
